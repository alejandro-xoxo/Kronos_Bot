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
  también. **Implementado (Etapa 5):** un `Schedule Trigger` cada 5
  segundos lee `results/*.json` con `readWriteFile` (operation
  `read`, soporta glob), actualiza `signals.status`/`mt4_ticket` en
  Postgres con un `UPDATE` idempotente (`WHERE status = 'CONFIRMED'`),
  notifica por Telegram si corresponde, y borra el archivo con
  `fs.promises.unlink` siempre (haya notificado o no).
- Si un archivo de `results/` no aparece dentro de un timeout
  razonable después de escribir el `pending/` correspondiente, es un
  caso de fallo de comunicación. El protocolo de reintento/alerta
  para ese caso se define al implementar el EA (Fase 6, pendiente),
  no en este documento de diseño.
