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
-- capital_real es reportado automáticamente por el EA de MT4 como
-- AccountBalance() completo (incluye crédito del bróker, decisión
-- explícita del usuario 2026-08-28), no editado a mano en operación
-- normal.
--
-- day_start_capital / day_start_date (agregado 2026-08-28, SOLO
-- usado por la auto-confirmación experimental de split-dev): capital
-- registrado al inicio del día en curso, para calcular la ganancia
-- del día como (capital_real - day_start_capital) / day_start_capital.
-- Se resetea automáticamente cuando day_start_date != CURRENT_DATE
-- (ver workflow split-dev/02-señal-nueva-parseo-confirmado.json).
-- NOTA DE DESPLIEGUE: en una base ya existente (creada antes de este
-- cambio) hay que agregar las columnas a mano con:
--   ALTER TABLE settings ADD COLUMN IF NOT EXISTS day_start_capital REAL;
--   ALTER TABLE settings ADD COLUMN IF NOT EXISTS day_start_date DATE;
--   ALTER TABLE settings ADD COLUMN IF NOT EXISTS capital_inicial_plan REAL;
-- (capital_inicial_plan documentado más abajo, junto a la definición
-- de la columna, agregado en la misma sesión).
-- Este CREATE TABLE con IF NOT EXISTS no las agrega a una tabla que
-- ya existe (mismo patrón conocido que el resto de columnas nuevas
-- del proyecto, ver punto 21 de STATUS.md).
-- =========================================================
-- capital_inicial_plan (agregado 2026-08-28): ancla manual, de una
-- sola vez, del capital con el que arrancó el plan de trading — mismo
-- concepto que "Capital inicial" en la sección Crecimiento de
-- PVG_kronos. A diferencia de capital_real, este SÍ requiere una
-- edición manual inicial (no lo reporta el EA); se usa en
-- GET /api/registros (dashboard/main.py) para reconstruir el capital
-- de cada día como capital_inicial_plan + suma acumulada de
-- daily_pnl.profit_loss hasta esa fecha.
CREATE TABLE IF NOT EXISTS settings (
    id                  SERIAL PRIMARY KEY,
    capital_real         REAL NOT NULL,
    day_start_capital     REAL,
    day_start_date        DATE,
    capital_inicial_plan   REAL,
    updated_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- =========================================================
-- Tabla: signals_archive_summary
-- Compactación automática de signals (ver trigger más abajo). Cuando
-- signals supera 20 filas, las más viejas (todo el excedente sobre
-- 20, no solo 1) se borran de signals y su agregado se acumula en
-- UNA ÚNICA fila (id=1, UPSERT) — no una fila nueva por cada tanda
-- archivada. Corrige un bug real: como el trigger dispara después de
-- cada INSERT y el excedente casi siempre es 1, la versión anterior
-- (INSERT por tanda) terminaba creando una fila nueva por señal
-- archivada — exactamente el crecimiento sin límite que esta tabla
-- pretendía evitar (detectado 2026-08-21, signals_archive_summary
-- había crecido a 44 filas). Se pierde el detalle fila por fila de lo
-- archivado, se conserva el agregado corriendo (conteos por status,
-- instrumentos, profit_loss total) en una sola fila que crece en
-- valor, no en cantidad de filas.
-- =========================================================
CREATE TABLE IF NOT EXISTS signals_archive_summary (
    id                  INTEGER PRIMARY KEY DEFAULT 1,
    period_start         TIMESTAMP,
    period_end            TIMESTAMP,
    signal_count           INTEGER NOT NULL DEFAULT 0,
    -- Conteo acumulado de filas por status, ej: {"OPEN": 5, "EXPIRED": 2}
    status_counts            JSONB NOT NULL DEFAULT '{}'::jsonb,
    instruments                TEXT,
    total_profit_loss            REAL,
    updated_at                    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT signals_archive_summary_single_row CHECK (id = 1)
);

-- =========================================================
-- Trigger: compact_old_signals
-- Se dispara después de cada INSERT en signals. Si la tabla supera
-- 20 filas, archiva TODO el excedente (no solo 1 fila) — deja
-- siempre como máximo 20 filas activas en signals. Borra primero
-- signal_modifications de las filas archivadas (no hay ON DELETE
-- CASCADE en esa FK) para no romper la referencia. El agregado de lo
-- archivado se acumula en la única fila (id=1) de
-- signals_archive_summary vía UPSERT, nunca inserta una fila nueva.
-- =========================================================
CREATE OR REPLACE FUNCTION compact_old_signals() RETURNS trigger AS $$
DECLARE
    excess_count INTEGER;
    v_period_start TIMESTAMP;
    v_period_end TIMESTAMP;
    v_signal_count INTEGER;
    v_status_counts JSONB;
    v_instruments TEXT;
    v_total_pl REAL;
BEGIN
    SELECT GREATEST(COUNT(*) - 20, 0) INTO excess_count FROM signals;

    IF excess_count = 0 THEN
        RETURN NULL;
    END IF;

    -- DROP explícito antes de crear: "ON COMMIT DROP" solo limpia la
    -- tabla temporal si la transacción efectivamente hace COMMIT. Si
    -- una conexión pooled (ej. el nodo Postgres de n8n) deja una
    -- transacción sin cerrar, la tabla persiste en esa sesión y el
    -- próximo INSERT en signals revienta con "relation already
    -- exists", bloqueando TODA inserción nueva hasta reiniciar n8n
    -- (incidente real, 2026-08-18). Este DROP hace que la función sea
    -- inmune a esa sesión colgada sin depender de por qué quedó así.
    DROP TABLE IF EXISTS _signals_to_archive;

    CREATE TEMP TABLE _signals_to_archive ON COMMIT DROP AS
    SELECT id, created_at, status, instrument, profit_loss
    FROM signals
    ORDER BY created_at ASC
    LIMIT excess_count;

    DELETE FROM signal_modifications
    WHERE signal_id IN (SELECT id FROM _signals_to_archive);

    DELETE FROM signals
    WHERE id IN (SELECT id FROM _signals_to_archive);

    SELECT MIN(created_at), MAX(created_at), COUNT(*),
           string_agg(DISTINCT instrument, ', '), SUM(profit_loss)
    INTO v_period_start, v_period_end, v_signal_count, v_instruments, v_total_pl
    FROM _signals_to_archive;

    SELECT jsonb_object_agg(status, cnt) INTO v_status_counts
    FROM (SELECT status, COUNT(*) AS cnt FROM _signals_to_archive GROUP BY status) s;

    INSERT INTO signals_archive_summary
        (id, period_start, period_end, signal_count, status_counts, instruments, total_profit_loss, updated_at)
    VALUES (1, v_period_start, v_period_end, v_signal_count, v_status_counts, v_instruments, v_total_pl, NOW())
    ON CONFLICT (id) DO UPDATE SET
        period_start = LEAST(signals_archive_summary.period_start, EXCLUDED.period_start),
        period_end   = GREATEST(signals_archive_summary.period_end, EXCLUDED.period_end),
        signal_count = signals_archive_summary.signal_count + EXCLUDED.signal_count,
        status_counts = (
            SELECT jsonb_object_agg(key, sum_val)
            FROM (
                SELECT key, SUM(val::int) AS sum_val
                FROM (
                    SELECT * FROM jsonb_each_text(signals_archive_summary.status_counts)
                    UNION ALL
                    SELECT * FROM jsonb_each_text(EXCLUDED.status_counts)
                ) t(key, val)
                GROUP BY key
            ) merged
        ),
        instruments = (
            SELECT string_agg(DISTINCT instr, ', ' ORDER BY instr)
            FROM unnest(
                string_to_array(COALESCE(signals_archive_summary.instruments, ''), ', ')
                || string_to_array(COALESCE(EXCLUDED.instruments, ''), ', ')
            ) AS instr
            WHERE instr <> ''
        ),
        total_profit_loss = COALESCE(signals_archive_summary.total_profit_loss, 0) + COALESCE(EXCLUDED.total_profit_loss, 0),
        updated_at = NOW();

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_compact_old_signals ON signals;
CREATE TRIGGER trg_compact_old_signals
    AFTER INSERT ON signals
    FOR EACH STATEMENT
    EXECUTE FUNCTION compact_old_signals();

-- =========================================================
-- NOTA DE DESPLIEGUE: en una base ya existente (creada antes de este
-- cambio) hay que aplicar a mano el bloque completo de daily_pnl +
-- update_daily_pnl + trg_update_daily_pnl que sigue — el
-- docker-entrypoint-initdb.d solo corre en un volumen nuevo, no
-- reaplica este archivo sobre una base que ya existe.
--
-- Tabla: daily_pnl (agregado 2026-08-28)
-- Recap diario de ganancia/pérdida real, pensado para alimentar el
-- panel "Crecimiento"/"Calendario" de PVG_kronos (integrado como
-- herramienta externa, ver PVG_kronos/docs/INTEGRACION_KRONOS_BOT.md)
-- sin depender de carga manual. Se llena en tiempo real vía trigger
-- (ver trg_update_daily_pnl más abajo), no por un job batch — así no
-- se pierde nada aunque compact_old_signals() borre el detalle de
-- signals más adelante (el agregado diario ya quedó grabado antes de
-- que eso ocurra).
--
-- "operable" = hubo al menos un cierre real ese día (decisión
-- explícita del usuario, 2026-08-28: un día operable se define por
-- actividad real, no por día de la semana — pueden operarse domingos
-- según el instrumento).
-- =========================================================
-- NOTA DE DESPLIEGUE: si `daily_pnl` ya existía sin wins/losses/
-- instruments (creada en una sesión anterior de este mismo día),
-- agregar a mano:
--   ALTER TABLE daily_pnl ADD COLUMN IF NOT EXISTS wins INTEGER NOT NULL DEFAULT 0;
--   ALTER TABLE daily_pnl ADD COLUMN IF NOT EXISTS losses INTEGER NOT NULL DEFAULT 0;
--   ALTER TABLE daily_pnl ADD COLUMN IF NOT EXISTS instruments TEXT;
--
-- wins/losses/instruments (agregado 2026-08-28): permiten que el
-- workflow "Kronos Dev 08 - Resumen diario" (vivo en n8n dev desde
-- antes, nunca sincronizado al repo hasta ahora — ver
-- n8n-workflows/split-dev/08-resumen-diario.json) lea el recap
-- completo desde acá en vez de agregarlo en vivo contra `signals`.
-- Esa versión anterior tenía el mismo riesgo de pérdida de datos que
-- signals_archive_summary: si compact_old_signals() archiva señales
-- cerradas más temprano el mismo día, antes de que el resumen de las
-- 11am las lea, esas operaciones desaparecen del recap sin aviso.
-- daily_pnl no tiene ese problema porque captura en el momento del
-- cierre, no al final del día.
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
        -- Mismo criterio que ya usaba la versión en vivo del workflow
        -- 08 contra `signals`: ganadora si profit_loss > 0, perdedora
        -- en cualquier otro caso (incluye 0, empate cuenta como no-win).
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
