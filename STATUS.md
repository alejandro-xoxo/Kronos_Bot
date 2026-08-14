# Kronos Bot — Estado actual

> Snapshot del proyecto al 2026-08-14, rama `feature/webhook-buttons-setup`
> (sin mergear a `develop` todavía). Para el detalle de reglas de negocio
> ver `PROTOCOLOS_KRONOS_BOT.md`; para contexto general, `CLAUDE.md`.

## Qué hace hoy (con detalle)

### 1. Captura de mensajes de Telegram — funcional
`telethon-service/main.py` es un microservicio Python (Telethon) que:
- Se loguea con la cuenta personal del usuario (`TELEGRAM_API_ID`,
  `TELEGRAM_API_HASH`, `TELEGRAM_PHONE`), no con un bot.
- Escucha en tiempo real el grupo configurado en `TELEGRAM_GROUP_ID`
  (si no está seteado, escucha *todos* los chats — hay un warning en
  el log para ese caso).
- Por cada mensaje nuevo arma un payload (`message_id`, `chat_id`,
  `sender`, `text`, `timestamp`, `reply_to_message_id`) y lo hace
  `POST` a `N8N_WEBHOOK_URL` con `requests`, con timeout de 10s y
  manejo de error simple (log, sin reintento).
- `list_groups.py` existe como utilidad para identificar el ID del
  grupo objetivo.
- Corre en Docker (`Dockerfile` propio), con la sesión de Telethon
  persistida en un volumen (`telethon_session`).

### 2. Orquestación con n8n — parcialmente definida, no desplegada
`n8n-workflows/webhook-mvp-workflow.json` define un workflow con 6 nodos:
1. **Webhook Telethon** (`POST /webhook/kronos-telethon-signal`) —
   recibe el payload de Telethon.
2. **Parsear señal (regex)** — detecta si el texto matchea el formato
   fijo de señal nueva (`INSTRUMENTO BUY|SELL [LIMIT] PRECIO TP valor
   [TP valor...] SL valor`). Extrae instrumento, dirección, tipo de
   ejecución, precio de entrada, **solo el primer TP** (`tp2` queda
   como dato informativo, no persistido), y SL. Valida antigüedad
   (>5 min → `EXPIRED`). Distingue explícitamente el caso "señal con
   SL faltante" (`MISSING_SL`) de "no es una señal"
   (`NO_MATCH_FIXED_FORMAT`), según protocolo sección 4.2 regla 5.
   **Bug real corregido:** el nodo Webhook de n8n anida el payload
   del POST dentro de `item.json.body`, no en la raíz — el código leía
   `item.json` directo y por eso nunca matcheaba nada en producción.
   Ahora lee de `item.json.body` (con fallback a `item.json` por
   robustez).
3. **¿Señal válida?** (IF) — filtra por `matched=true` y
   `status=PENDING_CONFIRMATION`.
4. **Insertar señal (Postgres)** — `INSERT INTO signals ...`
   parametrizado (`$1`..`$14`, mapeo 1:1 verificado contra las
   columnas del INSERT). Migrado de SQLite a Postgres por latencia
   (conexión TCP persistente vs. overhead de proceso por query).
5. **Notificar Telegram** — mensaje al chat privado del usuario con
   los datos de la señal, ahora con **teclado inline Confirmar/
   Rechazar** (`callback_data` con el `message_id` de la señal).
6. **Webhook Callback Telegram** (`POST /webhook/kronos-telegram-
   callback`) — nodo nuevo para recibir el `callback_query` cuando el
   usuario presiona un botón. **Existe pero no está conectado a nada
   todavía** — falta la lógica que actualice `status` en Postgres y
   responda al usuario.
- El regex está cubierto por comentarios inline que citan ejemplos
  reales del grupo (una y varias líneas, "TP" repetido sin numerar,
  texto extra después del SL).
- El JSON tiene `"active": false` y credenciales placeholder
  (`REPLACE_CON_TU_CREDENCIAL_POSTGRES`, `REPLACE_CON_TU_CREDENCIAL_TELEGRAM`)
  — **nunca se importó ni activó en una instancia real de n8n.**

### 3. Infraestructura Docker — parcialmente verificada
`docker-compose.yml` levanta cuatro servicios en una red compartida
(`trading_net`):
- `n8n` (imagen oficial, puerto 5678, `NODE_ENV=production`). Volumen
  de datos **corregido y verificado en ejecución**: apuntaba a
  `/home/node/.local/share/n8n` (ruta incorrecta, la config no
  persistía entre reinicios); ahora apunta a `/home/node/.n8n` — se
  confirmó con `docker compose exec n8n sh -c 'ls -la /home/node/.n8n'`
  que `database.sqlite`, `config` y `nodes/` sí persisten ahí.
- `postgres` (`postgres:16-alpine`, volumen `postgres_data`) — servicio
  nuevo, reemplaza a SQLite como base de datos de señales. Variables
  `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` deben estar en
  `.env` (pendiente confirmar que el usuario ya las agregó) y la
  credencial correspondiente configurarse a mano en n8n (host
  `postgres`, port `5432`).
- `ngrok` — expone n8n a un dominio público fijo vía `NGROK_AUTHTOKEN`
  y `N8N_HOST`, para que Telegram/webhooks externos lleguen a la
  instancia local.
- `telethon` — build local del microservicio. El mismatch de path que
  existía contra el webhook (`telegram-signal` vs.
  `kronos-telethon-signal`) **ya se corrigió** — ambos apuntan a
  `/webhook/kronos-telethon-signal`.

### 4. Documentación y reglas de negocio — completas y cerradas
`PROTOCOLOS_KRONOS_BOT.md` es la fuente de verdad, ya escrita en
detalle para todas las fases (no solo el MVP): árbol de clasificación
regex/IA, reglas de interpretación, antigüedad de señal, cálculo de
capital y lotaje por slots, validación de precio, flujo de
confirmación, protocolo de reintento con Gemini, ciclo de cierre,
estados de `signals`, matriz de notificaciones, y principios de
seguridad transversales. Esto está terminado como diseño, aunque casi
nada de lo que describe (fuera del MVP regex) está implementado.

### 5. Seguridad — reglas activas
- `.env` existe localmente (con credenciales reales) y no está
  versionado.
- Ya hubo un incidente de exposición de credenciales en este repo,
  documentado en `CLAUDE.md` como recordatorio permanente — motivo
  por el cual `.gitignore` protege `.env`, `*.session`,
  `telethon-service/session/`.

### 6. Schema de la base de datos — migrado a Postgres, no aplicado
`db/schema.sql` se migró de sintaxis SQLite a PostgreSQL
(`AUTOINCREMENT` → `SERIAL`, `DATETIME` → `TIMESTAMP`, se quitó
`PRAGMA foreign_keys`), mismas tablas, columnas, `CHECK` e índices:
- `signals` — señales nuevas, con `CHECK` en `direction`,
  `execution_type`, `interpreted_by` y los 10 estados de la sección 10,
  más índices por `status`, `instrument+status`, `message_id` y
  `mt4_ticket`. Incluye `lot_assigned REAL DEFAULT 0.01` (valor fijo
  temporal hasta que exista el cálculo real de capital/slots).
- `signal_modifications` — instrucciones de seguimiento, con los 6
  `modification_type` (incluye `CLOSE_AT_PRICE`), contador de
  `attempt_count` para el protocolo de reintento (sección 8), y su
  propio `status`.
- `settings` — solo `capital_real`, alimentado por el EA de MT4.

Nunca se ejecutó contra una instancia real de Postgres ni se conectó
la credencial del workflow n8n a ella.

## Qué NO hace todavía (ambiguo / a definir sobre la marcha)

Roughly en orden de lo más cercano a lo más lejano:

- El workflow de n8n **nunca se probó de punta a punta** — falta
  importarlo a una instancia real, correr `db/schema.sql` contra
  Postgres, configurar la credencial Postgres y la de Telegram en n8n,
  y confirmar que `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`
  ya están en `.env`.
- El nodo `Webhook Callback Telegram` existe pero está **desconectado**
  — falta la lógica que reciba el `callback_query` de los botones
  Confirmar/Rechazar, actualice `status` en `signals`, y responda al
  usuario. También falta configurar el `setWebhook` del bot de
  Telegram apuntando a ese endpoint.
- Interpretación de instrucciones de seguimiento vía Gemini (mover
  SL, BE, cerrar, `CLOSE_AT_PRICE`, etc.) — diseñada en detalle, cero
  código.
- Cálculo de lotaje por slots (capital, división 80/20, ocupación y
  liberación de slots) — es una fórmula ya definida pero no existe
  como función en ningún lado del código; `lot_assigned` en `signals`
  usa un valor fijo (`0.01`) como placeholder temporal.
- Todo lo relacionado al EA puente en MT4 (ejecución real de
  órdenes, reporte de cierre, cálculo de `capital_real`) — no
  arrancó, ni siquiera hay un esqueleto.
- Loop de reintento de precio con Gemini (sección 8 del protocolo) —
  depende de que exista primero la ejecución real en MT4.
- Registro en Google Sheets (señales cerradas y rechazadas) — sin
  integración todavía.
- Multi-TP como múltiples operaciones — decisión ya tomada de
  posponerlo, no hay fecha ni diseño de cuándo se retoma. `tp2` ya se
  captura en el parser como dato informativo, pero no se persiste
  (la tabla `signals` no tiene esa columna).
- El stack completo (`n8n` + `postgres` + `ngrok` + `telethon`) nunca
  se corrió junto de punta a punta con `docker compose up` — solo se
  verificó por separado que el volumen de `n8n` persiste
  correctamente. El resto sigue siendo "debería funcionar según la
  definición", no confirmado corriendo.

## Fases (referencia de `CLAUDE.md`)

- ✅ Fase 0 — credenciales Telegram, estructura de carpetas.
- ✅ Fase 1 — microservicio Telethon capturando y enviando al webhook.
- 🔶 Fase 2 — schema de base de datos (`signals`, `signal_modifications`,
  `settings`): `db/schema.sql` migrado a Postgres, servicio `postgres`
  agregado a `docker-compose.yml`, falta ejecutarlo contra la instancia
  real y conectar la credencial del workflow n8n.
- 🔶 Fase 3 — webhook + parser regex en n8n: JSON del workflow completo
  (incluye nodo Postgres y botones Confirmar/Rechazar), bug real de
  lectura de payload (`item.json.body`) ya corregido, pero **aún no
  verificado en una instancia real de n8n** (el MVP actual, a medio
  camino).
- 🔲 Fase 4 — interpretación por Gemini.
- 🔶 Fase 5 — confirmación interactiva por Telegram: botones inline
  Confirmar/Rechazar ya están en el mensaje de notificación y el
  webhook de callback existe, pero sin conectar a ninguna lógica
  todavía.
- 🔲 Fase 6 — EA puente en MT4.
- 🔲 Fase 7 — cierre y registro en Google Sheets.
- 🔲 Fase 8 — ejecución 100% automática (futuro).
</content>
