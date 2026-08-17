# Instalación en Ubuntu Server (headless)

Guía para replicar el entorno completo de Kronos Bot en un **Ubuntu
Server** recién instalado, sin entorno gráfico de escritorio (headless
por diseño — típico de un server dedicado o una VM). Es la variante
para `apt-get` de `docs/INSTALL_LINUX.md` (pensado para distros
Arch-based). Este documento es **vivo**: se actualiza a medida que
avanzan las etapas del proyecto, no solo al final. Estado actual: cubre
Docker, n8n, Postgres, Telethon, Wine, MT4 instalado y logueado,
compilación y activación del EA, y el puente n8n → MT4.

**Diferencia clave respecto a `docs/INSTALL_LINUX.md`:** todo lo que
usa `pacman` pasa a `apt-get`, y la parte gráfica de MT4 (instalador,
login, MetaEditor) necesita un mecanismo explícito de acceso gráfico
(Xvfb + VNC, o X11 forwarding por SSH) porque un server headless no
tiene monitor real ni sesión de escritorio.

## 1. Docker y Docker Compose

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Cerrar sesión y volver a entrar (o `newgrp docker`) para que el grupo
`docker` tome efecto sin necesitar `sudo` en cada comando.

Verificar:

```bash
docker --version
docker compose version
```

## 2. Clonar el repo

```bash
git clone <url-del-repo> Kronos_Bot
cd Kronos_Bot
```

## 3. Variables de entorno (`.env`)

Crear `.env` en la raíz del repo (nunca se commitea — está en
`.gitignore`). Plantilla de las claves necesarias, **sin valores
reales**:

```dotenv
# n8n
N8N_HOST=
N8N_API_KEY=

# ngrok (túnel para exponer el webhook de n8n)
NGROK_AUTHTOKEN=

# Postgres
POSTGRES_USER=
POSTGRES_PASSWORD=
POSTGRES_DB=

# Telethon (credenciales de my.telegram.org + datos de la cuenta)
TELEGRAM_API_ID=
TELEGRAM_API_HASH=
TELEGRAM_PHONE=
TELEGRAM_GROUP_ID=
TELEGRAM_USER_CHAT_ID=

# Puente n8n -> MT4 (ver sección 12 — se completa DESPUÉS de instalar
# MT4 y correr scripts/setup-mt4-ubuntu.sh, no antes)
MT4_ORDERS_HOST_PATH=
```

- `N8N_API_KEY` se genera desde la propia UI de n8n (Settings → n8n
  API → Create an API Key) **después** del primer arranque — se
  agrega a `.env` en un segundo paso, no antes.
- `TELEGRAM_GROUP_ID` y `TELEGRAM_USER_CHAT_ID` se obtienen inspeccionando
  los IDs reales de Telegram (grupo de señales y tu chat privado con
  el bot, respectivamente).
- `MT4_ORDERS_HOST_PATH` se completa en la sección 12.

## 4. Levantar el stack de Docker

```bash
docker compose up -d
```

Esto levanta 4 servicios (ver `docker-compose.yml`):

- `n8n` — orquestador, expuesto en el puerto `5678`.
- `ngrok` — túnel público hacia n8n (dominio fijo vía `N8N_HOST`).
- `postgres` — base de datos (`signals`, `signal_modifications`,
  `settings`).
- `telethon` — microservicio que escucha el grupo de Telegram.

El servicio `postgres` monta `./db/schema.sql` en
`/docker-entrypoint-initdb.d/`, así que si el volumen `postgres_data`
se crea desde cero, el schema se aplica automáticamente sin pasos
manuales. Esto **no** aplica si el volumen ya existe (ver siguiente
sección).

## 5. Aplicar `schema.sql` manualmente (solo si el volumen ya existía)

Si `postgres_data` ya tenía datos de una instalación previa (no es un
volumen recién creado), el init script de Postgres no se ejecuta.
Aplicar el schema a mano:

```bash
docker exec -i kronos_bot-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < db/schema.sql
```

Verificar que las 3 tablas quedaron creadas:

```bash
docker exec kronos_bot-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt"'
```

## 6. Wine + winetricks (para MT4)

MT4 es una aplicación de Windows; en Linux corre vía Wine. Ubuntu
Server trae en sus repos default una versión de Wine vieja (o
directamente no la trae, en una instalación mínima), así que hace
falta el repo oficial de WineHQ (https://wiki.winehq.org/Ubuntu) para
tener Wine 7+ — necesario para el modo `wow64` sin forzar
`WINEARCH=win32`.

El script `scripts/setup-mt4-ubuntu.sh` automatiza lo que se puede
automatizar:

```bash
bash scripts/setup-mt4-ubuntu.sh
```

Qué hace:

1. Agrega el repo oficial de WineHQ (clave GPG + `.sources` para tu
   codename de Ubuntu) e instala `winehq-stable` y `winetricks` vía
   `apt-get` (si no están ya instalados).
2. Instala `xvfb` (framebuffer virtual) — necesario en un server
   headless para poder inicializar Wine y correr partes no
   interactivas del instalador sin un display real.
3. Crea un **prefijo de Wine dedicado y aislado** en `~/.wine-mt4`
   (separado de tu `~/.wine` por defecto, para no mezclar MT4 con
   otras apps de Wine). No fuerza `WINEARCH=win32` — Wine 7+ usa un
   modo `wow64` combinado que corre apps de 32 bits (como MT4) sin
   necesidad de forzar la arquitectura; forzar `win32` en Wine
   moderno falla con "WINEARCH is set to 'win32' but this is not
   supported in wow64 mode". Si no hay `DISPLAY` exportado, usa
   `xvfb-run` automáticamente solo para este paso de inicialización.
4. Prepara `mt4-bridge/orders/{pending,results}/` en la raíz del
   repo: si MT4 todavía no corrió en esta máquina, deja carpetas
   reales con `.gitkeep`; si ya encuentra `Common/Files` en el
   prefijo de Wine, las reemplaza por symlinks hacia ahí (ver sección
   9 — idempotente, mismo mecanismo que en `docs/INSTALL_LINUX.md`).
5. Enlaza `mt4-bridge/ea/KronosBridgeEA.mq4` a `MQL4/Experts/` del
   terminal detectado, si ya existe (symlink, dirección inversa al
   punto anterior — ver sección 9).
6. Imprime los pasos manuales pendientes (siguiente sección).

## 7. Acceso gráfico en un server headless (Xvfb + VNC, o X11 forwarding)

El instalador de MT4, el login a la cuenta VT Markets y compilar el EA
en MetaEditor son pasos que **sí o sí** requieren ver una ventana —
Ubuntu Server no tiene sesión gráfica local. Dos formas de resolverlo:

**Opción A — Xvfb + VNC (recomendado para un server sin X local):**

```bash
sudo apt-get install -y x11vnc

Xvfb :1 -screen 0 1024x768x24 &
DISPLAY=:1 x11vnc -display :1 -nopw -forever &
```

Desde tu máquina local, abrir un túnel SSH y conectar un cliente VNC:

```bash
ssh -L 5900:localhost:5900 usuario@tu-server
# y en tu máquina local, apuntar un cliente VNC a localhost:5900
```

Con eso ves el display `:1` del server. Todos los comandos de `wine`
que necesiten interfaz gráfica van con `DISPLAY=:1` por delante (ver
paso 8).

**Opción B — X11 forwarding por SSH** (si tenés un cliente X11 en tu
máquina local, ej. otra Linux con escritorio, o un servidor X en
Windows/Mac):

```bash
ssh -X usuario@tu-server
# los comandos de wine en esa sesión ya heredan el DISPLAY reenviado
```

`xvfb-run` (sin VNC ni X forwarding) sirve solo para pasos totalmente
no interactivos (ej. `wineboot --init`, que ya lo hace el script
automáticamente) — **no** sirve para loguearte en MT4 ni para
MetaEditor, porque ahí necesitás ver e interactuar con la ventana de
verdad.

## 8. Instalar MT4 (instalador de VT Markets)

A diferencia de lo que se pensó originalmente, **VT Markets sí
distribuye su propio instalador** (`vtmarkets4setup.exe`, descargado
desde vtmarkets.com) — no es necesario usar el instalador genérico de
metatrader4.com.

1. Descargar `vtmarkets4setup.exe` desde el sitio de VT Markets. En un
   server headless, descargalo directo con `wget`/`curl` en el
   server, o copialo por `scp` desde tu máquina local.

2. **Exportar `WINEPREFIX`** para la sesión de terminal, y usar el
   `DISPLAY` de la Opción A o B del paso anterior:

   ```bash
   export WINEPREFIX=~/.wine-mt4
   DISPLAY=:1 wine ~/Descargas/vtmarkets4setup.exe
   ```

3. Seguir el instalador gráfico hasta el final (Next, Next, Finish) —
   viéndolo por VNC o por X11 forwarding.

4. Abrir MT4 (mismo `WINEPREFIX` y `DISPLAY`):

   ```bash
   DISPLAY=:1 wine "$WINEPREFIX/drive_c/Program Files (x86)/VT Markets MT4/terminal.exe"
   ```

5. Recién ahora, dentro de la plataforma ya instalada, conectarte al
   servidor específico de VT Markets: en MT4 ir a
   Archivo > Iniciar sesión en cuenta de trading (o la ventana de
   login que aparece al abrir por primera vez) e ingresar:
   - Número de cuenta
   - Contraseña
   - Servidor (el nombre exacto que te dio VT Markets, ej. algo como
     `VTMarkets-Live` o `VTMarkets-Demo`)

   Estas credenciales **nunca** se automatizan ni se guardan en ningún
   archivo del repo.

## 9. Symlinks de `mt4-bridge/` hacia `Common\Files\` de Wine

MQL4 no permite acceso a rutas de archivo arbitrarias — las funciones
nativas `FileOpen`/`FileWrite` están restringidas a la carpeta
`MQL4\Files\` del terminal (o, con la bandera `FILE_COMMON`, a
`Common\Files\`, compartida entre todos los terminales de un mismo
prefijo). Por eso `mt4-bridge/orders/pending/` y
`mt4-bridge/orders/results/` del repo son, en cada máquina con MT4
instalado, **symlinks locales** hacia esa carpeta real de Wine. Esto
es idéntico a la variante Arch — el prefijo de Wine funciona igual
independientemente de la distro.

**Este paso ya está automatizado por `scripts/setup-mt4-ubuntu.sh`**
(ya lo corriste en el paso 6) — no hace falta crear los symlinks a
mano. El script también enlaza `mt4-bridge/ea/KronosBridgeEA.mq4` a
`MQL4/Experts/` del terminal detectado (dirección inversa: acá el
repo es la fuente real, el symlink vive del lado de Wine), para que
el EA aparezca en el Navigator de MetaEditor sin copiarlo a mano —
ver sección 10. Es idempotente — correrlo varias veces no rompe nada;
si algo no se enlazó porque corriste el script antes de instalar MT4,
volvé a correrlo después de abrirlo por primera vez.

Si en algún momento necesitás hacerlo a mano igual, el equivalente
manual es (el ID de terminal es autogenerado, pero `Common/Files` es
fijo, no depende de ese ID):

```bash
COMMON_FILES=~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files

mkdir -p "$COMMON_FILES/orders/pending" "$COMMON_FILES/orders/results"

rm -rf mt4-bridge/orders/pending mt4-bridge/orders/results
ln -s "$COMMON_FILES/orders/pending" mt4-bridge/orders/pending
ln -s "$COMMON_FILES/orders/results" mt4-bridge/orders/results
```

**Importante — esto es local, no se commitea:**

- Esta ruta es específica de tu usuario y máquina. Reemplazar
  `mt4-bridge/orders/{pending,results}/` por symlinks hace que `git
  status` muestre los `.gitkeep` originales como "borrados" y los
  symlinks como "sin seguimiento" — es el estado esperado en una
  máquina con MT4 instalado, igual que pasa con `.env`.
- **Nunca** usar `git add -A` en este repo, y menos dentro de
  `mt4-bridge/`. Los `.gitkeep` siguen versionados en el repo porque
  son necesarios para que un clone nuevo (sin Wine configurado
  todavía) tenga las carpetas `pending/`/`results/` como directorios
  reales vacíos, no rotos.

## 10. Verificar el puente de archivos

Con los symlinks en su lugar, un archivo escrito desde el lado del
repo debe aparecer instantáneamente del lado de Wine:

```bash
echo '{"test": true}' > mt4-bridge/orders/pending/999.json
cat ~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/pending/999.json
rm mt4-bridge/orders/pending/999.json
```

Si el `cat` muestra el mismo contenido, el puente está listo para el
EA.

## 11. Compilar y activar el EA en MT4

`scripts/setup-mt4-ubuntu.sh` (paso 6) ya dejó `KronosBridgeEA.mq4`
enlazado en `MQL4/Experts/` (sección 9). Falta compilarlo y
activarlo — esto es gráfico, necesitás VNC o X11 forwarding (sección
7) para verlo:

1. **Compilar.** Con MT4 abierto (viendo la ventana por VNC/X11):
   `Ver → Navigator` (o `Ctrl+N`) → carpeta `Expert Advisors` → click
   derecho en `KronosBridgeEA` → `Modify` (abre MetaEditor), o `F4`
   desde MT4. Con el archivo abierto, `F7`. Debería dar `0 errors`
   (warnings menores tipo "description is too long" son normales).
2. **Arrastrar al gráfico** del instrumento que quieras (ej. XAUUSD)
   desde el Navigator.
3. **Pestaña Common → tildar "Allow live trading".**
4. **Pestaña Inputs → `InpSymbolSuffix`**: `"-VIP"` en cuenta demo,
   `"-STD"` en cuenta real (VT Markets usa un sufijo distinto según
   el tipo de cuenta).
5. **Botón global "AutoTrading"** de la barra de herramientas de MT4
   en verde — interruptor aparte del punto 3, sin él ningún EA
   ejecuta nada.
6. **Verificar:** carita 🙂 verde junto al nombre del EA, y en la
   pestaña **Experts** el log `Kronos EA: iniciado...`.

**Si recompilás (`F7`) con el EA ya corriendo en un gráfico**, la
instancia en memoria sigue con el código viejo — sacarlo
(`Expert Advisors → Remove`) y volver a arrastrarlo. Cambiar el
*valor* de `InpSymbolSuffix` desde Properties no requiere recompilar
ni recargar.

## 12. Puente n8n → MT4 (escritura de órdenes)

n8n corre en Docker y no tiene acceso al filesystem del host donde
vive `mt4-bridge/orders/` (los symlinks de la sección 9 apuntan a
Wine, fuera del contenedor). Hace falta un bind mount, ya configurado
en `docker-compose.yml`, que depende de una variable de tu `.env`:

1. **Completar `MT4_ORDERS_HOST_PATH`** con la ruta real de
   `Common/Files/orders` en tu prefijo de Wine:

   ```dotenv
   MT4_ORDERS_HOST_PATH=/home/<tu-usuario>/.wine-mt4/drive_c/users/<tu-usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders
   ```

2. **Recrear el contenedor de n8n:**

   ```bash
   docker compose up -d n8n
   ```

3. **Verificar** escribiendo un archivo de prueba desde dentro del
   contenedor:

   ```bash
   docker exec kronos_bot-n8n-1 sh -c 'echo test > /mt4-bridge/orders/pending/test.json'
   cat ~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/pending/test.json
   docker exec kronos_bot-n8n-1 sh -c 'rm /mt4-bridge/orders/pending/test.json'
   ```

`docker-compose.yml` también define `N8N_RESTRICT_FILE_ACCESS_TO`
para `n8n` (no requiere acción tuya en `.env`) — n8n restringe por
defecto el acceso a filesystem de los nodos "Read/Write File" a
`~/.n8n-files`; sin esa variable, el nodo que escribe las órdenes
falla con `"The file ... is not writable"` aunque los permisos Unix
estén bien. Ver sección 13 si te aparece ese error.

## 13. Troubleshooting

Mismos síntomas y causas que `docs/INSTALL_LINUX.md` (sección 12) —
no se repiten acá para no duplicar mantenimiento. Diferencia real en
un server headless: si el EA no reacciona a nada y no es ninguno de
los problemas de esa sección, confirmar primero que la sesión VNC/X11
sigue activa y que estás viendo la ventana correcta de MT4 — es fácil
perder de vista una sesión Xvfb que murió sin avisar.

## 14. Mantener el acceso gráfico disponible entre sesiones

Un server headless no deja una sesión gráfica corriendo sola por
defecto. Si vas a necesitar volver a entrar a MT4 (relogueo, cambios
de configuración, recompilar el EA), conviene dejar Xvfb + x11vnc
corriendo como proceso persistente (ej. un servicio de `systemd` de
usuario, o `screen`/`tmux`) en vez de relanzarlo a mano cada vez. No
es parte de este MVP automatizarlo — se documenta acá para no
tener que redescubrirlo la próxima vez.

---

*Este documento se actualiza junto con cada etapa nueva del proyecto.*
