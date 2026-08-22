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
CREATE TABLE IF NOT EXISTS settings (
    id                  SERIAL PRIMARY KEY,
    capital_real         REAL NOT NULL,
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
