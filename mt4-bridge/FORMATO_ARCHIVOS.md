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
| `lot` | number | Dinámico, calculado por n8n antes de escribir el archivo: `floor(capital_real / 100) * 0.01`, con piso `0.01` si el resultado da 0 o negativo (protocolo sección 5.2). Se recalcula contra el `capital_real` actual en `settings` en cada confirmación — no queda pegado a un máximo histórico. Redondeado a 2 decimales. Distinto del cálculo de slots 80/20 de la sección 5.3, que sigue sin conectar al flujo real. |
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

## 4. Configuración dinámica — `mt4-bridge/orders/config.json` (opcional, lado EA)

Archivo opcional, escrito por un dashboard externo (fuera de este
documento del lado del EA — ver la documentación del dashboard para
cómo lo genera). El EA lo lee al inicio de **cada ciclo** de
`OnTimer()`, antes de procesar `pending/`. Si no existe, o el JSON no
parsea, o el valor no es uno de los dos soportados, el EA lo ignora
silenciosamente y conserva el último `symbol_suffix` válido (o el
input `InpSymbolSuffix` si todavía no leyó ninguno).

```json
{ "symbol_suffix": "-STD" }
```

| Campo | Tipo | Notas |
|---|---|---|
| `symbol_suffix` | string | Únicos valores válidos: `"-VIP"` (cuenta demo) o `"-STD"` (cuenta real). Cualquier otro valor se ignora (validación estricta, igual criterio que `ResolveBrokerSymbol` con los instrumentos). Permite cambiar de cuenta sin recompilar el EA. |

No se borra tras leerlo (a diferencia de `pending/`/`results/`) — se
relee en cada ciclo porque representa configuración persistente, no
un evento puntual.

## 5. Reporte de posiciones abiertas — `mt4-bridge/orders/status.json` (lado EA)

Escrito por el EA al final de **cada ciclo** de `OnTimer()` (se
sobrescribe completo, no se acumula). Contiene **todas** las
posiciones de mercado (`OP_BUY`/`OP_SELL`) abiertas en la cuenta,
tanto las de este EA como las abiertas manualmente por el usuario en
MT4 — cada posición lleva `"managed"` (`true` si su
`OrderMagicNumber()` coincide con `InpMagicNumber`, `false` si es
operativa manual) para que el dashboard las distinga sin mezclarlas.

```json
{
  "updated_at": "2026-08-16T10:00:00Z",
  "account": { "number": 23096429, "balance": 1000.00, "equity": 998.50 },
  "positions": [
    {
      "ticket": 123456789,
      "managed": true,
      "signal_uid": "1192-A",
      "symbol": "XAUUSD-STD",
      "direction": "BUY",
      "lot": 0.01,
      "open_price": 4372.30,
      "current_price": 4371.80,
      "sl": 4347.0,
      "tp": 4376.0,
      "profit": -0.50,
      "open_time": "2026-08-16T09:55:00Z"
    }
  ]
}
```

`signal_uid` se extrae del `OrderComment()` (`"KronosBot:" +
signal_uid`, ver sección 1) solo cuando `managed=true`; en posiciones
manuales viene vacío. `current_price` es el precio al que la posición
se podría cerrar ahora mismo (Bid para BUY, Ask para SELL). Archivo de
solo lectura para consumidores externos (dashboard); el EA nunca lo
lee, solo lo escribe.

El dashboard solo permite encolar acciones (`SET_BE`/`SET_TP_BE`/
`CLOSE`) sobre tickets con `managed=true` — `ProcessActionFile` en el
EA de todos modos ignora acciones sobre tickets sin su
`InpMagicNumber`, así que esto es una validación redundante en el
dashboard para no encolar comandos que nunca se van a ejecutar.

## 6. Convención de limpieza

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
    { "ticket": 202201987, "managed": true, "signal_uid": "1192-A", "symbol": "XAUUSD-VIP",
      "direction": "BUY", "lot": 0.01, "open_price": 4390.13,
      "current_price": 4392.0, "sl": 4370.0, "tp": 4410.0,
      "profit": 1.87, "open_time": "2026-08-17T00:28:56Z" }
  ]
}
```

Ver sección 5 para el detalle completo de `managed` (posiciones
propias del EA vs. manuales del usuario).

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

### 4.3 Comandos sobre posiciones abiertas — `mt4-bridge/orders/actions/{ticket}-{action}.json`

El dashboard los escribe (`POST /api/positions/<ticket>/action`); el
EA los lee en cada ciclo de `OnTimer` (antes de reescribir
`status.json`), ejecuta el comando y borra el archivo siempre
(éxito o fallo) — mismo criterio de limpieza que `pending/`.

```json
{ "ticket": 202230990, "action": "SET_BE" }
```

| Campo | Tipo | Notas |
|---|---|---|
| `ticket` | int | Ticket real de MT4, tiene que aparecer en el último `status.json` reportado — el dashboard rechaza tickets inventados o ya cerrados con 404 antes de escribir el archivo. |
| `action` | string | `"SET_BE"` (mueve el SL al precio de apertura), `"SET_TP_BE"` (BE inverso: mueve el TP al precio de apertura, no el SL) o `"CLOSE"` (cierra a mercado). Cualquier otro valor se rechaza con 400 del lado del dashboard. |

El EA solo actúa si el ticket tiene el mismo `InpMagicNumber` de este
EA — nunca toca operativa manual del usuario en la misma cuenta,
aunque alguien escriba un ticket válido de otra operación a mano.

El nombre de archivo incluye la acción (`{ticket}-{action}.json`, no
solo `{ticket}.json`) para que un `SET_BE` y un `CLOSE` mandados casi
juntos sobre el mismo ticket no se pisen entre sí — el EA procesa los
dos en el mismo ciclo si hace falta.

### 4.4 Resultado de un comando — `mt4-bridge/orders/action_results/{ticket}-{action}.json`

El EA lo escribe después de intentar `SET_BE`/`CLOSE` (éxito o
fallo); el dashboard lo lee (`GET
/api/positions/<ticket>/action_result?action=...`) para mostrar el
resultado real en vez de inferirlo comparando el estado de la
posición — un `SET_BE` puede fallar legítimamente (ej. `OrderModify`
rechazado por el bróker si la posición todavía está en pérdida, el
SL de break-even quedaría del lado equivocado del precio actual) y
sin este archivo no había forma de distinguir "todavía no lo
procesó" de "lo procesó y falló".

```json
{
  "ticket": 202230990,
  "action": "SET_BE",
  "success": true,
  "result_price": 4398.13,
  "error_code": null,
  "error_message": null,
  "processed_at": "2026-08-17T06:00:00Z"
}
```

| Campo | Tipo | Notas |
|---|---|---|
| `result_price` | number \| null | SL nuevo si `SET_BE` tuvo éxito, TP nuevo si `SET_TP_BE` tuvo éxito, precio de cierre si `CLOSE` tuvo éxito. `null` si falló. |
| `error_code` | int \| null | Código nativo de MQL4 (`GetLastError()`). `null` si tuvo éxito. |
| `error_message` | string \| null | `"MT4 error {code}"` — sin traducción a texto legible todavía, el dashboard muestra el código tal cual. `null` si tuvo éxito. |

El dashboard borra cualquier resultado anterior del mismo
`{ticket}-{action}` **antes** de encolar un comando nuevo (en `POST
/api/positions/<ticket>/action`), para que el polling del frontend
nunca confunda un resultado viejo con el del intento actual.
