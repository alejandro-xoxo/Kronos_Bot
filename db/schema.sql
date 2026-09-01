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
-- Se resetea automáticamente cuando day_start_date != la fecha actual
-- en horario de Colombia — no CURRENT_DATE crudo (bug real detectado
-- 2026-09-01: el contenedor de Postgres corre en UTC, así que
-- CURRENT_DATE saltaba de día 5 horas antes de medianoche en
-- Colombia; corregido calculando la fecha con
-- (NOW() AT TIME ZONE 'America/Bogota')::date en el workflow, ver
-- split-dev/02-señal-nueva-parseo-confirmado.json).
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
-- Revertido 2026-08-31 (decisión explícita del usuario, misma sesión
-- que capital_real): el crédito del bróker cuenta como capital real,
-- no se excluye de este ancla — reversa una decisión de más temprano
-- ese mismo día que lo fijaba SIN crédito para no mezclar unidades
-- con capital_end_of_day (ver nota de esa columna, más abajo, y
-- n8n-workflows/split-dev/09-sync-capital-real.json). Requiere un
-- UPDATE manual, una sola vez, para llevar el valor existente (fijado
-- sin crédito) a la misma unidad que capital_real:
--   UPDATE settings SET capital_inicial_plan = capital_real
--   WHERE id = (SELECT id FROM settings ORDER BY id DESC LIMIT 1);
-- (o el valor manual que corresponda si capital_inicial_plan no debe
-- ser exactamente el capital_real de hoy). Sin este UPDATE, el KPI
-- "Capital actual"/porcentaje de ganancia de PVG_kronos queda
-- comparando unidades distintas (ancla sin crédito vs. capital en
-- vivo con crédito) hasta que se corrija a mano.
--
-- circuit_breaker_pct (agregado 2026-09-01): umbral de ganancia
-- diaria (fracción, ej. 0.06 = 6%) del circuit breaker de Fase 2
-- (PROTOCOLOS_KRONOS_BOT.md sección 12.3) — antes hardcodeado como
-- 0.06 en el nodo "¿Ganancia del día <6%?" de
-- n8n-workflows/split-mvp|split-dev/02-señal-nueva-parseo-confirmado.json.
-- Editable desde el panel de control del dashboard
-- (GET/POST /api/circuit-breaker en dashboard/main.py). El nodo lee
-- este valor con COALESCE(circuit_breaker_pct, 0.06) para que una
-- base ya existente sin el UPDATE inicial siga operando con el 6%
-- de siempre.
-- NOTA DE DESPLIEGUE: en una base ya existente hay que agregar la
-- columna a mano con:
--   ALTER TABLE settings ADD COLUMN IF NOT EXISTS circuit_breaker_pct REAL;
--   UPDATE settings SET circuit_breaker_pct = 0.06
--   WHERE id = (SELECT id FROM settings ORDER BY id DESC LIMIT 1);
CREATE TABLE IF NOT EXISTS settings (
    id                  SERIAL PRIMARY KEY,
    capital_real         REAL NOT NULL,
    day_start_capital     REAL,
    day_start_date        DATE,
    capital_inicial_plan   REAL,
    circuit_breaker_pct    REAL,
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
-- capital_end_of_day (agregado 2026-08-31): snapshot del capital real
-- de la cuenta para ese día, CON crédito del bróker (account.capital_real
-- de orders/status.json = AccountBalance() + AccountCredit(), mismo
-- valor que settings.capital_real), actualizado automáticamente cada
-- 5s por n8n-workflows/split-dev/09-sync-capital-real.json (solo dev
-- por ahora — no hay equivalente en split-mvp/producción todavía).
-- Revertido el mismo día 2026-08-31 (decisión explícita del usuario):
-- una versión anterior de esta columna, en esta misma sesión, guardaba
-- el snapshot SIN crédito (account.balance) para que fuera comparable
-- con capital_inicial_plan (que en ese momento tampoco lo incluía) —
-- el usuario pidió expresamente lo contrario: el crédito cuenta como
-- capital real de trabajo, así que capital_end_of_day vuelve a usar
-- capital_real completo, y capital_inicial_plan se actualiza a la
-- misma unidad (ver nota de esa columna, más arriba, con el UPDATE
-- manual de una sola vez necesario). A diferencia de profit_loss (que
-- solo suma cierres de señales del bot vía el trigger de abajo), este
-- campo captura el capital real completo de la cuenta — incluye
-- operaciones abiertas manualmente en MT4, que nunca pasan por
-- `signals` y por lo tanto nunca disparan el trigger.
-- /api/registros (dashboard/main.py) prioriza este campo sobre el
-- profit_loss acumulado cuando está disponible, para que el gráfico
-- de Crecimiento refleje el capital real, no solo lo operado por el
-- bot. NULL en días anteriores a este cambio, o si status.json no
-- trae account.capital_real por algún motivo — esos casos siguen
-- calculándose con el método viejo (capital_inicial_plan + suma de
-- profit_loss), sin romper el histórico ya existente.
--
-- NOTA DE DESPLIEGUE: si `daily_pnl` ya existía sin esta columna
-- (creada en una sesión anterior a este cambio), agregar a mano:
--   ALTER TABLE daily_pnl ADD COLUMN IF NOT EXISTS capital_end_of_day REAL;
CREATE TABLE IF NOT EXISTS daily_pnl (
    date                DATE PRIMARY KEY,
    profit_loss          REAL NOT NULL DEFAULT 0,
    wins                  INTEGER NOT NULL DEFAULT 0,
    losses                INTEGER NOT NULL DEFAULT 0,
    instruments            TEXT,
    operable              BOOLEAN NOT NULL DEFAULT TRUE,
    capital_end_of_day    REAL,
    updated_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Eliminado 2026-08-31 (decisión explícita del usuario): existía un
-- trigger update_daily_pnl/trg_update_daily_pnl que autocompletaba
-- profit_loss/wins/losses/instruments en daily_pnl al cerrar una
-- señal, usando NEW.close_timestamp::date para elegir el día. Se sacó
-- porque generaba registros en la fecha equivocada (se detectó el
-- 2026-08-31: cierres de hoy quedaban registrados el domingo) — la
-- causa de fondo (desfase de timezone/valor de close_timestamp entre
-- lo que escribe n8n y la fecha real del cierre) no se investigó a
-- fondo porque el usuario prefiere cargar wins/losses/profit_loss a
-- mano en PVG en vez de confiar en el auto-registro. capital_end_of_day
-- (arriba) sigue siendo automático vía el sync de capital_real — esto
-- solo afecta profit_loss/wins/losses/instruments.
