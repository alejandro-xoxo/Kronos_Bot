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
        'CLOSE_AT_PRICE'
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
