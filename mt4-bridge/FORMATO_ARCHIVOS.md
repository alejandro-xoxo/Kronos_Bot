# Formato de archivos del puente n8n ↔ EA (MT4)

Diseño del mecanismo de comunicación entre n8n y el EA puente en MT4,
vía archivos JSON en disco. Este documento define el formato exacto
**antes** de escribir el EA en MQL4 (Fase 6). No implementa código
MQL4 — solo el contrato de datos entre ambos lados.

## Mecanismo general

- n8n escribe un archivo de orden en `mt4-bridge/orders/pending/`
  cuando el usuario confirma una señal (botón "✅ Confirmar" en
  Telegram).
- El EA hace polling de esa carpeta, ejecuta la orden en MT4, y
  escribe el resultado en `mt4-bridge/orders/results/`.
- n8n hace polling de `results/` para actualizar Postgres
  (`signals.mt4_ticket`, `signals.status`) y notificar al usuario
  por Telegram.

**Identificador de correlación:** `signal_id` = el `id` numérico de
Postgres (la misma PK que ya viaja en el `callback_data` de los
botones de Telegram y en los `UPDATE` de status del flujo de
confirmación). Se reutiliza este id en vez de inventar uno nuevo.

## 1. Orden pendiente — `mt4-bridge/orders/pending/{signal_id}.json`

```json
{
  "signal_id": 42,
  "signal_uid": "1192-A",
  "instrument": "XAUUSD",
  "direction": "BUY",
  "execution_type": "MARKET",
  "entry_price": 4372.0,
  "sl": 4347.0,
  "tp": 4376.0,
  "lot": 0.01,
  "created_at": "2026-08-14T13:24:00Z"
}
```

| Campo | Tipo | Notas |
|---|---|---|
| `signal_id` | int | Coincide con el nombre del archivo, redundante a propósito para que el EA pueda loguear sin parsear el nombre. |
| `signal_uid` | string | Solo trazabilidad/logs legibles (ej. `"1192-A"`). El EA no lo usa funcionalmente. |
| `instrument` | string | Símbolo tal como lo espera MT4 (ej. `"XAUUSD"`). |
| `direction` | string | `"BUY"` o `"SELL"`, ya normalizado. |
| `execution_type` | string | `"MARKET"` o `"LIMIT"` — únicos dos valores válidos, el EA no interpreta texto libre. |
| `entry_price` | number | Precio de entrada de la señal (referencia para LIMIT; informativo en MARKET). |
| `sl` | number | Stop loss. |
| `tp` | number | Take profit (ya resuelto a un solo valor por sub-señal — ver protocolo sección 4.2 regla 6). |
| `lot` | number | Fijo `0.01` por ahora (protocolo sección 5, MVP sin cálculo de slots conectado). |
| `created_at` | string | ISO 8601 UTC. Para logging/diagnóstico de antigüedad del lado del EA, no para revalidar los 5 minutos (esa regla ya se aplicó en n8n antes de confirmar). |

## 2. Resultado de ejecución — `mt4-bridge/orders/results/{signal_id}.json`

**Caso éxito:**

```json
{
  "signal_id": 42,
  "success": true,
  "ticket": 123456789,
  "executed_price": 4372.30,
  "executed_at": "2026-08-14T13:24:05Z",
  "error_code": null,
  "error_message": null
}
```

**Caso fallo:**

```json
{
  "signal_id": 42,
  "success": false,
  "ticket": null,
  "executed_price": null,
  "executed_at": "2026-08-14T13:24:05Z",
  "error_code": 130,
  "error_message": "Invalid stops"
}
```

| Campo | Tipo | Notas |
|---|---|---|
| `signal_id` | int | Igual al de la orden pendiente correspondiente. |
| `success` | bool | `true`/`false`. |
| `ticket` | int \| null | Ticket real de MT4 — alimenta `signals.mt4_ticket` (columna ya existente en el schema) para el ciclo de cierre posterior. `null` si `success = false`. |
| `executed_price` | number \| null | Precio real de ejecución. Puede diferir de `entry_price` en órdenes a mercado (slippage) — nunca se asume que coincide. `null` si falló. |
| `executed_at` | string | ISO 8601 UTC. |
| `error_code` | int \| null | Código nativo de MQL4 (`GetLastError()`) cuando `success = false`, para diagnóstico exacto sin depender de interpretar texto. `null` si tuvo éxito. |
| `error_message` | string \| null | Mensaje legible del error. `null` si tuvo éxito. |

## 3. Convención de limpieza

- El EA, tras leer un archivo de `pending/`, lo **borra inmediatamente**
  (no lo deja mientras ejecuta, para no reprocesarlo por timing del
  polling).
- n8n, tras leer y procesar un archivo de `results/`, lo **borra**
  también.
- Si un archivo de `results/` no aparece dentro de un timeout
  razonable después de escribir el `pending/` correspondiente, es un
  caso de fallo de comunicación. El protocolo de reintento/alerta
  para ese caso se define al implementar el EA (Fase 6, pendiente),
  no en este documento de diseño.

## 4. Estado de cuenta/posiciones y config del símbolo — dashboard web

Contrato adicional entre el EA y el dashboard web (`dashboard/`,
servicio Docker nuevo, puerto 8088). A diferencia de `pending/` y
`results/` (que son colas de un solo uso, se leen y se borran), estos
dos archivos viven directamente en `mt4-bridge/orders/` y se
sobrescriben en el lugar — no hay borrado ni cola.

### 4.1 Estado de cuenta y posiciones — `mt4-bridge/orders/status.json`

El EA lo escribe periódicamente (polling, no evento) con el estado
actual de la cuenta y las posiciones abiertas. El dashboard solo lee
este archivo, nunca lo escribe.

```json
{
  "updated_at": "2026-08-17T00:00:00Z",
  "account": { "number": 23096429, "balance": 1000.0, "equity": 1005.2 },
  "positions": [
    { "ticket": 202201987, "signal_uid": "1192-A", "symbol": "XAUUSD-VIP",
      "direction": "BUY", "lot": 0.01, "open_price": 4390.13,
      "current_price": 4392.0, "sl": 4370.0, "tp": 4410.0,
      "profit": 1.87, "open_time": "2026-08-17T00:28:56Z" }
  ]
}
```

| Campo | Tipo | Notas |
|---|---|---|
| `updated_at` | string | ISO 8601 UTC de la última escritura del EA. |
| `account.number` | int | Número de cuenta MT4. |
| `account.balance` | number | Balance de la cuenta. |
| `account.equity` | number | Equity actual (balance ± flotante). |
| `positions[].ticket` | int | Ticket real de MT4. |
| `positions[].signal_uid` | string | Trazabilidad hacia `signals.signal_uid` en Postgres. |
| `positions[].symbol` | string | Símbolo tal como lo reporta MT4, **con sufijo del bróker incluido** (ej. `"XAUUSD-VIP"`). |
| `positions[].direction` | string | `"BUY"` o `"SELL"`. |
| `positions[].lot`, `open_price`, `current_price`, `sl`, `tp`, `profit` | number | Estado en vivo de la posición. |
| `positions[].open_time` | string | ISO 8601 UTC. |

El dashboard (`GET /api/positions`) sirve el contenido de este
archivo tal cual. Si el archivo todavía no existe (el EA no arrancó
o no llegó a su primer ciclo de escritura), el endpoint responde
`{"positions": [], "account": null, "stale": true}` con status 200
— es un estado esperado antes/durante el arranque, no un error.

### 4.2 Configuración de sufijo de símbolo — `mt4-bridge/orders/config.json`

El dashboard lo escribe (`POST /api/config` desde la UI web); el EA
lo lee para saber qué sufijo de símbolo del bróker anteponer al
instrumento (`XAUUSD` → `XAUUSD-VIP` en demo, `XAUUSD-STD` en real)
al ejecutar órdenes.

```json
{ "symbol_suffix": "-STD" }
```

| Campo | Tipo | Notas |
|---|---|---|
| `symbol_suffix` | string | Únicos dos valores válidos: `"-VIP"` (demo) o `"-STD"` (real). El dashboard rechaza cualquier otro valor con 400 antes de escribir el archivo — el EA no necesita validar texto libre. |

Si el archivo no existe todavía, `GET /api/config` del dashboard
responde `{"symbol_suffix": null}` con status 200.
