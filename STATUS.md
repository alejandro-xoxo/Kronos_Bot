# Kronos Bot — Estado actual

> Snapshot técnico del proyecto al 2026-08-18, rama `develop`. Pensado
> para poder pegarse completo a una sesión nueva de Claude Code (o de
> cualquier asistente) sin depender de memoria de conversación previa.
> Para reglas de negocio detalladas ver `PROTOCOLOS_KRONOS_BOT.md`; para
> contexto general y reglas de trabajo, `CLAUDE.md`; para el detalle de
> alcance de v1 (qué incluye y qué queda afuera a propósito),
> `docs/versions/v1.md`.

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

**Fase 4 (Gemini) ya está mergeada a `develop`, pero NO está en
producción todavía.** El código de interpretación de instrucciones de
seguimiento ("mover el SL a BE", "cerrar a X -Y PIPS") y el consumidor
de cierres TP/SL (`feature/cierre-tp-sl`) están en `develop`
(`3f19e91`, `7e64a4b`), pero el workflow que corre en vivo
(`QxXebyoPgTGmGH2B`, cuenta real VT Markets) **sigue siendo el viejo**
— no se subió por API todavía. Además hay un bloqueante real
confirmado: **`GEMINI_API_KEY` no existe ni en `.env` ni en
`docker-compose.yml`** — sin eso, cada instrucción de seguimiento real
fallaría al llamar a Gemini y caería a `PENDING_MANUAL` (no rompe el
sistema gracias al fix de retry, pero Fase 4 no cumpliría su propósito
real hasta agregar la key). Plan de subida completo, con riesgos de
merge de JSON de n8n y comandos exactos, en `MERGE_PLAN.md` (raíz del
repo, sin commitear — es un documento de trabajo, no un artefacto del
repo). Mientras tanto, sigue siendo **100% responsabilidad manual del
usuario** aplicar SL/BE/cierres vía los botones del dashboard
(`localhost:8088`).

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

**Reorganización visual del workflow (sin commitear):** el JSON de
`n8n-workflows/webhook-mvp-workflow.json` en el working tree tiene 5
notas adhesivas nuevas (`stickyNote`) agrupando el canvas en secciones
(1. Captura y parseo, 2. Confirmación Telegram, 3. Seguimiento/Fase 4,
4. Ejecución en MT4, 5. Detección de cierres TP/SL) y varios nodos
reposicionados para que coincidan visualmente con esos grupos. Es solo
reordenamiento/documentación del canvas — no cambia tipos de nodo, no
agrega ni quita lógica (mismo conteo de nodos funcionales antes y
después del diff).

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
- **Intento de cambio en `.gitignore` — revertido, ya no es tema
  pendiente.** Hubo un cambio local sin commitear que reemplazaba el
  patrón de ignorar el *contenido* de las carpetas
  (`mt4-bridge/orders/pending/*` / `results/*`, con excepción explícita
  de los `.gitkeep`) por ignorar directamente las rutas completas
  (sin excepción de `.gitkeep`) — eso habría dejado a los `.gitkeep`
  fuera del tracking la próxima vez que se tocara ese archivo, algo
  que el usuario confirmó explícitamente que nunca quiso. Se revirtió
  con `git checkout -- .gitignore`. El patrón vigente sigue siendo el
  original: ignora contenido, con excepción explícita para los
  `.gitkeep`, que siguen versionados tal como exige `CLAUDE.md`.

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
  - `WritePositionsStatus()` reporta `account.balance`, `account.equity`
    y **`account.capital_real`** (`AccountBalance() - AccountCredit()`,
    protocolo sección 5.2 / regla no negociable de `CLAUDE.md`: nunca
    usar `AccountBalance()` solo para capital, puede incluir crédito
    del bróker) — pensado para que n8n actualice `settings.capital_real`
    sin edición manual. **Cambio local sin commitear todavía** (no
    subido a `develop` ni a producción); falta el lado de n8n que lo
    consuma (el nodo `Obtener capital real (settings)` de las ramas de
    `MERGE_PLAN.md` lee de la tabla `settings`, no de este campo del
    EA directamente — falta conectar ambos).
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
- **Detección de motivo de cierre (TP vs SL)** — **lado EA
  implementado** (`DetectClosedPositions()` en `KronosBridgeEA.mq4`,
  ver `mt4-bridge/FORMATO_ARCHIVOS.md` sección 5.1): compara
  `OrderClosePrice()` contra TP/SL y escribe
  `orders/closed/<ticket>.json` con `TP_REACHED`/`SL_REACHED`/
  `CLOSED_MANUAL`. **Sin probar en real todavía** — requiere
  recompilar el `.ex4` con MetaEditor (GUI) antes de tomar efecto.
  **Falta el lado de n8n**: un nodo que lea `closed/*.json` (mismo
  patrón que `results/`, sección 6) y actualice `signals.status` en
  Postgres — sin esto los archivos se acumulan sin consumirse. No se
  tocó el workflow de n8n en vivo en esta pasada por ser un sistema
  operando con dinero real y sin forma de probar el workflow importado
  en este entorno; ver sección 5.1 del formato para el detalle exacto
  de los nodos que faltan.

## ⚠️ Errores persistentes / problemas abiertos que necesitan iteración

Lista de problemas conocidos, reales o de diseño, que **no están
resueltos** y no son un simple "próximo paso" — requieren decisión,
prueba en real, o iteración adicional antes de darlos por cerrados.

1. **`GEMINI_API_KEY` ausente — bloqueante confirmado para Fase 4.**
   No está en `.env` ni referenciada en `docker-compose.yml`
   (servicio `n8n`, sección `environment`). Sin esto, el nodo
   `Interpretar con Gemini` falla siempre. Falta: conseguir la key
   (capa gratuita, ver `CLAUDE.md`), agregarla en ambos lugares, y
   reiniciar el contenedor de n8n para que la tome. Ver Paso 3 de
   `MERGE_PLAN.md`.
2. **Workflow de producción — verificado por `GET` en vivo el
   2026-08-18, YA SINCRONIZADO (corrige la entrada anterior de este
   punto).** Se consultó `GET /api/v1/workflows/QxXebyoPgTGmGH2B` y se
   comparó nodo por nodo y `connections` completo contra el JSON local
   (`develop` + working tree): **56 nodos en ambos, cero diferencias**
   — Fase 4, consumidor de cierres TP/SL, y el fix de sin-tope de
   sub-señales ya están todos en producción. El nombre del workflow
   sigue diciendo "MVP Fase 3" (cosmético, no se actualizó al renombrar
   fases) — no confundir el nombre con el contenido real. `MERGE_PLAN.md`
   describía esto como pendiente; ya no lo está para el JSON del
   workflow en sí (sigue pendiente el `GEMINI_API_KEY`, punto 1, y
   recompilar el EA, punto 3, para que lo ya subido funcione de
   punta a punta).
3. **`DetectClosedPositions()` sin probar en real.** La función que
   detecta motivo de cierre (TP/SL/manual) en `KronosBridgeEA.mq4`
   está escrita pero el `.ex4` en producción no está recompilado con
   ella todavía — requiere abrir MetaEditor (GUI) en la máquina con
   Wine, compilar (`F7`), remover y volver a arrastrar el EA al
   gráfico (MT4 no recarga el `.ex4` solo). Hasta que esto pase, el
   nodo n8n que consume `orders/closed/*.json` no tiene nada que leer
   en producción, aunque ya esté mergeado a `develop`.
4. **`docs/INSTALL_WINDOWS.md` no verificado end-to-end.** A
   diferencia de la guía Linux (probada en la máquina real del
   usuario), la de Windows nunca se corrió de punta a punta — puede
   tener pasos rotos o desactualizados si alguien la sigue tal cual.
5. **Pérdida de eventos de Telethon — mitigado, no eliminado.** El
   polling de respaldo cada 15s reduce el riesgo de perder mensajes
   cuando Telegram fuerza un resync de "difference" en el grupo de
   alto tráfico, pero sigue siendo un parche sobre un problema de
   fondo (la librería no siempre re-dispara `events.NewMessage` tras
   el resync). No hay alerta si el polling de respaldo también
   fallara silenciosamente — nadie se entera salvo revisando logs.
6. **Sin cálculo de lotaje real (80/20).** Todas las señales — incluida
   cada sub-señal de una señal multi-TP — usan `0.01` fijo. La fórmula
   de slots está definida en el protocolo (sección 5.3) pero no
   implementada ni probada; hasta que exista, el sistema no gestiona
   riesgo real de forma proporcional al capital.
7. **`error 4109` (trade context busy) — mitigado con pausa fija, no
   resuelto de raíz.** Al abrir 2 sub-señales del mismo instrumento
   casi simultáneas, el bróker rechazaba la segunda `OrderSend`. Se
   agregó una pausa corta entre órdenes consecutivas como parche; no
   hay reintento automático si el error igual ocurriera bajo más
   carga (ej. 3+ sub-señales si se saca el tope, ver punto de
   `sin-tope-sub-senales` arriba).
8. **Sin registro de cierres fuera de Postgres (Fase 7 completa).**
   Aun cuando se cierre el lazo de detección TP/SL (punto 3), el
   registro en Google Sheets sigue sin existir — los cierres viven
   solo en la base de datos, sin respaldo externo ni reporte legible
   fuera del dashboard.
9. **Gemini / Fase 4 — PENDIENTE DE REDISEÑO CON APROBACIÓN EXPLÍCITA
   DEL USUARIO. No subir a producción bajo ninguna circunstancia hasta
   entonces, tiene prioridad sobre cualquier otro trabajo de Fase 4.**
   El diseño actual (árbol de decisión regex + Gemini, ver
   `MERGE_PLAN.md` sección 2 para el detalle de los 15 nodos) se
   construyó sin que el usuario lo aprobara paso a paso como el resto
   del sistema. Aunque el JSON ya está técnicamente en producción
   (punto 2, arriba) y sigue bloqueado en la práctica por la falta de
   `GEMINI_API_KEY` (punto 1), **eso no equivale a aprobación de
   diseño** — no activarlo (ni conseguir la key, ni destrabarlo) sin
   pasar antes por ese rediseño conjunto.
10. **`error 4109` (trade context busy) — decisión de fix ya tomada,
    falta implementar.** En vez del parche actual de pausa fija entre
    `OrderSend()` consecutivos, el EA debe procesar **una sola orden**
    de `orders/pending/` por ciclo de `OnTimer`, no todas las que
    encuentre de una vez — elimina la causa raíz (varios `OrderSend()`
    casi simultáneos) en lugar de mitigarla. Se implementa después de
    confirmar el punto 11 (medir lentitud antes de tocar el timing del
    EA, para no introducir un cambio de performance a ciegas).
11. **Percepción de lentitud — sin medir todavía, no optimizar a
    ciegas.** Hay percepción de que el sistema es lento, pero no hay
    datos: falta agregar timestamps de diagnóstico en los puntos clave
    del flujo (llegada del webhook, inicio/fin de cada nodo relevante,
    latencia de Gemini si aplica) para identificar con datos reales
    dónde está la lentitud, en vez de asumir que es por "muchos
    listeners" u otra causa no verificada.
12. **Límite de operaciones simultáneas según capital — diseño actual
    en revisión, fórmula nueva AÚN NO DEFINIDA con precisión.** Hoy es
    `floor(capital/100)` operaciones a lotaje fijo `0.01` (ver punto 6).
    Propuesta del usuario en discusión: máximo 5 operaciones
    simultáneas, escalando con el capital, con lotaje ligeramente
    mayor en la primera operación al cruzar ciertos umbrales (ej.
    $600) — falta una tabla completa de ejemplos confirmados por el
    usuario antes de implementar cualquier cosa. No asumir la fórmula
    todavía.
13. **Crecimiento de la base de datos — pendiente de decisión sobre
    pérdida de detalle al archivar.** El trigger de compactación
    (`signals_archive_summary`, tope de 20 filas activas en `signals`,
    ver `db/schema.sql`) ya funciona, pero pierde el detalle fila por
    fila de lo archivado — solo queda el agregado. Falta decidir con
    el usuario si importa poder auditar señales viejas en detalle
    después de archivadas, o si el resumen agregado alcanza. Si
    importa el detalle, evaluar exportar a Google Sheets (Fase 7)
    **antes** de que el trigger las borre, no solo cuando el trigger
    las toque.
14. **Causa raíz encontrada de "las órdenes no se ejecutan al
    confirmar" — DIAGNOSTICADO, pendiente de verificación del usuario
    (no marcar resuelto hasta confirmar).** `orders/config.json` tenía
    `{"symbol_suffix": "-VIP"}` mientras la cuenta real (`23096429`,
    gráficos `-STD`) necesita `-STD`. Evidencia directa en
    `MQL4/Logs/20260818.log`: múltiples `OrderSend falló, error 130`
    (`ERR_INVALID_STOPS`) para señales reales confirmadas
    (`signal_id` 2, 3, 12, 13, 19, 20 — señales `9695-B`, `77770001-A`,
    `9719-A/B`, `9726-A/B`), y errores repetidos de "mover a
    break-even" con el mismo símbolo mal configurado. El usuario está
    corrigiendo `config.json` a `-STD` a mano desde el selector del
    dashboard (`localhost:8088`) para verlo en vivo — **actualizar este
    punto a "resuelto" recién cuando confirme que las próximas señales
    ejecutan bien**, no antes.
15. **Falta validación que impida repetir el error del punto 14 —
    especialmente ahora que va a existir un segundo stack de pruebas
    en paralelo (demo, `-VIP`, ver `docker-compose.dev.yml`) corriendo
    junto al de producción (real, `-STD`) en la misma máquina.** Hoy
    `config.json` es un archivo plano sin ningún chequeo — nada impide
    que alguien deje el sufijo de un stack aplicado al otro. Ideas a
    evaluar (sin implementar todavía, decidir con el usuario):
    - **En el EA:** hardcodear (o leer de `orders/config.json`) el
      número de cuenta esperado por sufijo (`23096429` → `-STD`,
      `911260411` → `-STD` en la cuenta demo si mantiene el mismo
      símbolo, o el que corresponda) y comparar contra
      `AccountNumber()` al arrancar y en cada poll — si no coincide,
      **no operar nada**, escribir un error explícito en
      `orders/status.json` y loguear en **Experts** en vez de intentar
      `OrderSend` con un símbolo probablemente inválido para esa
      cuenta. Esto habría bloqueado el bug del punto 14 en vez de
      dejarlo fallar en silencio con error 130.
    - **En el dashboard:** mostrar siempre, junto al selector de
      sufijo, el número de cuenta que reporta `WritePositionsStatus()`
      (`account.number`) al lado del sufijo elegido, con una alerta
      visual si la combinación cuenta/sufijo no es la esperada (mismo
      chequeo que el EA, del lado humano).
    - **Separación física ya ayuda pero no alcanza sola:** el stack de
      pruebas usa un `MT4_ORDERS_HOST_PATH_DEV` distinto (otro prefijo
      de Wine), así que un `config.json` mal puesto en un stack no
      puede pisar el `config.json` del otro — el riesgo real es
      humano (mirar el dashboard equivocado), no de archivo compartido.
16. **Duplicados por reintento de webhook (Telegram/n8n) — identificado
    en una conversación anterior con Claude Code, nunca se llegó a
    documentar en este archivo (se perdió, no está en ningún commit
    del historial de `STATUS.md`) — re-agregado el 2026-08-20.** Si
    Telegram reintenta la entrega de un callback (timeout, error 5xx
    transitorio) o n8n reintenta un nodo HTTP, hoy nada impide que la
    misma confirmación dispare más de una ejecución del flujo — no
    hay constraint `UNIQUE` sobre `message_id` a nivel de callback ni
    control de idempotencia explícito en el nodo que procesa
    Confirmar/Rechazar. **Distinto del bug de las 3 órdenes duplicadas
    resuelto hoy** (commit `1e43027` en `develop`, cherry-pick `70faf71`
    en `main`): ese fue un problema puramente del lado del EA (timer de
    Wine + polling de archivos reprocesando el mismo `.json`), no de
    reintentos de webhook — se confirmó que hubo una sola ejecución de
    n8n y un solo `INSERT`/archivo `pending/` para esa señal. Este
    riesgo (duplicados por reintento HTTP) sigue sin mitigar. Ideas a
    evaluar: constraint `UNIQUE` en `signals.signal_uid` combinado con
    manejo de conflicto (`ON CONFLICT DO NOTHING`) en el `INSERT` de
    confirmación, o un guard idempotente que verifique `status` antes
    de reprocesar un callback ya aplicado (similar al patrón ya usado
    en Fase 5 para no reprocesar doble clic del mismo botón).

## Próximos pasos inmediatos (en orden)

0. **Rediseñar Fase 4 (Gemini) en conjunto con el usuario, paso a
   paso, antes de tocar código o `.env`.** Ver punto 9 de errores
   persistentes: el diseño actual no fue aprobado así como el resto
   del sistema. **No conseguir `GEMINI_API_KEY` ni destrabar el nodo
   de Gemini hasta cerrar ese rediseño** — corrige el paso 0 anterior
   de esta lista, que decía lo contrario.
1. Medir la lentitud percibida antes de tocar timing (punto 11) — solo
   después, implementar el fix real de `error 4109` (una orden por
   ciclo de `OnTimer`, punto 10) y recompilar `KronosBridgeEA.mq4` con
   MetaEditor (incluye también activar `DetectClosedPositions()`, ver
   punto 3 de errores persistentes).
2. Cerrar con el usuario la tabla de ejemplos del nuevo límite de
   operaciones simultáneas por capital (punto 12) antes de implementar
   nada — no asumir la fórmula de `floor(capital/100)` actual como
   definitiva.
3. Decidir con el usuario el punto 13 (exportar a Sheets antes de
   archivar vs. quedarse con el resumen agregado) — ciclo de cierre y
   registro en Google Sheets (Fase 7).
4. Recién después: evaluar ejecución 100% automática sin confirmación
   (Fase 8), con el historial de v1 como respaldo de confianza.

## Qué es "v2" para este proyecto (recomendación)

No hay un salto de versión mayor pendiente de diseño — el roadmap de
`CLAUDE.md` (Fases 0–8) ya es, en efecto, el plan de v2: v1 fue el
sistema manual/semi-manual anterior (mencionado como respaldo de
confianza en el punto 4 de arriba); v2 es este bot con confirmación
humana + ejecución real en MT4. Cerrar los 4 puntos de la lista de
arriba (en ese orden) **es** completar v2. No conviene inventar un
roadmap paralelo — el existente ya está priorizado por riesgo/impacto
y validado en una operación con dinero real, y el punto más importante
sigue siendo el mismo desde el "gap operativo" al principio de este
documento: Gemini (Fase 4) para no depender de gestión 100% manual de
SL/BE/cierres mientras hay posiciones reales abiertas.

## Fases (referencia de `CLAUDE.md`)

- ✅ Fase 0 — credenciales Telegram, estructura de carpetas.
- ✅ Fase 1 — microservicio Telethon capturando y enviando al webhook,
  con polling de respaldo agregado por pérdida de eventos en canales
  de alto tráfico.
- ✅ Fase 2 — base de datos Postgres, auto-init vía
  `docker-entrypoint-initdb.d`.
- ✅ Fase 3 — webhook + parser regex (incluye multi-TP), verificado
  end-to-end.
- 🔶 Fase 4 — interpretación por Gemini. Código mergeado en `develop`
  (rama `feature/fase4-seguimiento`), **no en producción** — falta
  `GEMINI_API_KEY` y subir el workflow (ver aviso al inicio y sección
  de errores persistentes).
- ✅ Fase 5 — botones de confirmar/rechazar funcionales, idempotentes,
  con mensaje de confirmación visible en el chat.
- ✅ Fase 6 — EA puente en MT4. Completa y verificada end-to-end con
  dinero real: Wine/MT4 con sesión real, EA compilado y ejecutando,
  nodos n8n de escribir orden / leer resultado funcionando, tickets
  reales confirmados en la cuenta `23096429`.
- 🔶 Fase 7 — cierre y registro en Google Sheets. El consumidor de
  `orders/closed/*.json` (detección TP/SL) ya está mergeado en
  `develop` (`feature/cierre-tp-sl`) pero sin probar en real — falta
  recompilar el EA. El registro en Google Sheets en sí no existe
  todavía.
- 🔲 Fase 8 — ejecución 100% automática (futuro, meta de v2).
