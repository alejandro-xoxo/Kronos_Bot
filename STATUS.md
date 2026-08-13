# Kronos Bot — Estado actual

> Snapshot del proyecto al 2026-08-13, rama `develop`. Para el detalle de
> reglas de negocio ver `PROTOCOLOS_KRONOS_BOT.md`; para contexto general,
> `CLAUDE.md`.

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
`n8n-workflows/webhook-mvp-workflow.json` define un workflow con 4 nodos:
1. **Webhook** (`POST /webhook/kronos-telethon-signal`) — recibe el
   payload de Telethon.
2. **Nodo Code (parser regex)** — detecta si el texto matchea el
   formato fijo de señal nueva (`INSTRUMENTO BUY|SELL [LIMIT] PRECIO
   TP valor [TP valor...] SL valor`). Extrae instrumento, dirección,
   tipo de ejecución, precio de entrada, **solo el primer TP**, y SL.
   Valida antigüedad (>5 min → `EXPIRED`). Distingue explícitamente el
   caso "señal con SL faltante" (`MISSING_SL`) de "no es una señal"
   (`NO_MATCH_FIXED_FORMAT`), según protocolo sección 4.2 regla 5.
3. **IF ¿Señal válida?** — filtra por `matched=true` y
   `status=PENDING_CONFIRMATION`.
4. **Insertar en SQLite** (`INSERT INTO signals ...`) y **Notificar
   por Telegram** al chat privado del usuario con los datos de la
   señal.
- El regex está cubierto por comentarios inline que citan ejemplos
  reales del grupo (una y varias líneas, "TP" repetido sin numerar,
  texto extra después del SL).
- El JSON tiene `"active": false` y credenciales placeholder
  (`REPLACE_CON_TU_CREDENCIAL_SQLITE`, `REPLACE_CON_TU_CREDENCIAL_TELEGRAM`)
  — **nunca se importó ni activó en una instancia real de n8n.**

### 3. Infraestructura Docker — definida, no verificada en ejecución
`docker-compose.yml` levanta tres servicios en una red compartida
(`trading_net`):
- `n8n` (imagen oficial, puerto 5678, `NODE_ENV=production`).
- `ngrok` — expone n8n a un dominio público fijo vía `NGROK_AUTHTOKEN`
  y `N8N_HOST`, para que Telegram/webhooks externos lleguen a la
  instancia local.
- `telethon` — build local del microservicio, apunta por defecto a
  `http://n8n:5678/webhook/telegram-signal` (nota: **no coincide** con
  el path `kronos-telethon-signal` definido en el workflow — hay un
  desalineamiento a resolver antes de correr end-to-end).

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

### 6. Schema SQL de la base de datos — escrito, no aplicado
`db/schema.sql` ya existe (recuperado de la rama `feature/db-schema`,
que había quedado sin mergear) con las tres tablas del protocolo:
- `signals` — señales nuevas, con `CHECK` en `direction`,
  `execution_type`, `interpreted_by` y los 10 estados de la sección 10,
  más índices por `status`, `instrument+status`, `message_id` y
  `mt4_ticket`.
- `signal_modifications` — instrucciones de seguimiento, con los 6
  `modification_type` (incluye `CLOSE_AT_PRICE`), contador de
  `attempt_count` para el protocolo de reintento (sección 8), y su
  propio `status`.
- `settings` — solo `capital_real`, alimentado por el EA de MT4.

Nunca se ejecutó contra un archivo `.db` real ni se conectó la
credencial SQLite del workflow n8n a él.

## Qué NO hace todavía (ambiguo / a definir sobre la marcha)

Roughly en orden de lo más cercano a lo más lejano:

- El workflow de n8n **nunca se probó de punta a punta** — falta
  importarlo a una instancia real, correr `db/schema.sql` contra un
  archivo `.db`, apuntar la credencial SQLite del workflow a ese
  archivo, resolver la credencial placeholder de Telegram, y corregir
  el mismatch de path del webhook contra `docker-compose.yml`.
- Interpretación de instrucciones de seguimiento vía Gemini (mover
  SL, BE, cerrar, `CLOSE_AT_PRICE`, etc.) — diseñada en detalle, cero
  código.
- Botones interactivos de Confirmar/Rechazar en Telegram — hoy la
  notificación es informativa, sin callback.
- Cálculo de lotaje por slots (capital, división 80/20, ocupación y
  liberación de slots) — es una fórmula ya definida pero no existe
  como función en ningún lado del código.
- Todo lo relacionado al EA puente en MT4 (ejecución real de
  órdenes, reporte de cierre, cálculo de `capital_real`) — no
  arrancó, ni siquiera hay un esqueleto.
- Loop de reintento de precio con Gemini (sección 8 del protocolo) —
  depende de que exista primero la ejecución real en MT4.
- Registro en Google Sheets (señales cerradas y rechazadas) — sin
  integración todavía.
- Multi-TP como múltiples operaciones — decisión ya tomada de
  posponerlo, no hay fecha ni diseño de cuándo se retoma.
- Nunca se corrió el stack completo con `docker-compose up` para
  verificar que los tres contenedores conversan entre sí en la
  práctica — todo lo dicho arriba sobre Docker es "debería funcionar
  según la definición", no algo confirmado corriendo.

## Fases (referencia de `CLAUDE.md`)

- ✅ Fase 0 — credenciales Telegram, estructura de carpetas.
- ✅ Fase 1 — microservicio Telethon capturando y enviando al webhook.
- 🔶 Fase 2 — schema SQLite (`signals`, `signal_modifications`,
  `settings`): `db/schema.sql` ya escrito y mergeado a `develop`,
  falta ejecutarlo contra un `.db` real y conectar la credencial del
  workflow n8n.
- 🔶 Fase 3 — webhook + parser regex en n8n: el JSON del workflow está
  escrito y parece completo, pero no verificado en una instancia real
  (el MVP actual, a medio camino).
- 🔲 Fase 4 — interpretación por Gemini.
- 🔲 Fase 5 — confirmación interactiva por Telegram.
- 🔲 Fase 6 — EA puente en MT4.
- 🔲 Fase 7 — cierre y registro en Google Sheets.
- 🔲 Fase 8 — ejecución 100% automática (futuro).
</content>
