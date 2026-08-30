-- Kronos Bot — Schema PostgreSQL
-- Fuente de verdad de las reglas: PROTOCOLOS_KRONOS_BOT.md
-- Tablas: signals, signal_modifications, settings

-- =========================================================
-- Tabla: signals
-- Señales nuevas capturadas desde Telegram (sección 3, 4, 7, 10)
-- =========================================================
CREATE TABLE IF NOT EXISTS signals (
    id                  SERIAL PRIMARY KEY,

    -- Identificador de sub-señal (sección 4.2 regla 6). Una señal con
    -- 2 TP genera 2 filas independientes, cada una con su propio
    -- signal_uid: "{message_id}-A" (TP1) y "{message_id}-B" (TP2).
    -- Señales de un solo TP usan solo "{message_id}-A".
    signal_uid          TEXT NOT NULL UNIQUE,

    -- Datos de captura (sección 3.1)
    message_id          BIGINT NOT NULL,
    chat_id             BIGINT NOT NULL,
    sender               TEXT,
    raw_text            TEXT NOT NULL,
    signal_timestamp    TIMESTAMP NOT NULL,
    reply_to_message_id BIGINT,

    -- Datos interpretados (sección 4.2)
    instrument          TEXT NOT NULL,
    direction            TEXT NOT NULL CHECK (direction IN ('BUY', 'SELL')),
    execution_type       TEXT NOT NULL CHECK (execution_type IN ('MARKET', 'LIMIT')),
    entry_price          REAL,
    sl                   REAL,
    tp                   REAL,

    interpreted_by       TEXT NOT NULL CHECK (interpreted_by IN ('REGEX', 'AI')),

    -- Lotaje asignado a la señal (sección 5). Valor fijo temporal
    -- (0.01) hasta que exista el cálculo real de capital/slots
    -- (CLAUDE.md, MVP actual).
    lot_assigned         REAL NOT NULL DEFAULT 0.01,

    -- Estado del ciclo de vida (sección 10)
    status                TEXT NOT NULL CHECK (status IN (
        'PENDING_CONFIRMATION',
        'CONFIRMED',
        'REJECTED_BY_USER',
        'OPEN',
        'TP_REACHED',
        'SL_REACHED',
        'CLOSED_MANUAL',
        'CLOSED_BY_PRICE_RACE',
        'EXPIRED',
        'PENDING_MANUAL'
    )) DEFAULT 'PENDING_CONFIRMATION',

    -- Ejecución y cierre (sección 9)
    mt4_ticket            INTEGER,
    close_timestamp        TIMESTAMP,
    close_price            REAL,
    profit_loss             REAL,

    created_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_signals_status ON signals(status);
CREATE INDEX IF NOT EXISTS idx_signals_instrument_status ON signals(instrument, status);
CREATE INDEX IF NOT EXISTS idx_signals_message_id ON signals(message_id);
CREATE INDEX IF NOT EXISTS idx_signals_mt4_ticket ON signals(mt4_ticket);

-- =========================================================
-- Tabla: signal_modifications
-- Instrucciones de seguimiento sobre señales existentes (sección 4, 8)
-- =========================================================
CREATE TABLE IF NOT EXISTS signal_modifications (
    id                  SERIAL PRIMARY KEY,

    signal_id            INTEGER NOT NULL REFERENCES signals(id),

    -- Datos de captura del mensaje de seguimiento
    message_id           BIGINT NOT NULL,
    raw_text              TEXT NOT NULL,

    modification_type     TEXT NOT NULL CHECK (modification_type IN (
        'ENTRY_CHANGE',
        'SL_CHANGE',
        'SL_TO_BE',
        'CANCEL',
        'TP_UPDATE',
        'CLOSE_AT_PRICE',
        'CLOSE_ALL_TO_BE',
        'UNCLASSIFIED'
    )),

    interpreted_by         TEXT NOT NULL CHECK (interpreted_by IN ('REGEX', 'AI')),

    -- Valor objetivo de la modificación (precio de SL/TP/entrada, o precio
    -- de referencia para CLOSE_AT_PRICE)
    target_price           REAL,

    -- Protocolo de reintento de precio (sección 8)
    attempt_count           INTEGER NOT NULL DEFAULT 0,
    status                   TEXT NOT NULL CHECK (status IN (
        'PENDING',
        'SUCCESS',
        'FAILED',
        'PENDING_MANUAL'
    )) DEFAULT 'PENDING',

    applied_price            REAL,

    created_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_signal_modifications_signal_id ON signal_modifications(signal_id);
CREATE INDEX IF NOT EXISTS idx_signal_modifications_status ON signal_modifications(status);

-- =========================================================
-- Tabla: settings
-- Configuración del sistema (sección 5.1)
-- capital_real es reportado automáticamente por el EA de MT4
-- (AccountBalance() - AccountCredit()), no editado a mano en
-- operación normal.
-- =========================================================
-- capital_inicial_plan (v2.3, agregado 2026-08-30): ancla manual, de
-- una sola vez, del capital con el que arrancó el plan de trading —
-- usado por GET /api/registros (dashboard/main.py) para reconstruir
-- el capital de cada día del panel Crecimiento/Calendario de
-- PVG_kronos. A diferencia de capital_real, este SÍ requiere carga
-- manual (no lo reporta el EA).
-- NOTA DE DESPLIEGUE: en una base ya existente hay que agregar a mano:
--   ALTER TABLE settings ADD COLUMN IF NOT EXISTS capital_inicial_plan REAL;
-- day_start_capital / day_start_date (agregado 2026-08-30, Fase 2 —
-- auto-confirmación, PROTOCOLOS_KRONOS_BOT.md sección 12.3): capital
-- registrado al inicio del día en curso, para calcular la ganancia del
-- día como (capital_real - day_start_capital) / day_start_capital y
-- aplicar el circuit breaker de 6%. Se resetea automáticamente cuando
-- day_start_date != CURRENT_DATE (ver
-- n8n-workflows/split-mvp/02-señal-nueva-parseo-confirmado.json).
-- NOTA DE DESPLIEGUE: en una base ya existente hay que agregar las
-- columnas a mano con:
--   ALTER TABLE settings ADD COLUMN IF NOT EXISTS day_start_capital REAL;
--   ALTER TABLE settings ADD COLUMN IF NOT EXISTS day_start_date DATE;
-- (mismo patrón que el resto de columnas nuevas del proyecto — este
-- CREATE TABLE con IF NOT EXISTS no las agrega a una tabla existente).
CREATE TABLE IF NOT EXISTS settings (
    id                  SERIAL PRIMARY KEY,
    capital_real         REAL NOT NULL,
    day_start_capital     REAL,
    day_start_date        DATE,
    capital_inicial_plan   REAL,
    updated_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =========================================================
-- Trigger: purge_old_signals (reemplaza compact_old_signals,
-- 2026-08-29, decisión explícita del usuario)
--
-- Elimina por completo el mecanismo de archivado/resumen
-- (signals_archive_summary) — ya no hace falta: `daily_pnl` (ver más
-- abajo) guarda el P&L histórico de forma independiente de si la fila
-- sigue existiendo en `signals` o no, así que no hay nada que
-- preservar al purgar.
--
-- Regla nueva, mucho más simple: cuando `signals` llega a 200 filas,
-- se borran las 100 más viejas (por created_at ASC) de una sola vez,
-- dejando las 100 más recientes — sin acumular ningún agregado.
-- Se dispara por statement (no por fila) después de cada INSERT,
-- igual que la versión anterior, para no recalcular el COUNT(*) en
-- cada fila de un INSERT masivo.
-- =========================================================
CREATE OR REPLACE FUNCTION purge_old_signals() RETURNS trigger AS $$
BEGIN
    IF (SELECT COUNT(*) FROM signals) < 200 THEN
        RETURN NULL;
    END IF;

    -- DROP explícito antes de crear: mismo motivo que la versión
    -- anterior de este trigger — una conexión pooled con una
    -- transacción sin cerrar podría dejar la tabla temporal viva de
    -- una ejecución previa (incidente real, 2026-08-18).
    DROP TABLE IF EXISTS _signals_to_purge;

    CREATE TEMP TABLE _signals_to_purge ON COMMIT DROP AS
    SELECT id FROM signals
    ORDER BY created_at ASC
    LIMIT 100;

    DELETE FROM signal_modifications
    WHERE signal_id IN (SELECT id FROM _signals_to_purge);

    DELETE FROM signals
    WHERE id IN (SELECT id FROM _signals_to_purge);

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_compact_old_signals ON signals;
DROP FUNCTION IF EXISTS compact_old_signals();
DROP TABLE IF EXISTS signals_archive_summary;

DROP TRIGGER IF EXISTS trg_purge_old_signals ON signals;
CREATE TRIGGER trg_purge_old_signals
    AFTER INSERT ON signals
    FOR EACH STATEMENT
    EXECUTE FUNCTION purge_old_signals();

-- =========================================================
-- NOTA DE DESPLIEGUE: en la base de producción (ya existente) hay que
-- aplicar a mano el bloque completo de daily_pnl + update_daily_pnl +
-- trg_update_daily_pnl que sigue — el docker-entrypoint-initdb.d solo
-- corre en un volumen nuevo, no reaplica este archivo sobre una base
-- que ya existe.
--
-- Tabla: daily_pnl (v2.0, agregado 2026-08-29)
-- Recap diario de ganancia/pérdida real, usado por el workflow
-- "Kronos 08 - Resumen diario" (mensaje de las 11am). Se llena en
-- tiempo real vía trigger (ver trg_update_daily_pnl más abajo), no
-- por un job batch — así no se pierde nada aunque
-- compact_old_signals() borre el detalle de signals más adelante
-- (el agregado diario ya quedó grabado antes de que eso ocurra).
--
-- "operable" = hubo al menos un cierre real ese día (decisión
-- explícita del usuario: un día operable se define por actividad
-- real, no por día de la semana — pueden operarse domingos según el
-- instrumento).
-- =========================================================
CREATE TABLE IF NOT EXISTS daily_pnl (
    date                DATE PRIMARY KEY,
    profit_loss          REAL NOT NULL DEFAULT 0,
    wins                  INTEGER NOT NULL DEFAULT 0,
    losses                INTEGER NOT NULL DEFAULT 0,
    instruments            TEXT,
    operable              BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =========================================================
-- Trigger: update_daily_pnl
-- Se dispara cuando una señal transiciona a un status de cierre real
-- (TP_REACHED, SL_REACHED, CLOSED_MANUAL, CLOSED_BY_PRICE_RACE) y
-- trae close_timestamp. Sólo cuenta el cambio de status hacia un
-- cierre (OLD.status IS DISTINCT FROM NEW.status), nunca re-suma un
-- UPDATE posterior sobre una señal que ya estaba cerrada.
-- =========================================================
CREATE OR REPLACE FUNCTION update_daily_pnl() RETURNS trigger AS $$
DECLARE
    v_close_date DATE;
    v_is_win INTEGER;
    v_is_loss INTEGER;
BEGIN
    IF NEW.status IN ('TP_REACHED', 'SL_REACHED', 'CLOSED_MANUAL', 'CLOSED_BY_PRICE_RACE')
       AND OLD.status IS DISTINCT FROM NEW.status
       AND NEW.close_timestamp IS NOT NULL THEN
        v_close_date := NEW.close_timestamp::date;
        -- Ganadora si profit_loss > 0, perdedora en cualquier otro
        -- caso (incluye 0, empate cuenta como no-win).
        v_is_win := CASE WHEN COALESCE(NEW.profit_loss, 0) > 0 THEN 1 ELSE 0 END;
        v_is_loss := CASE WHEN COALESCE(NEW.profit_loss, 0) > 0 THEN 0 ELSE 1 END;

        INSERT INTO daily_pnl (date, profit_loss, wins, losses, instruments, operable, updated_at)
        VALUES (v_close_date, COALESCE(NEW.profit_loss, 0), v_is_win, v_is_loss, NEW.instrument, TRUE, NOW())
        ON CONFLICT (date) DO UPDATE SET
            profit_loss = daily_pnl.profit_loss + COALESCE(EXCLUDED.profit_loss, 0),
            wins = daily_pnl.wins + EXCLUDED.wins,
            losses = daily_pnl.losses + EXCLUDED.losses,
            instruments = (
                SELECT string_agg(DISTINCT instr, ', ' ORDER BY instr)
                FROM unnest(
                    string_to_array(COALESCE(daily_pnl.instruments, ''), ', ')
                    || string_to_array(COALESCE(EXCLUDED.instruments, ''), ', ')
                ) AS instr
                WHERE instr <> ''
            ),
            operable = TRUE,
            updated_at = NOW();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_daily_pnl ON signals;
CREATE TRIGGER trg_update_daily_pnl
    AFTER UPDATE ON signals
    FOR EACH ROW
    EXECUTE FUNCTION update_daily_pnl();
