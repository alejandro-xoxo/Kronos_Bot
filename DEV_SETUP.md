# Setup del stack de PRUEBAS — guía paso a paso

**Archivo temporal, no commitear.** Sirve para levantar
`docker-compose.dev.yml` en paralelo al stack de producción sin
tocarlo. Hacer los pasos EN ORDEN — varios son prerequisito de los
siguientes.

---

## 0. Hallazgos importantes antes de empezar (no asumir lo contrario)

1. **`GEMINI_API_KEY` ya tiene un valor cargado en `.env` de
   producción.** Verificado sin imprimir el valor: la línea no está
   vacía (`~54 caracteres`, consistente con una API key real). **No
   hace falta generar una key nueva desde cero** — pero **sí conviene
   generar una SEGUNDA key distinta para el stack dev, no reusar la
   misma.** La capa gratuita de Gemini limita por API key (requests
   por minuto y por día), no por proyecto ni por instancia de n8n —
   si dev y producción comparten key, las pruebas le comen cuota a
   producción, con riesgo de que una tanda de pruebas haga que
   producción reciba un `429 rate limit` justo durante una instrucción
   de seguimiento real. Generar la segunda key es gratis (mismo tier).
   Poner esta segunda key en `GEMINI_API_KEY` de `.env.dev` — no la de
   producción.
2. **NO correr `scripts/setup-mt4.sh` para el prefijo demo.** Ese
   script apunta siempre a `mt4-bridge/orders/` del repo — que son los
   symlinks que usa el stack de **producción**. Correrlo con
   `~/.wine-mt4-demo` de por medio arriesga repisar esos symlinks. Para
   el prefijo demo, todo se crea a mano (sección 3) y `.env.dev` apunta
   directo a la carpeta real, sin pasar por ningún symlink del repo.
3. **El webhook del bot de Telegram solo puede apuntar a UNA URL a la
   vez, por token de bot.** Si el workflow de n8n en el stack dev usa
   el **mismo bot** (mismo token) que producción, activar el workflow
   dev le va a robar el webhook al de producción (o viceversa, según
   cuál se active último) — los botones Confirmar/Rechazar dejarían de
   funcionar en el que se quedó sin webhook, sin ningún error visible
   aparte de que los clics dejan de notificar. **Hace falta un BOT
   DE TELEGRAM DISTINTO para pruebas** (ver sección 5).

---

## 1. Comandos exactos — levantar / verificar / bajar el stack dev

Ejecutar siempre desde la raíz del repo (`/home/alejandroa/Proyectos/Kronos_Bot`),
siempre con `-f`/`--env-file` explícitos.

### Levantar

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev up -d
```

### Ver que levantó bien (contenedores, logs)

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev ps
docker compose -f docker-compose.dev.yml --env-file .env.dev logs -f n8n
# Ctrl+C para salir del -f (sigue mostrando logs en vivo)
```

### Confirmar que producción sigue intacta, sin tocarla

```bash
docker compose ps
# (el docker-compose.yml de producción, comando normal sin flags nuevos)
```

### Acceder a los servicios del stack dev

- n8n dev: `http://localhost:5679`
- postgres dev: `localhost:5433` (mismo `POSTGRES_USER`/`DB` que pongas en `.env.dev`)
- dashboard dev: `http://localhost:8089`

### Bajar SOLO el stack dev

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev down
```

Esto no toca volúmenes (`down` sin `-v`). Si en algún momento querés
borrar también los datos del stack dev desde cero:

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev down -v
```

**Nunca correr `docker compose down -v` sin `-f docker-compose.dev.yml`**
— sin el flag, apunta al `docker-compose.yml` de producción por
defecto y borraría sus volúmenes reales.

---

## 2. Variables a completar en `.env.dev` antes de levantar el stack

Lista completa, con qué poner en cada una:

| Variable | Qué poner | Notas |
|---|---|---|
| `N8N_HOST` | Dominio del segundo túnel ngrok (ver sección 4) | Vacío = usar sin `--domain` fijo en el compose, ver sección 4 |
| `NGROK_AUTHTOKEN_DEV` | Token de ngrok para el túnel dev | Puede ser el mismo token que producción SI tu plan de ngrok permite 2 túneles simultáneos; si no, necesitás una segunda cuenta/token |
| `TELEGRAM_API_ID` | Igual que en `.env` de producción | Es la credencial de la app registrada en my.telegram.org, no de la sesión — se puede reusar |
| `TELEGRAM_API_HASH` | Igual que en `.env` de producción | Mismo criterio que arriba |
| `TELEGRAM_PHONE` | Tu número de teléfono | El mismo de siempre, salvo que quieras loguear Telethon con otra cuenta |
| `TELEGRAM_GROUP_ID` | ID del grupo/chat de PRUEBA (NO el grupo real) | Creá un grupo propio o usate a vos mismo como chat, mandate mensajes con el formato de señal para simular |
| `TELEGRAM_USER_CHAT_ID` | Tu chat ID privado (puede ser el mismo que producción) | Es donde llegan las notificaciones — puede ser igual, solo cambia el bot que las manda (sección 5) |
| `POSTGRES_USER` | Uno nuevo, distinto al de producción (ej. `kronos_dev`) | No es obligatorio que sea distinto (la instancia ya está aislada), pero ayuda a no confundir si algún día conectás con un cliente psql a mano |
| `POSTGRES_PASSWORD` | Una contraseña nueva | No reusar la de producción |
| `POSTGRES_DB` | Ej. `kronos_dev` | — |
| `MT4_ORDERS_HOST_PATH_DEV` | `/home/alejandroa/.wine-mt4-demo/drive_c/users/alejandroa/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders` | Se confirma el path exacto en la sección 3, paso 4 (puede variar el nombre de usuario de Windows dentro de Wine) |
| `KRONOS_WEBHOOK_SECRET` | Uno nuevo — generar con `openssl rand -hex 32` | Nunca reusar el de producción |
| `GEMINI_API_KEY` | **Generar una SEGUNDA key**, distinta a la de `.env` de producción (ver punto 0.1) | No reusar la de producción — comparten cuota gratuita por key, no por proyecto |

Para generar `KRONOS_WEBHOOK_SECRET`:

```bash
openssl rand -hex 32
```

---

## 3. Crear el segundo prefijo de Wine e instalar MT4 (cuenta demo)

Pasos manuales, en orden. Basado en lo que ya funcionó para el
prefijo de producción (`docs/INSTALL_LINUX.md`), pero **con nombres
distintos en cada paso** para no chocar con `~/.wine-mt4`.

### Paso 1 — Crear el prefijo de Wine nuevo

```bash
export WINEPREFIX=~/.wine-mt4-demo
# fish shell: set -gx WINEPREFIX ~/.wine-mt4-demo   (persistir en config.fish si querés que quede)
wineboot --init
```

No usar `WINEARCH=win32` (ya no es válido en Wine 7+, modo `wow64`
combinado — mismo fix que ya se aplicó en `scripts/setup-mt4.sh` para
el prefijo de producción). El prefijo por defecto corre MT4 (32 bits)
sin problema.

### Paso 2 — Descargar e instalar MT4 con el instalador de VT Markets

Mismo instalador que producción (`vtmarkets4setup.exe`, de
vtmarkets.com) — la cuenta demo también es de VT Markets, así que el
terminal es el mismo software, solo cambia a qué servidor/cuenta te
logueás.

```bash
cd ~/Downloads   # o donde hayas guardado vtmarkets4setup.exe
WINEPREFIX=~/.wine-mt4-demo wine vtmarkets4setup.exe
```

Seguir el instalador gráfico (Wine va a abrir la ventana normal del
instalador de MT4). Instalar en la ruta que proponga por defecto
dentro del prefijo.

### Paso 3 — Loguear la cuenta demo

Abrir el terminal ya instalado:

```bash
WINEPREFIX=~/.wine-mt4-demo wine ~/.wine-mt4-demo/drive_c/Program\ Files\ \(x86\)/VT\ Markets*/terminal.exe
```

(el nombre exacto de la carpeta puede variar un poco según cómo lo
haya llamado el instalador — revisar con
`ls ~/.wine-mt4-demo/drive_c/Program\ Files\ \(x86\)/` si el comando
de arriba no encuentra el ejecutable).

Dentro de MT4: **Archivo → Login a Cuenta de Trading** → ingresar
número de cuenta `911260411` y el servidor demo correspondiente de VT
Markets (lo tenés que tener a mano, junto con el password — no lo
pegues en ningún archivo de este repo).

### Paso 4 — Confirmar la ruta real de `Common/Files/orders` y crearla

```bash
find ~/.wine-mt4-demo/drive_c/users -maxdepth 6 -ipath '*/MetaQuotes/Terminal/Common' 2>/dev/null
```

Esto va a imprimir algo como:

```
/home/alejandroa/.wine-mt4-demo/drive_c/users/alejandroa/AppData/Roaming/MetaQuotes/Terminal/Common
```

Confirmar que ese path (con `/Files/orders` al final) es exactamente
lo que vas a poner en `MT4_ORDERS_HOST_PATH_DEV` de `.env.dev`. Crear
las subcarpetas necesarias (Docker no las crea solo si el bind mount
apunta a algo que no existe):

```bash
mkdir -p ~/.wine-mt4-demo/drive_c/users/alejandroa/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/pending
mkdir -p ~/.wine-mt4-demo/drive_c/users/alejandroa/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/results
mkdir -p ~/.wine-mt4-demo/drive_c/users/alejandroa/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/closed
mkdir -p ~/.wine-mt4-demo/drive_c/users/alejandroa/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/actions
```

**No hace falta crear ningún symlink dentro de `mt4-bridge/orders/`
del repo para esto** — el stack dev de Docker monta
`MT4_ORDERS_HOST_PATH_DEV` directo, sin pasar por esos symlinks (esos
solo los usa/crea `scripts/setup-mt4.sh`, que acá no corremos).

### Paso 5 — Compilar y adjuntar el EA en el terminal demo

Igual que en producción: `F4` (MetaEditor) → abrir
`KronosBridgeEA.mq4` (vas a tener que copiarlo a
`~/.wine-mt4-demo/.../MQL4/Experts/` primero, no está ahí todavía) →
`F7` para compilar → volver a MT4 → arrastrar el EA al gráfico del
símbolo que quieras probar (ej. `XAUUSD-VIP` o el sufijo que use la
cuenta demo) → confirmar en **Inputs** que `InpProfile` está en
`PROFILE_DEMO_VIP` (el EA valida `AccountNumber()` contra el perfil
elegido y bloquea la ejecución con `ACCOUNT MISMATCH` en Experts si
no coincide — doble verificar acá para no repetir del lado demo el
mismo tipo de bug ya visto en producción).

---

## 4. Segundo dominio de ngrok (para que Telegram llegue al n8n dev)

ngrok gratuito normalmente da **un solo dominio fijo reservado** por
cuenta. Opciones, de más a menos recomendable:

### Opción A — Sin dominio fijo (más simple, más frágil)

Dejar `N8N_HOST` vacío en `.env.dev` y quitar la línea
`--domain=${N8N_HOST}` del comando del servicio `ngrok` en
`docker-compose.dev.yml` (ya está comentado ahí qué línea borrar).
Cada vez que reiniciás el contenedor `ngrok` del stack dev, te da una
URL nueva al azar (`algo-random.ngrok-free.app`) — hay que volver a
activar el workflow en n8n dev (o simplemente reiniciar el contenedor
`n8n` dev después de que `ngrok` levante, así toma la URL nueva al
activarse) para que el webhook de Telegram quede apuntando ahí.

Para ver qué URL le tocó en un momento dado:

```bash
docker compose -f docker-compose.dev.yml --env-file .env.dev logs ngrok | grep -i "started tunnel\|url="
```

### Opción B — Segundo dominio fijo reservado (más estable)

1. Entrar a https://dashboard.ngrok.com/domains con la cuenta de
   ngrok que uses.
2. Click en **"+ New Domain"** (o **"Create Domain"**).
3. ngrok genera un subdominio fijo gratuito tipo
   `algo-nuevo.ngrok-free.dev` (igual que el que ya tenés para
   producción, `cradle-imprint-substance.ngrok-free.dev`).
4. **Atención al límite del plan free:** la mayoría de los planes
   gratuitos de ngrok permiten **un solo dominio fijo reservado por
   cuenta**. Si al crear el segundo te bloquea o te pide upgrade,
   las alternativas son: (a) usar la Opción A (sin dominio fijo) para
   el stack dev, o (b) crear una segunda cuenta de ngrok gratuita
   distinta solo para pruebas, con su propio `NGROK_AUTHTOKEN_DEV`.
5. Copiar el dominio nuevo a `N8N_HOST` en `.env.dev`.

---

## 5. Bot de Telegram separado para pruebas (obligatorio, ver punto 0.3)

1. Hablarle a **@BotFather** en Telegram (con tu cuenta de usuario
   normal, la misma que ya usás).
2. `/newbot` → elegir un nombre y un username único (ej.
   `KronosBotDev_bot`).
3. BotFather te da un **token nuevo** — copiarlo, no compartirlo, no
   pegarlo en ningún archivo de este repo.
4. En el workflow de n8n del stack **dev** (`http://localhost:5679`),
   los nodos `Notificar Telegram`, `Trigger Callback Telegram`,
   `Responder callback: *`, `Avisar en chat: *` necesitan una
   credencial de Telegram nueva apuntando a este bot nuevo — se crea
   dentro de la UI de n8n (Credentials → Telegram API → pegar el
   token del bot nuevo), **no va en `.env.dev`** (las credenciales de
   nodos de n8n viven en la base de la instancia n8n, no en variables
   de entorno).
5. Escribirle un mensaje a tu bot nuevo desde tu cuenta de Telegram
   (cualquier mensaje, ej. "hola") — es necesario para que el bot
   pueda iniciar conversación con vos y mandarte notificaciones
   (los bots de Telegram no pueden escribirle primero a un usuario
   que nunca les escribió).
6. Confirmar `TELEGRAM_USER_CHAT_ID` en `.env.dev` — puede ser el
   mismo chat ID numérico que ya usás en producción (es tu ID de
   usuario de Telegram, no cambia por bot), lo que cambia es qué bot
   te manda el mensaje.

---

## 6. Orden recomendado para la primera levantada

1. Sección 2 → completar `.env.dev` (menos `MT4_ORDERS_HOST_PATH_DEV`
   y `N8N_HOST` todavía).
2. Sección 3 → prefijo Wine demo + cuenta logueada + EA compilado y
   corriendo → recién ahí completar `MT4_ORDERS_HOST_PATH_DEV`.
3. Sección 4 → decidir Opción A o B de ngrok → completar `N8N_HOST` y
   `NGROK_AUTHTOKEN_DEV`.
4. Sección 1 → `docker compose -f docker-compose.dev.yml --env-file .env.dev up -d`.
5. Entrar a `http://localhost:5679`, importar
   `n8n-workflows/webhook-dev-workflow.json` a mano (Import from File
   en la UI de n8n) — **no lo sube nadie por API a esta instancia
   dev automáticamente**, es un paso manual la primera vez.
   **NUNCA importar `webhook-mvp-workflow.json`** (el de
   producción) en la instancia dev — ver la regla no negociable de
   `CLAUDE.md` sobre los nodos de entrada (`Webhook`+Telethon en
   prod vs `Telegram Trigger` en dev): son estructuralmente
   distintos y permanentes por ambiente, nunca se restauran uno
   desde el otro.
6. Sección 5 → conectar el bot de Telegram nuevo a los nodos de
   Telegram del workflow recién importado.
7. Activar el workflow en n8n dev, mandar un mensaje de prueba al
   grupo/chat de `TELEGRAM_GROUP_ID` con formato de señal, confirmar
   que todo el ciclo corre contra la cuenta demo sin tocar nada de
   producción.
