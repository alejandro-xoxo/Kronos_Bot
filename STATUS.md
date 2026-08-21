# Kronos Bot — Estado actual

> Snapshot técnico del proyecto al 2026-08-17, rama `develop` (ya mergeado
> — Etapas 1 a 6 completas, ver más abajo). Pensado para poder pegarse
> completo a una sesión nueva de Claude Code (o de cualquier asistente)
> sin depender de memoria de conversación previa. Para reglas de negocio
> detalladas ver `PROTOCOLOS_KRONOS_BOT.md`; para contexto general y
> reglas de trabajo, `CLAUDE.md`; para el detalle de alcance de v1 (qué
> incluye y qué queda afuera a propósito), `docs/versions/v1.md`.

## Excepción registrada: acceso remoto al dashboard (commit directo a `main`)

**2026-08-21** — cambio de infraestructura aplicado directo sobre
`main`/producción, autorizado explícitamente por el usuario como
excepción al flujo normal `feature/* → develop → main` (misma
excepción ya usada antes para el cambio LIMIT/MERCADO). Motivo: poder
controlar posiciones abiertas (BE, BE inverso, Cerrar) desde el
celular vía una URL pública, sin depender de estar en la LAN.

Cambios:

- **Túnel ngrok compartido**: se agregó un servicio `caddy` (Caddyfile
  en `proxy/Caddyfile`) delante de `n8n` y `dashboard`. `ngrok` ahora
  apunta a `caddy:8080` en vez de `n8n:5678` directo. `caddy` rutea
  `/webhook/*` → `n8n:5678` (necesario para que Telegram siga
  entregando los callbacks de los botones Confirmar/Rechazar, y para
  el webhook de Telethon) y todo lo demás → `dashboard:8080`. El
  webhook interno Telethon → n8n (`http://n8n:5678/...`, red interna
  `trading_net`) no se tocó.
- **Login básico en el dashboard**: `dashboard/main.py` ahora exige
  HTTP Basic Auth en `@app.before_request` (todas las rutas, sin
  excepciones) usando `DASHBOARD_USER`/`DASHBOARD_PASSWORD` (nuevas
  vars en `.env`, agregadas vacías — hay que completarlas a mano antes
  de levantar el stack). Antes el dashboard no tenía ninguna
  autenticación y confiaba en no estar expuesto por ngrok.
- **Botones táctiles**: los botones de acción por posición (BE, BE
  inverso, Cerrar — ya existían y funcionaban, ver sección "Qué
  funciona probado de punta a punta") ahora tienen un breakpoint
  móvil (`@media max-width: 640px` en `dashboard/static/index.html`)
  que los agranda a tamaño táctil (min 44px) y los apila en columna.
  Se agregó además un `confirm()` de JS antes de encolar `CLOSE`
  (`dashboard/static/app.js`) — es la única acción irreversible de
  las tres, y antes se disparaba con un solo tap sin confirmación.

**Pendiente para que esto funcione en producción:** completar
`DASHBOARD_USER`/`DASHBOARD_PASSWORD` en `.env` del EliteBook (no se
generan ni se muestran automáticamente — regla de seguridad de
`CLAUDE.md`) y recrear el stack (`docker compose up -d --build`) para
que tome el nuevo servicio `caddy` y el cambio de destino de `ngrok`.

## ⚠️ El gap operativo más importante ahora mismo

**Fase 4 (Gemini) no está implementada.** El sistema ejecuta señales
*nuevas* de formato fijo de punta a punta, con dinero real. Pero los
mensajes de *seguimiento* del grupo — "mover el SL a BE", "cerrar a X
-Y PIPS", "TP alcanzado" — **no se interpretan ni se aplican solos**.
Si el grupo pide cerrar o mover el SL de una operación ya abierta, hay
que verlo en el chat y aplicarlo a mano con los botones **BE / Cerrar**
del dashboard (`localhost:8088`). No hay ningún proceso automático
mirando el grupo para eso todavía — es 100% responsabilidad manual del
usuario mientras esta fase no esté conectada.

## Cómo se despliega de verdad un cambio del EA a producción (manual, sin automatización)

**No hay ningún mecanismo automático** (sin cron, sin systemd timer, sin
git hook) que compile o sincronice el EA de producción. El flujo real,
confirmado el 2026-08-19 revisando el sistema en vivo, son 3 pasos que
hace el usuario a mano:

1. `git pull`/`git reset` en `Kronos_Bot-prod` — el checkout **separado**
   (no es este directorio) que vive en
   `~/Proyectos/Kronos_Bot-prod`, en rama `main`, y del que cuelga el
   symlink real `MQL4/Experts/KronosBridgeEA.mq4` dentro del prefijo de
   Wine (`~/.wine-mt4/...MQL4/Experts/`).
2. Editar el `.mq4` a mano ahí mismo si hace falta un ajuste puntual
   antes de aprobarlo formalmente vía PR.
3. Abrir MetaEditor dentro de Wine y compilar (F7) — regenera el `.ex4`
   que el terminal MT4 ya tiene cargado.

**⚠️ NUNCA hacer `git reset`/`git pull` en `Kronos_Bot-prod` sin antes
verificar si hay cambios sin commitear en el `.mq4`** (correr
`git diff mt4-bridge/ea/KronosBridgeEA.mq4` ahí antes de resetear) — ya
pasó una vez (2026-08-19) que un fix funcional real (comparación de
precio actual vs `entry_price` en `ExecuteOrder()`, ver sección más
abajo) quedó aplicado solo como edición manual sin commitear en ese
checkout, corriendo en producción real, sin estar en ningún commit de
`main` ni `develop` — un reset sin este chequeo lo habría borrado en
silencio, sin ningún aviso, y el bug original habría vuelto a producción
sin que nadie lo notara hasta la próxima señal real mal ejecutada.

## Qué funciona probado de punta a punta (no solo diseñado)

**Ejecución real en MT4 — verificada con tickets reales de VT Markets**,
no solo en teoría. Ejemplo: señal `9641-A` (XAUUSD BUY, entrada 4398.57,
TP 4402, SL 4370) → confirmada por Telegram → ticket real `24827753`,
abierta y visible en el dashboard con precio en vivo. Desde entonces
corrieron más señales reales (`9644-A/B`, `9646-A/B`), todas con tickets
reales de la cuenta `23096429`.

Flujo completo verificado con señales reales del grupo de Telegram:

```
Telegram (grupo VIP SIGNALS FX)
   → Telethon (microservicio Python, captura el mensaje)
   → Webhook n8n (POST /webhook/kronos-telethon-signal)
   → Parsear señal (regex)
   → ¿Señal válida? (IF: matched=true, status=PENDING_CONFIRMATION)
   → Insertar señal (Postgres) — INSERT ... RETURNING id
   → Notificar Telegram (mensaje + botones Confirmar/Rechazar)
   → [usuario presiona un botón]
   → Trigger Callback Telegram → Parsear callback → ¿Confirmar o rechazar?
   → Actualizar status (Postgres, idempotente) → Responder callback → Avisar en chat
```

Puntos ya verificados en ejecución real (no solo revisados en código):

1. **Captura y parseo.** Telethon reenvía el mensaje real, el parser regex
   lo matchea correctamente, incluyendo el bug histórico ya corregido de
   que el payload llega anidado en `item.json.body`, no en la raíz.
2. **Multi-TP → sub-señales independientes** (protocolo sección 4.2 regla
   6, cambio de diseño reciente): si el mensaje trae 2+ TP, el parser
   genera **hasta 2 items** de salida (`signal_uid` = `{message_id}-A` /
   `-B`), cada uno con su propio TP, mismo instrumento/dirección/entrada/
   SL. TP3 en adelante se ignora. Cada sub-señal se inserta, valida y
   notifica **por separado** — 2 filas en `signals`, 2 notificaciones de
   Telegram con botones independientes.
3. **BIGINT para IDs de Telegram.** `chat_id`, `message_id` y
   `reply_to_message_id` son `BIGINT` en el schema — un `chat_id` real
   negativo grande (`-5523530567`) rompía con `INTEGER`, ya corregido y
   verificado insertando esa fila real.
4. **Botones de confirmar/rechazar funcionales.** No son informativos:
   - `callback_data` usa el `id` real de Postgres (vía `RETURNING id` del
     INSERT), no el `message_id` de Telegram.
   - El `UPDATE` de status es **idempotente**: usa un CTE
     (`WHERE status = 'PENDING_CONFIRMATION'`) que siempre devuelve
     `updated_count` y `current_status`, así un doble clic no reprocesa
     la señal ni duplica el mensaje — responde "ya fue procesada".
   - Además del toast de `answerCallbackQuery` (fácil de perder, se
     desvanece solo), se manda un **mensaje real al chat** confirmando o
     rechazando, para que quede visible en el historial.
5. **Auto-init de la base de datos.** `db/schema.sql` está montado como
   `docker-entrypoint-initdb.d/schema.sql` en el servicio `postgres` de
   `docker-compose.yml` — si se recrea el volumen `postgres_data` desde
   cero, el schema se aplica solo, sin pasos manuales.

## Infraestructura Docker — corriendo y verificada

`docker-compose.yml`, servicios en la red `trading_net`:

- **`n8n`** — imagen oficial, puerto 5678. Variables clave agregadas
  durante esta fase: `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (sin esto,
  `$env` no se resuelve dentro de expresiones de nodos) y
  `TELEGRAM_USER_CHAT_ID` (sin esto, el nodo de notificación mandaba
  `chat_id` vacío). Volumen de datos en `/home/node/.n8n`, persistencia
  verificada.
- **`postgres`** — `postgres:16-alpine`, volumen `postgres_data` +
  bind-mount de `db/schema.sql` en `docker-entrypoint-initdb.d/`. Se
  recreó el volumen limpio al menos dos veces durante esta fase (fixes de
  schema) y el auto-init funcionó ambas veces sin intervención manual.
- **`ngrok`** — expone n8n a un dominio fijo (`N8N_HOST`) para que
  Telegram le llegue.
- **`telethon`** — build local, apunta a
  `http://n8n:5678/webhook/kronos-telethon-signal`.

**Modificación manual de workflows vía API de n8n:** durante esta fase se
detectó que el JSON de `n8n-workflows/webhook-mvp-workflow.json` en el
repo y el workflow cargado en la instancia real de n8n son **copias
independientes** — editar el archivo no actualiza automáticamente lo que
corre en n8n, hay que reimportar. Varias veces se aplicaron fixes
directo contra la instancia viva vía `PUT /api/v1/workflows/{id}` (con
`N8N_API_KEY` en `.env`) para evitar depender de la UI, y después se
sincronizó el JSON del repo bajándolo de vuelta vía `GET`. **Riesgo real
ya observado:** si el navegador tiene el editor de n8n abierto con un
borrador viejo y se guarda/publica desde la UI, sobrescribe cambios
hechos por API — pasó al menos una vez y se perdió el guard de
idempotencia temporalmente, hubo que reconstruirlo. Recomendación:
cerrar y reabrir la pestaña del editor antes de tocar la UI después de
un cambio por API.

## Etapa 6 — EA puente en MT4 (en progreso)

Sub-etapas de esta fase, con estado individual:

### 1. Wine + MT4 instalado — ✅ completo, con sesión real activa

- `scripts/setup-mt4.sh` (Linux, cualquier distro Arch-based — verifica
  `pacman`, no asume CachyOS) instala `wine`/`winetricks`, crea el
  prefijo dedicado `~/.wine-mt4`, crea `mt4-bridge/orders/{pending,
  results}/`.
- `scripts/setup-mt4.ps1` — equivalente para Windows nativo (sin Wine).
- **Fix real durante la ejecución:** `WINEARCH=win32` ya no es válido en
  Wine 7+ (modo `wow64` combinado) — el script fallaba con
  `"WINEARCH is set to 'win32' but this is not supported in wow64 mode"`
  en Wine 11.15. Se quitó esa variable, el prefijo por defecto corre MT4
  (32 bits) sin problema.
- **MT4 se instaló con el instalador real de VT Markets**
  (`vtmarkets4setup.exe`, descargado de vtmarkets.com) — no con el
  genérico de metatrader4.com como se había asumido inicialmente; VT
  Markets sí distribuye su propio instalador.
- Instalado correctamente en `~/.wine-mt4` (confirmado: carpeta
  `MetaQuotes/Terminal/<ID>/` con `MQL4/`, `config/`, etc.)
- Sesión real iniciada (cuenta `23096429`, servidor de VT Markets),
  terminal corriendo (`terminal.exe` bajo Wine, verificado con `ps`).

### 2. Formato de archivos + symlinks a Common/Files — ✅ completo y verificado

- `mt4-bridge/FORMATO_ARCHIVOS.md` define el contrato exacto:
  - Orden pendiente: `mt4-bridge/orders/pending/{signal_id}.json`
    (`signal_id`, `signal_uid`, `instrument`, `direction`,
    `execution_type`, `entry_price`, `sl`, `tp`, `lot` fijo `0.01`,
    `created_at`).
  - Resultado: `mt4-bridge/orders/results/{signal_id}.json` (`success`,
    `ticket`, `executed_price`, `executed_at`, `error_code`,
    `error_message`).
  - `signal_id` reutiliza el `id` numérico de Postgres, ya usado en los
    botones de Telegram — no se inventó un segundo identificador.
- **Descubrimiento técnico clave:** MQL4 no permite acceso a rutas de
  archivo arbitrarias (ni con Wine) — las funciones nativas `FileOpen`/
  `FileWrite` están sandboxeadas a `MQL4\Files\` del terminal, salvo que
  se use la bandera `FILE_COMMON`, que redirige a una carpeta compartida
  fija: `.../MetaQuotes/Terminal/Common/Files/` (no depende del ID del
  terminal, a diferencia de la carpeta específica de cada instalación).
- **Ruta real confirmada en esta máquina:**
  ```
  ~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/
  ```
- `mt4-bridge/orders/pending/` y `mt4-bridge/orders/results/` en el repo
  son **symlinks locales** hacia
  `Common/Files/orders/{pending,results}/` de ese prefijo de Wine.
  Verificado con una escritura de prueba: un archivo creado del lado del
  repo aparece instantáneamente del lado de `Common/Files`.
- **Estos symlinks son específicos de esta máquina/usuario y NUNCA se
  commitean.** `git status` en este repo va a mostrar permanentemente,
  en cualquier máquina con Wine configurado:
  - `borrados: mt4-bridge/orders/pending/.gitkeep` y `results/.gitkeep`
  - `sin seguimiento: mt4-bridge/orders/pending` y `results` (los
    symlinks)

  Esto es el estado local esperado, igual que `.env` — **nunca usar
  `git add -A` en este repo**, y menos dentro de `mt4-bridge/`. Los
  `.gitkeep` siguen versionados porque son necesarios para que un clone
  nuevo (sin Wine configurado todavía) tenga las carpetas reales antes
  de correr el setup.
- `.gitignore` excluye `mt4-bridge/orders/pending/*` y
  `mt4-bridge/orders/results/*`, con excepción explícita de los
  `.gitkeep`.

### 3. EA en MQL4 — ✅ compilado y ejecutando órdenes reales

- `mt4-bridge/ea/KronosBridgeEA.mq4` — Expert Advisor que:
  - Usa `OnTimer` (no `OnTick`) para hacer polling de
    `orders/pending/*.json` cada `InpPollIntervalSeconds` (default 2s).
  - Parser JSON manual minimalista (`JsonGetValue`) — MQL4 no trae uno
    nativo; suficiente porque el schema es plano y fijo, sin anidamiento.
  - Valida cada campo antes de intentar `OrderSend` (tipos, presencia,
    rangos > 0) — si el JSON es inválido, nunca llega a ejecutar nada.
  - Lee/escribe archivos en modo `FILE_BIN` (no `FILE_TXT` — en MQL4
    `FileReadString` en modo texto tokeniza por espacios y rompería el
    JSON), decodificando/codificando UTF-8 a mano.
  - Todas las operaciones de archivo usan `FILE_COMMON`.
  - Decide `OP_BUY`/`OP_SELL`/`OP_BUYLIMIT`/`OP_BUYSTOP`/`OP_SELLLIMIT`/
    `OP_SELLSTOP` según `execution_type` y dónde quedó el precio actual
    respecto a `entry_price`.
  - **Fix aplicado tras revisión externa (protocolo sección 4.2 regla
    3):** si `execution_type` es `LIMIT` pero el precio actual ya
    alcanzó/cruzó `entry_price`, se ejecuta como `MARKET` (con el precio
    actual), no como orden pendiente — antes de este fix, siempre creaba
    una orden pendiente aunque el nivel ya se hubiera alcanzado.
  - Borra el archivo de `pending/` tras procesarlo (éxito o JSON
    inválido); si no pudo **leer** el archivo (posible escritura a medias
    de n8n), no lo borra, reintenta en el siguiente ciclo.
  - Escribe siempre un resultado en `results/{signal_id}.json`, tanto en
    éxito como en fallo (con `error_code`/`error_message` de MQL4).
  - Logging con `Print()` en cada paso clave, visible en la pestaña
    **Experts** de MT4.
- Revisado en conjunto con el usuario (vía archivo enviado, no pegado en
  terminal — pegarlo corrompía el código).
- **Compilado con MetaEditor** (`KronosBridgeEA.ex4` presente en
  `MQL4/Experts/`) y **adjuntado a gráficos reales** (XAUUSD-STD,
  EURUSD-STD) — verificado vía log de MT4 (`MQL4/Logs/`), incluyendo el
  polling de `orders/pending/*.json`, la actualización en caliente del
  sufijo de símbolo desde `orders/config.json`, y errores reales de
  permisos de escritura ya resueltos.
- **Fix real post-compilación:** al abrir 2 sub-señales del mismo
  instrumento casi simultáneas (multi-TP), el bróker devolvía error
  4109 (trade context busy) en la segunda `OrderSend` — se agregó una
  pausa corta entre órdenes consecutivas.

### 4 y 5 — Nodos de n8n para el puente con MT4

- **Etapa 4 — ✅ implementada y verificada end-to-end con dinero real.**
  Confirmar una señal real en Telegram escribe la orden, el EA la
  levanta y ejecuta, y vuelve un ticket real (ver arriba). En la
  rama `feature/n8n-mt4-order-bridge`:
  - **Bloqueo de infraestructura resuelto:** n8n corre en Docker y no
    tenía acceso al filesystem del host donde vive `mt4-bridge/orders/`
    (symlinks a Wine). Se agregó a `docker-compose.yml` un bind mount
    nuevo: `${MT4_ORDERS_HOST_PATH}:/mt4-bridge/orders` en el servicio
    `n8n`, más `MT4_ORDERS_DIR=/mt4-bridge/orders` como env var interna.
    `MT4_ORDERS_HOST_PATH` se agregó a `.env` (no versionado, específico
    de esta máquina) apuntando directo a
    `~/.wine-mt4/.../MetaQuotes/Terminal/Common/Files/orders` — se monta
    el destino real, no el symlink del repo (Docker no puede resolver
    symlinks que apuntan fuera del árbol montado). Verificado con una
    escritura de prueba desde dentro del contenedor, visible del lado
    de Wine.
  - Tres nodos nuevos en el workflow, en la rama `CONFIRMED` del flujo
    (contenido histórico de esta sección, aún vigente):
    de callback (paralelo a `Responder callback: Confirmada`, no lo
    reemplaza): **`Obtener señal confirmada`** (Postgres `SELECT`, ya
    que el `UPDATE` de `Actualizar status: CONFIRMED` solo devuelve
    `updated_count`/`current_status`, no la fila completa) →
    **`Preparar orden pending (JSON)`** (Code, arma el JSON exacto de
    `FORMATO_ARCHIVOS.md`, lotaje fijo `0.01`) → **`Escribir orden
    pending (MT4)`** (`n8n-nodes-base.readWriteFile`, escribe en
    `{{ $env.MT4_ORDERS_DIR }}/pending/{{ signal_id }}.json`).
  - Ya subido vía API a la instancia real de n8n (workflow activo
    `QxXebyoPgTGmGH2B`) y sincronizado de vuelta al JSON del repo.
  - **Prueba end-to-end real disparada y verificada** (ver el ejemplo
    de `9641-A`/ticket `24827753` al inicio de este documento).
- **Etapa 5 — ✅ implementada y verificada end-to-end.** Rama
  `feature/n8n-read-mt4-results`. Seis nodos nuevos, en paralelo al
  flujo de confirmación (no tocan los nodos existentes):
  **`Trigger: leer resultados MT4`** (`scheduleTrigger`, cada 5s) →
  **`Leer resultados (MT4)`** (`readWriteFile`, operation `read`,
  `fileSelector = {{ $env.MT4_ORDERS_DIR }}/results/*.json`, soporta
  glob, 0 items si no hay archivos — no falla) → **`Parsear resultado
  (MT4)`** (Code) → **`Actualizar status: OPEN/PENDING_MANUAL`**
  (Postgres, `UPDATE` idempotente `WHERE status = 'CONFIRMED'`,
  `status` final `OPEN` si `success=true` o `PENDING_MANUAL` si
  `success=false`) → **`¿Se actualizó ahora?`** (IF sobre
  `updated_count`) → rama `true`: **`Avisar en chat: Resultado MT4`**
  (Telegram, texto distinto para éxito/fallo) → ambas ramas confluyen
  en **`Borrar archivo de resultado`** (Code, `fs.promises.unlink`,
  se ejecuta siempre haya o no notificado).
  - **Detalle técnico no obvio, encontrado en esta etapa:** esta
    versión de n8n usa modo de binarios `filesystem-v2`
    (`settings.binaryMode: "separate"`) — el contenido del archivo
    leído por `readWriteFile` **no** viaja en base64 dentro de
    `item.binary.data.data` (ahí solo hay el string literal
    `"filesystem-v2"`, un marcador). Hay que leer el contenido real
    con `await this.helpers.getBinaryDataBuffer(i, 'data')` dentro
    del Code node. Intentar `Buffer.from(item.binary.data.data,
    'base64')` como en versiones más viejas de n8n rompe con
    `SyntaxError: ... is not valid JSON` (el string `"filesystem-v2"`
    decodificado de "base64" da bytes basura).
  - **Segundo detalle no obvio:** el nodo Postgres intermedio
    reemplaza `item.json` por las columnas devueltas por la query, así
    que el nodo de borrado no puede leer `$json.fileName` directo —
    hay que recuperarlo del nodo `Parsear resultado (MT4)` usando el
    `pairedItem` del item actual (`$('Parsear resultado (MT4)').all()
    [idx].json.fileName`, con `idx` sacado de `item.pairedItem.item`)
    para que el índice sea correcto incluso si el IF divide en dos
    ramas.
  - Requiere `NODE_FUNCTION_ALLOW_BUILTIN=fs` en el servicio `n8n` de
    `docker-compose.yml` (n8n restringe qué módulos built-in de Node
    puede usar un Code node) — agregado.
  - **Probado en real:** al implementar esto había 5 archivos de
    `results/` acumulados de pruebas manuales previas de la Etapa 6
    (EA) que nunca se habían consumido (`7.json`...`11.json`) — el
    trigger nuevo los procesó todos en el primer ciclo, actualizó
    Postgres (`7` y `8` a `PENDING_MANUAL` por error real del EA, `9`,
    `10`, `11` a `OPEN` con tickets reales de VT Markets) y los borró.
    Además se probó manualmente un archivo `999999.json` con
    `signal_id` inexistente en Postgres: `updated_count` dio `0`
    (sin error), no se mandó notificación (la señal nunca estuvo en
    `CONFIRMED`), y el archivo igual se borró — comportamiento
    idempotente correcto.
  - Workflow sincronizado de vuelta a
    `n8n-workflows/webhook-mvp-workflow.json` tras subir los nodos vía
    `PUT /api/v1/workflows/{id}`.

## Documentación de instalación — completa hasta esta etapa

- `docs/INSTALL_LINUX.md` — guía completa desde SO recién instalado:
  Docker/Docker Compose, plantilla de `.env`, levantar el stack, aplicar
  `schema.sql` manual si el volumen ya existía, `scripts/setup-mt4.sh`
  paso a paso, instalación real de MT4 con el instalador de VT Markets,
  fix de `set -gx WINEPREFIX` (fish shell, no `export` como en bash),
  symlinks de `mt4-bridge/` y por qué son locales, verificación del
  puente de archivos.
- `docs/INSTALL_WINDOWS.md` — mismo flujo para Windows nativo (Docker
  Desktop o WSL2, MT4 sin Wine vía `scripts/setup-mt4.ps1`, ruta
  `%APPDATA%\MetaQuotes\Terminal\Common\Files\` en vez de la ruta con
  prefijo de Wine, equivalente con `mklink`). Marcado explícitamente
  como **no verificado end-to-end** (a diferencia del de Linux, que sí
  se probó en la máquina real del usuario).

## Desde el snapshot del 14/08 — qué se agregó

- **Dashboard (Flask, `localhost:8088`)**: posiciones abiertas en vivo
  (precio, profit, SL/TP), botones **BE** y **Cerrar** por posición
  (escriben comandos que el EA lee de `orders/actions/` y ejecuta),
  botón **Reintentar** para señales en `PENDING_MANUAL`, historial de
  señales con filtros por período y numeración de ciclo visual (1-20,
  se resumen las más viejas en la fila "#0"), y un selector de sufijo
  de símbolo del bróker (`-VIP` demo / `-STD` real) que el EA lee en
  caliente desde `orders/config.json` sin recompilar.
- **Fix de pérdida de eventos en Telethon**: en el grupo real (~3900
  suscriptores, tráfico alto), Telethon a veces pedía un resync de
  "difference" ante un gap de `pts` y no volvía a disparar
  `events.NewMessage` — el mensaje se perdía en silencio. Se agregó un
  polling de respaldo cada 15s sobre el historial reciente del chat,
  deduplicado por `message_id`, como red de seguridad del evento en
  vivo. También se corrigió el `timestamp` enviado a n8n para usar la
  fecha real del mensaje (`message.date`) en vez de la hora de captura.
- **Nodo de debug en n8n**: notifica por Telegram privado cualquier
  mensaje del grupo que no matchee el regex de señal nueva, para poder
  confirmar en vivo que Telethon está leyendo el grupo correcto.
- **Repo limpio**: historia de git reescrita para sacar atribución de
  herramientas de IA en los commits, ramas viejas ya mergeadas
  eliminadas (local y remoto), solo quedan `main` y `develop`.
- **README y documentación reestructurados** para portafolio: la
  historia y el porqué del proyecto viven en `README.md`; el detalle
  técnico completo (decisiones de arquitectura, retos técnicos,
  instalación, configuración, roadmap) vive en `docs/versions/v1.md`,
  versionado aparte para cuando exista v2.

## Qué NO hace todavía

- **Interpretación por Gemini** (Fase 4 del roadmap original) — mover
  SL, BE, cerrar, `CLOSE_AT_PRICE` — diseñado en detalle en
  `PROTOCOLOS_KRONOS_BOT.md`, cero código.
- **Cálculo de lotaje por slots** (80/20, sección 5.3 del protocolo) —
  fórmula definida, no implementada. Todas las señales (incluidas ambas
  sub-señales de una señal multi-TP) usan lotaje fijo `0.01`.
- **Ciclo de cierre y registro en Google Sheets** (Fase 7) — sin
  empezar. Los cierres (BE/Cerrar) hoy se hacen manual desde el
  dashboard, y no se registran en ningún lado fuera de Postgres.
- **Loop de reintento de precio con Gemini** (protocolo sección 8) —
  depende de que exista la ejecución real en MT4.
- **Ejecución 100% automática sin confirmación** (Fase 8, futuro) — todo
  el diseño actual asume confirmación humana obligatoria (protocolo,
  principio no negociable #3).

## Próximos pasos inmediatos (en orden)

1. **Conectar Gemini (Fase 4)** para interpretar instrucciones de
   seguimiento en lenguaje libre y aplicarlas solo (hoy es 100% manual
   vía dashboard — ver el aviso al principio de este documento). Es el
   gap operativo más importante mientras se opera con dinero real.
2. Cálculo de lotaje por slots (80/20, protocolo sección 5.3) — hoy
   fijo en `0.01`.
3. Ciclo de cierre y registro en Google Sheets (Fase 7).
4. Recién después: evaluar ejecución 100% automática sin confirmación
   (Fase 8), con el historial de v1 como respaldo de confianza.

## Fases (referencia de `CLAUDE.md`)

- ✅ Fase 0 — credenciales Telegram, estructura de carpetas.
- ✅ Fase 1 — microservicio Telethon capturando y enviando al webhook,
  con polling de respaldo agregado por pérdida de eventos en canales
  de alto tráfico.
- ✅ Fase 2 — base de datos Postgres, auto-init vía
  `docker-entrypoint-initdb.d`.
- ✅ Fase 3 — webhook + parser regex (incluye multi-TP), verificado
  end-to-end.
- 🔲 Fase 4 — interpretación por Gemini. No iniciada — gap operativo
  activo (ver aviso al inicio del documento).
- ✅ Fase 5 — botones de confirmar/rechazar funcionales, idempotentes,
  con mensaje de confirmación visible en el chat.
- ✅ Fase 6 — EA puente en MT4. Completa y verificada end-to-end con
  dinero real: Wine/MT4 con sesión real, EA compilado y ejecutando,
  nodos n8n de escribir orden / leer resultado funcionando, tickets
  reales confirmados en la cuenta `23096429`.
- 🔲 Fase 7 — cierre y registro en Google Sheets. Cierres manuales hoy
  vía dashboard, sin registro fuera de Postgres.
- 🔲 Fase 8 — ejecución 100% automática (futuro, meta de v2).
