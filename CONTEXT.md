# Kronos Bot — Contexto técnico del sistema

> Este documento explica **cómo funciona** el sistema completo: arquitectura,
> componentes, modelo de datos, contratos de comunicación y reglas de negocio
> clave. Es complementario a `STATUS.md` (que documenta **qué tan avanzado**
> está cada pieza, qué falta y qué problemas siguen abiertos) — para eso, ver
> `STATUS.md`, no este archivo.

## 1. Qué es el proyecto

Kronos Bot es un copiador semi-automático de señales de trading: escucha un
grupo de Telegram ("VIP SIGNALS FX - ESPAÑA") donde un caller publica señales
de compra/venta en formato fijo, las interpreta, pide confirmación humana por
Telegram, y al confirmarse las ejecuta de verdad en una cuenta MT4 real de
VT Markets. También interpreta instrucciones de seguimiento en lenguaje libre
(mover SL, break-even, cerrar) usando Gemini, y detecta cuándo una operación
cierra en el bróker para actualizar su estado. Todo orquestado por n8n, con
Postgres como base de datos y un Expert Advisor (EA) en MQL4 como único punto
de contacto real con MT4.

## 2. Arquitectura general — flujo completo

```
Telegram (grupo VIP SIGNALS FX)
    │  (Telethon, cuenta de usuario vía MTProto — el usuario no es admin)
    ▼
Microservicio Telethon (Docker, Python)
    │  POST webhook con message_id, chat_id, sender, text, timestamp,
    │  reply_to_message_id + header X-Kronos-Secret
    ▼
n8n — Webhook Telethon (POST /webhook/kronos-telethon-signal)
    │
    ├── ¿Secreto de webhook válido? ── no → descarta
    │
    ├── ¿Coincide formato fijo de señal nueva? (Parsear señal (regex))
    │       sí → hasta N sub-señales (una por cada TP del mensaje)
    │       │
    │       ▼
    │   Insertar señal (Postgres, status=PENDING_CONFIRMATION)
    │       │
    │       ▼
    │   Notificar Telegram (chat privado del usuario, botones
    │   Confirmar/Rechazar por sub-señal)
    │       │
    │       ▼
    │   Trigger Callback Telegram (usuario presiona un botón)
    │       │
    │       ├── Confirmar → Actualizar status: CONFIRMED
    │       │       │
    │       │       ▼
    │       │   Obtener señal confirmada → Obtener capital real (settings)
    │       │       → Preparar orden pending (JSON) → Escribir orden
    │       │       pending (MT4) → mt4-bridge/orders/pending/{id}.json
    │       │       │
    │       │       ▼  (lado MT4, ver sección 5)
    │       │   EA puente ejecuta la orden real → escribe
    │       │       mt4-bridge/orders/results/{id}.json
    │       │       │
    │       │       ▼
    │       │   Trigger: leer resultados MT4 (cada 5s) → Parsear
    │       │       resultado (MT4) → Actualizar status: OPEN/
    │       │       PENDING_MANUAL → Avisar en chat: Resultado MT4
    │       │
    │       └── Rechazar → Actualizar status: REJECTED_BY_USER
    │           → Avisar en chat: Rechazada
    │
    └── ¿Es instrucción de seguimiento? (reply a una señal existente,
        redacción libre: mover SL, BE, cerrar...)
            │
            ▼
        Buscar señal referenciada → Clasificar seguimiento (regex,
        primer intento barato) → Enrutar clasificación → Expandir
        targets (si aplica a varias sub-señales relacionadas)
            │
            ▼
        Interpretar con Gemini (httpRequest) → Parsear respuesta
        Gemini → Insertar modificación (Postgres, signal_modifications)
            │
            ├── ¿Tiene acción EA? → sí → Preparar acción EA (JSON) →
            │   Escribir acción EA (MT4) → mt4-bridge/orders/actions/
            │   → Avisar en chat: Modificación aplicada
            │
            └── no → Avisar en chat: Registrada sin acción EA

Independiente del flujo anterior, en paralelo:

Trigger: leer cierres MT4 (cada 5s) → Leer cierres (MT4) → Parsear
cierre (MT4) → Actualizar status: cierre TP/SL (por signal_uid) →
Avisar en chat: Cierre TP/SL → Borrar archivo de cierre
```

Los nombres de nodo de arriba son los reales del workflow
(`n8n-workflows/webhook-mvp-workflow.json`), agrupados ahí en 5 sticky notes:
"1. Captura y parseo", "2. Confirmación Telegram", "3. Seguimiento (Fase 4)",
"4. Ejecución en MT4", "5. Detección de cierres TP-SL".

## 3. Componentes — un servicio Docker por responsabilidad

Todos los servicios viven en `docker-compose.yml`, en la red `trading_net`.

- **`n8n`** (imagen oficial, puerto `5678`) — orquestador central. Corre
  todo el workflow: recibe el webhook de Telethon, corre el parser regex,
  llama a Gemini, lee/escribe en Postgres, escribe/lee los archivos JSON del
  puente MT4, y manda las notificaciones de Telegram. Necesita
  `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` para que `$env` funcione dentro de
  expresiones de nodo, y `NODE_FUNCTION_ALLOW_BUILTIN=fs` para que los Code
  nodes puedan usar el módulo `fs` de Node (necesario para borrar los
  archivos de `results/`/`closed/` tras procesarlos). Tiene un bind mount
  `${MT4_ORDERS_HOST_PATH}:/mt4-bridge/orders` — n8n corre en contenedor y no
  ve el filesystem del host donde vive el prefijo de Wine, así que este mount
  apunta directo a la carpeta real `Common/Files/orders` de Wine (no al
  symlink del repo, que Docker no puede resolver si apunta fuera del árbol
  montado).
- **`postgres`** (`postgres:16-alpine`) — la base de datos de señales,
  modificaciones y configuración. `db/schema.sql` está montado como
  `docker-entrypoint-initdb.d/schema.sql`, así que si se recrea el volumen
  `postgres_data` desde cero, el schema se aplica solo, sin pasos manuales.
- **`telethon`** (build local, `telethon-service/`) — microservicio Python
  que mantiene una sesión de usuario de Telegram (MTProto, no bot API,
  porque el usuario no es admin del grupo) y reenvía cada mensaje nuevo del
  grupo al webhook de n8n (`N8N_WEBHOOK_URL`). Ver sección 3.1 más abajo
  para el detalle de captura.
- **`ngrok`** — expone `n8n:5678` en un dominio fijo (`N8N_HOST`) para que
  Telegram (webhooks de callback de botones) y Telethon puedan alcanzar a
  n8n desde fuera. No expone el `dashboard` — ese solo vive en
  localhost/LAN.
- **`dashboard`** (build local, `dashboard/`, Flask, puerto `8088`) — panel
  web de operación manual y monitoreo. Lee `mt4-bridge/orders/status.json`
  (que escribe el EA) para mostrar posiciones abiertas en vivo con
  precio/profit/SL/TP, y ofrece botones **BE**, **BE inverso (TP)** y
  **Cerrar** por posición, que encolan comandos en
  `mt4-bridge/orders/actions/` para que el EA los ejecute. También permite
  reintentar señales en `PENDING_MANUAL` (reescribe el archivo en
  `pending/`), ver historial de señales desde Postgres con filtros por
  período, y cambiar el sufijo de símbolo del bróker (`-VIP`/`-STD`) vía
  `mt4-bridge/orders/config.json`, que el EA relee en caliente sin
  recompilar. Sin autenticación — solo pensado para exposición local.

### 3.1 Captura de mensajes (Telethon)

`telethon-service/main.py` corre un `TelegramClient` de Telethon logueado
con la cuenta personal del usuario, escuchando `events.NewMessage` en
`TELEGRAM_GROUP_ID`. Por cada mensaje nuevo arma el payload
(`message_id`, `chat_id`, `sender`, `text`, `timestamp` con la fecha real
del mensaje, `reply_to_message_id`) y lo postea al webhook de n8n con el
header `X-Kronos-Secret`. Además de la escucha en vivo, corre un
**polling de respaldo cada 15 segundos** sobre el historial reciente del
chat (deduplicado por `message_id` con un `set` en memoria) — mitigación de
un bug real de Telethon en grupos de alto tráfico donde un resync de
"difference" puede hacer que la librería no vuelva a disparar el evento en
vivo para el mensaje que causó el gap.

## 4. Modelo de datos (Postgres)

Schema completo en `db/schema.sql`. Cuatro tablas:

### `signals`
Una fila por **sub-señal** (una señal con 2 TP genera 2 filas). Columnas
clave: `signal_uid` (`"{message_id}-A"`, `"-B"`, ... — único), datos de
captura (`message_id`, `chat_id`, `sender`, `raw_text`, `signal_timestamp`,
`reply_to_message_id`), datos interpretados (`instrument`, `direction`,
`execution_type`, `entry_price`, `sl`, `tp`, `interpreted_by`),
`lot_assigned` (fijo `0.01` por ahora), `status`, y los campos de ejecución
y cierre (`mt4_ticket`, `close_timestamp`, `close_price`, `profit_loss`).

Estados posibles de `status` (protocolo sección 10):

| Estado | Significado |
|---|---|
| `PENDING_CONFIRMATION` | Señal nueva parseada, esperando confirmación del usuario |
| `CONFIRMED` | Usuario confirmó, orden enviada al EA |
| `REJECTED_BY_USER` | Usuario rechazó la señal explícitamente |
| `OPEN` | Operación ejecutada y actualmente abierta en MT4 |
| `TP_REACHED` | Cerrada por alcanzar Take Profit |
| `SL_REACHED` | Cerrada por alcanzar Stop Loss |
| `CLOSED_MANUAL` | Cerrada manualmente (caller o usuario) |
| `CLOSED_BY_PRICE_RACE` | Cerrada por el protocolo de reintento de precio (sección 8) |
| `EXPIRED` | Descartada por exceder 5 minutos de antigüedad |
| `PENDING_MANUAL` | No se pudo interpretar/ejecutar; requiere revisión manual (reintentable desde el dashboard) |

Señales rechazadas por falta de lotaje (slots, sección 5.4 del protocolo)
**no generan fila acá** — solo quedan en Google Sheets (cuando esa parte
exista).

### `signal_modifications`
Instrucciones de seguimiento sobre una señal ya existente (`signal_id` FK).
`modification_type` ∈ `ENTRY_CHANGE`, `SL_CHANGE`, `SL_TO_BE`, `CANCEL`,
`TP_UPDATE`, `CLOSE_AT_PRICE`, `CLOSE_ALL_TO_BE`, `UNCLASSIFIED`.
`interpreted_by` distingue `REGEX`/`AI`. `attempt_count` y `status`
(`PENDING`/`SUCCESS`/`FAILED`/`PENDING_MANUAL`) llevan la cuenta del
protocolo de reintento de precio (sección 8 de `PROTOCOLOS_KRONOS_BOT.md`).

### `settings`
Una fila (o histórico) con `capital_real`, reportado por el EA
(`AccountBalance() - AccountCredit()`) y usado para calcular `lot` antes de
escribir cada orden pendiente. No se edita a mano en operación normal.

### `signals_archive_summary`
Destino de la compactación automática: un `TRIGGER` (`trg_compact_old_signals`,
`AFTER INSERT ON signals`, función `compact_old_signals()`) mantiene
`signals` con máximo 20 filas — cuando se supera ese tope, todo el
excedente (las filas más viejas por `created_at`) se resume en **una fila
nueva** acá (conteos por `status`, instrumentos, `profit_loss` total) y se
borra de `signals` (borrando antes sus `signal_modifications`, porque esa FK
no tiene `ON DELETE CASCADE`). Se pierde el detalle fila por fila de lo
archivado, se conserva el agregado.

## 5. El contrato de archivos MT4 (n8n ↔ EA, sin API directa)

MQL4 no permite acceso a rutas de archivo arbitrarias — el EA solo puede
escribir en `MQL4\Files\` salvo que use la bandera `FILE_COMMON`, que
redirige a una carpeta compartida del terminal
(`.../MetaQuotes/Terminal/Common/Files/`). Por eso todo el intercambio entre
n8n y el EA (`mt4-bridge/ea/KronosBridgeEA.mq4`) pasa por archivos JSON en
disco bajo `mt4-bridge/orders/`, con `FILE_COMMON` del lado del EA y un
symlink local (`pending/`, `results/`) o bind mount directo (para n8n en
Docker) del lado del repo. Contrato completo y ejemplos de JSON en
`mt4-bridge/FORMATO_ARCHIVOS.md`; resumen de cada archivo:

| Archivo | Quién escribe | Quién lee | Patrón |
|---|---|---|---|
| `pending/{signal_id}.json` | n8n (al confirmar) | EA | cola de un solo uso: EA borra tras leer |
| `results/{signal_id}.json` | EA (tras `OrderSend`) | n8n (polling 5s) | cola de un solo uso: n8n borra tras procesar |
| `closed/{ticket}.json` | EA (`DetectClosedPositions`) | n8n (polling 5s) | un archivo por ticket cerrado, n8n borra tras procesar |
| `status.json` | EA (cada ciclo de `OnTimer`) | dashboard (`GET /api/positions`) | se sobrescribe completo, no se borra |
| `config.json` | dashboard (`POST /api/config`) | EA (relee cada ciclo) | persistente, no se borra |
| `actions/{ticket}-{action}.json` | dashboard (`POST /api/positions/<ticket>/action`) | EA | un archivo por ticket+acción, EA borra tras procesar |
| `action_results/{ticket}-{action}.json` | EA (tras procesar una acción) | dashboard (polling) | dashboard borra el resultado anterior antes de encolar uno nuevo |

`signal_id` (identificador de correlación de `pending/`/`results/`) reutiliza
el `id` numérico de Postgres — el mismo que ya viaja en el `callback_data`
de los botones de Telegram. `closed/*.json` en cambio solo trae
`signal_uid` (no tiene el `id` de Postgres a mano desde el lado del EA), así
que ese consumidor correlaciona por `signal_uid` con
`WHERE status = 'OPEN'` para mantener idempotencia.

**Idempotencia:** todos los `UPDATE` que consumen estos archivos filtran por
el `status` esperado (`WHERE status = 'CONFIRMED'` para `results/`,
`WHERE status = 'OPEN'` para `closed/`) — si el mismo archivo se procesa dos
veces, el segundo `UPDATE` no encuentra fila y no rompe nada. Los archivos
de cola siempre se borran tras procesarse, haya habido notificación o no.

El EA (`KronosBridgeEA.mq4`) hace polling con `OnTimer` (no `OnTick`), con
un parser JSON manual minimalista (MQL4 no trae uno nativo), valida cada
campo antes de intentar `OrderSend`, y usa `FILE_BIN` (no `FILE_TXT`, que
tokeniza por espacios y rompería el JSON) para leer/escribir, codificando
UTF-8 a mano. Decide `OP_BUY`/`OP_SELL`/`OP_BUYLIMIT`/`OP_BUYSTOP`/
`OP_SELLLIMIT`/`OP_SELLSTOP` según `execution_type` y la posición del precio
actual respecto a `entry_price` (protocolo sección 4.2 regla 3: si es
`LIMIT` pero el precio ya cruzó el nivel, se ejecuta como `MARKET`).
`WritePositionsStatus()` reporta `account.capital_real` calculado como
`AccountBalance() - AccountCredit()` (nunca solo `AccountBalance()`, que
incluiría crédito del bróker).

## 6. Reglas de negocio clave

El detalle completo vive en `PROTOCOLOS_KRONOS_BOT.md` — no se repite acá,
solo el resumen orientador:

- **Multi-TP → sub-señales independientes** (sección 4.2 regla 6): una señal
  con TP1/TP2/TP3... genera una sub-señal por cada TP presente (sin tope),
  cada una con su propio `signal_uid`, fila en `signals`, notificación y
  botones Confirmar/Rechazar independientes. Todas comparten instrumento,
  dirección, tipo de ejecución, precio de entrada y SL — solo el TP difiere.
- **Expiración por antigüedad** (sección 4.3): si `ahora - signal_timestamp
  > 5 minutos`, la señal se descarta (`EXPIRED`), sin excepciones ni ventana
  intermedia.
- **Tipos de modificación de seguimiento** (`signal_modifications.modification_type`):
  `ENTRY_CHANGE`, `SL_CHANGE`, `SL_TO_BE` (BE siempre mueve el SL, nunca el
  TP), `CANCEL`, `TP_UPDATE`, `CLOSE_AT_PRICE` (cierre manual a mercado en un
  punto intermedio, sin pasar por el loop de reintento de precio), y
  `CLOSE_ALL_TO_BE`. Las modificaciones sobre operaciones ya confirmadas se
  ejecutan **sin pedir confirmación** — la aprobación original ya cubrió eso.
- **Protocolo de reintento de precio** (sección 8): al mover SL/TP, si el
  primer intento falla, se reintenta una vez con un precio recalculado por
  Gemini; si vuelve a fallar, se notifica al usuario con 30s de timeout
  (precio exacto, "cerrar", o reintento automático final) — máximo 3
  intentos en total, nunca reintento indefinido.
- **`capital_real`** (sección 5.1, y regla no negociable de `CLAUDE.md`):
  siempre `AccountBalance() - AccountCredit()`, calculado en el EA y
  reportado a n8n para actualizar `settings`, nunca editado a mano en
  operación normal.
- **Lotaje** (sección 5.2): `lote_total = floor(capital_real / 100) * 0.01`
  con piso `0.01`. La división en slots 80/20 entre hasta 2 operaciones
  simultáneas (sección 5.3) está diseñada pero no conectada al flujo real —
  ver `STATUS.md` para el estado exacto.

## 7. Seguridad

- **Nunca crear, mostrar, imprimir, loggear ni commitear el contenido de
  `.env`.** Hubo un incidente real de exposición de credenciales en este
  repo (ya rotadas). `.gitignore` protege `.env`, `*.session`, y
  `telethon-service/session/`.
- `mt4-bridge/orders/pending/` y `mt4-bridge/orders/results/` en el repo son
  **symlinks locales** hacia la carpeta `Common/Files/orders/` del prefijo
  de Wine de cada máquina — específicos de usuario/máquina, nunca se
  commitean. Los `.gitkeep` sí quedan versionados (necesarios para que un
  clone nuevo tenga la carpeta antes de correr el setup). Nunca usar
  `git add -A` en este repo, y menos dentro de `mt4-bridge/`.
- El dashboard (puerto `8088`) no tiene autenticación — pensado solo para
  exposición local/LAN, nunca detrás de `ngrok`.
- Los webhooks de n8n validan el header `X-Kronos-Secret` contra
  `KRONOS_WEBHOOK_SECRET` (nodo `¿Secreto de webhook válido?`) antes de
  procesar cualquier payload entrante.

## 8. Cómo correrlo localmente

Ver `docs/INSTALL_LINUX.md` (probada end-to-end en la máquina real del
usuario) o `docs/INSTALL_WINDOWS.md` (equivalente para Windows nativo, no
verificada end-to-end todavía) para el paso a paso completo: Docker,
plantilla de `.env`, levantar el stack, aplicar `schema.sql` si hace falta,
y el setup de Wine/MT4 (`scripts/setup-mt4.sh` / `.ps1`). No se repite acá.

## 9. Referencias cruzadas

- `CLAUDE.md` — contexto de negocio, stack, reglas de seguridad no
  negociables, alcance del MVP, flujo de trabajo con git.
- `PROTOCOLOS_KRONOS_BOT.md` — fuente única de verdad de todas las reglas de
  negocio (interpretación, lotaje, reintentos, estados) — léelo antes de
  tocar cualquier lógica relacionada.
- `STATUS.md` — estado actual de cada fase, qué está probado en real, qué
  falta, y los problemas abiertos que requieren iteración. **Para estado de
  avance, ver siempre ese documento, no este.**
- `MERGE_PLAN.md` — plan de trabajo puntual para sincronizar `develop` con
  la instancia de n8n en producción (documento de trabajo, no versionado).
- `mt4-bridge/FORMATO_ARCHIVOS.md` — contrato exacto de todos los archivos
  JSON del puente n8n ↔ EA ↔ dashboard, con ejemplos completos de cada uno.
