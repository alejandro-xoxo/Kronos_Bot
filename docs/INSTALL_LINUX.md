# Instalación en Linux (distros basadas en Arch)

Guía para replicar el entorno completo de Kronos Bot desde un sistema
operativo recién instalado (Arch, CachyOS, Manjaro, EndeavourOS, etc.).
Este documento es **vivo**: se actualiza a medida que avanzan las
etapas del proyecto, no solo al final. Estado actual: cubre Docker,
n8n, Postgres, Telethon, Wine, MT4 instalado y logueado, compilación
y activación del EA, y el puente n8n → MT4 (escritura de órdenes).

## 1. Docker y Docker Compose

```bash
sudo pacman -S --needed docker docker-compose
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
git clone https://github.com/alejandro-xoxo/Kronos_Bot.git
cd Kronos_Bot
```

## 3. Variables de entorno (`.env`)

Crear `.env` en la raíz del repo (nunca se commitea — está en
`.gitignore`). Plantilla de las claves necesarias, **sin valores
reales**:

```dotenv
# n8n
N8N_HOST=
DASHBOARD_USER=
DASHBOARD_PASSWORD=
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

# Puente n8n -> MT4 (ver sección 11 — se agrega DESPUÉS de instalar
# MT4 y correr scripts/setup-mt4.sh, no antes; sin Wine todavía no
# existe la ruta real que va acá)
MT4_ORDERS_HOST_PATH=
```

- `N8N_API_KEY` se genera desde la propia UI de n8n (Settings → n8n
  API → Create an API Key) **después** del primer arranque — se
  agrega a `.env` en un segundo paso, no antes.
- `TELEGRAM_GROUP_ID`: la forma soportada de obtenerlo es correr
  `telethon-service/list_groups.py` (necesita `TELEGRAM_API_ID`/
  `TELEGRAM_API_HASH`/`TELEGRAM_PHONE` ya completos en `.env`) — lista
  todos los chats/grupos/canales visibles para tu cuenta con su ID:
  ```bash
  cd telethon-service
  pip install -r requirements.txt   # o un venv, si preferís no instalar global
  python list_groups.py
  cd ..
  ```
  Copiar el ID del grupo de señales tal cual lo imprime (incluido el
  signo negativo si lo tiene).
- `TELEGRAM_USER_CHAT_ID`: tu propio `chat_id` privado, no el del
  grupo — es donde te van a llegar las notificaciones y los botones de
  Confirmar/Rechazar. Se obtiene fácil hablándole a `@userinfobot` en
  Telegram (te devuelve tu ID al toque), o revisando el `chat.id` de
  cualquier update que le mandes a tu propio bot una vez creado (ver
  sección 5).
- `MT4_ORDERS_HOST_PATH` se completa en la sección 11, no ahora —
  depende de una ruta que solo existe después de instalar Wine/MT4.

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

MT4 es una aplicación de Windows; en Linux corre vía Wine. El script
`scripts/setup-mt4.sh` automatiza lo que se puede automatizar:

```bash
bash scripts/setup-mt4.sh
```

Qué hace:

1. Instala `wine` y `winetricks` vía `pacman` (si no están ya
   instalados).
2. Crea un **prefijo de Wine dedicado y aislado** en `~/.wine-mt4`
   (separado de tu `~/.wine` por defecto, para no mezclar MT4 con
   otras apps de Wine). No fuerza `WINEARCH=win32` — Wine 7+ usa un
   modo `wow64` combinado que corre apps de 32 bits (como MT4) sin
   necesidad de forzar la arquitectura; forzar `win32` en Wine
   moderno falla con "WINEARCH is set to 'win32' but this is not
   supported in wow64 mode".
3. Prepara `mt4-bridge/orders/{pending,results}/` en la raíz del
   repo: si MT4 todavía no corrió en esta máquina, deja carpetas
   reales con `.gitkeep` (para que git las trackee vacías); si ya
   encuentra `Common/Files` en el prefijo de Wine, las reemplaza por
   symlinks hacia ahí (ver sección 8 — es lo mismo que antes había
   que hacer a mano, ahora está automatizado y es idempotente).
4. Imprime los pasos manuales pendientes (siguiente sección).

## 7. Instalar MT4 (instalador de VT Markets)

A diferencia de lo que se pensó originalmente, **VT Markets sí
distribuye su propio instalador** (`vtmarkets4setup.exe`, descargado
desde vtmarkets.com) — no es necesario usar el instalador genérico de
metatrader4.com.

1. Descargar `vtmarkets4setup.exe` desde el sitio de VT Markets,
   guardarlo en `~/Descargas` (o cualquier carpeta temporal).

2. **Exportar `WINEPREFIX` para toda la sesión de la terminal** antes
   de correr el instalador. La sintaxis depende de tu shell:

   **fish** (shell por defecto en este proyecto):
   ```fish
   set -gx WINEPREFIX ~/.wine-mt4
   wine ~/Descargas/vtmarkets4setup.exe
   ```

   **bash/zsh:**
   ```bash
   export WINEPREFIX=~/.wine-mt4
   wine ~/Descargas/vtmarkets4setup.exe
   ```

   Usar `WINEPREFIX="~/.wine-mt4" wine ...` como prefijo de un solo
   comando (sin exportar) también funciona para ese comando puntual,
   pero exportarlo evita tener que repetirlo cada vez que abras MT4
   en la misma sesión de terminal.

3. Seguir el instalador gráfico hasta el final (Next, Next, Finish).

4. Abrir MT4 (mismo `WINEPREFIX` ya exportado, o repetirlo si es una
   terminal nueva):
   ```fish
   wine "$WINEPREFIX/drive_c/Program Files (x86)/VT Markets MT4/terminal.exe"
   ```

5. Loguearse con las credenciales reales de la cuenta VT Markets
   (número de cuenta, contraseña, servidor — ej. `VTMarkets-Live 9`).
   Estas credenciales **nunca** se automatizan ni se guardan en
   ningún archivo del repo.

## 8. Symlinks de `mt4-bridge/` hacia `Common\Files\` de Wine

MQL4 no permite acceso a rutas de archivo arbitrarias — las funciones
nativas `FileOpen`/`FileWrite` están restringidas a la carpeta
`MQL4\Files\` del terminal (o, con la bandera `FILE_COMMON`, a
`Common\Files\`, compartida entre todos los terminales de un mismo
prefijo). Por eso `mt4-bridge/orders/pending/` y
`mt4-bridge/orders/results/` del repo son, en cada máquina con MT4
instalado, **symlinks locales** hacia esa carpeta real de Wine.

**Este paso ahora está automatizado por `scripts/setup-mt4.sh`** (ya
lo corriste en el paso 6) — no hace falta crear los symlinks a mano.
Cada vez que corrés el script, la función `setup_bridge_dirs`:

1. Busca `MetaQuotes/Terminal/Common` dentro del prefijo de Wine (el
   ID de terminal es autogenerado, pero esa ruta es fija).
2. Si la encuentra, crea `Common/Files/orders/{pending,results}` y
   reemplaza `mt4-bridge/orders/{pending,results}` del repo por
   symlinks hacia ahí — sea que esas carpetas fueran directorios
   reales (clone nuevo con `.gitkeep`) o symlinks rotos/desactualizados
   de una corrida anterior (prefijo recreado, etc.).
3. Si todavía no existe (prefijo recién creado o MT4 nunca corrió en
   esta máquina), no falla: avisa que los symlinks se crearán en una
   corrida posterior, después de instalar y abrir MT4 al menos una vez
   (ver paso 7).

Es idempotente — correrlo varias veces no rompe nada ni tira error de
"ya existe"; si el symlink ya apunta al lugar correcto, lo deja como
está.

**El mismo script también enlaza el EA.** Si ya instalaste y abriste
MT4 al menos una vez (paso 7), `scripts/setup-mt4.sh` detecta la
carpeta `MQL4/Experts/` de ese terminal y crea ahí un symlink
`KronosBridgeEA.mq4` apuntando a `mt4-bridge/ea/KronosBridgeEA.mq4`
del repo — dirección inversa a los symlinks de `orders/` de arriba
(acá el repo es la fuente real, versionada en git; el symlink vive
del lado de Wine). Esto es lo que hace que el EA aparezca en el
Navigator de MetaEditor sin copiarlo a mano — ver sección 10. Si
corriste el script ANTES de instalar MT4, volvé a correrlo después de
abrirlo por primera vez para que este symlink se cree.

Si en algún momento necesitás hacerlo a mano igual, el equivalente
manual es:

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

## 9. Verificar el puente de archivos

Con los symlinks en su lugar, un archivo escrito desde el lado del
repo debe aparecer instantáneamente del lado de Wine:

```bash
echo '{"test": true}' > mt4-bridge/orders/pending/999.json
cat ~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/pending/999.json
rm mt4-bridge/orders/pending/999.json
```

Si el `cat` muestra el mismo contenido, el puente está listo para el
EA.

## 10. Compilar y activar el EA en MT4

`scripts/setup-mt4.sh` (paso 6) ya dejó `KronosBridgeEA.mq4` enlazado
en `MQL4/Experts/` (ver sección 8). Falta compilarlo y activarlo
dentro de MT4 — esto sí es manual, requiere interfaz gráfica.

1. **Compilar.** Con MT4 abierto: `Ver → Navigator` (o `Ctrl+N`) →
   carpeta `Expert Advisors` → click derecho en `KronosBridgeEA` →
   `Modify` (abre MetaEditor), o directamente `F4` desde MT4 para
   abrir MetaEditor y ubicarlo ahí. Con el archivo abierto, `F7` para
   compilar. Debería dar `0 errors` (algunos warnings de MQL4 son
   normales y no bloquean, ej. "description is too long" o "possible
   loss of data due to type conversion" en conversiones numéricas
   estándar).
2. **Arrastrar al gráfico.** De vuelta en MT4, abrí el gráfico del
   instrumento que quieras (ej. XAUUSD) y arrastrá `KronosBridgeEA`
   desde el Navigator sobre el gráfico.
3. **Tildar "Allow live trading".** En la ventana que se abre al
   soltarlo, pestaña **Common**: tildar **"Allow live trading"** —
   sin esto el EA corre pero nunca puede enviar órdenes.
4. **Configurar `InpSymbolSuffix`.** Pestaña **Inputs**: el bróker
   (VT Markets) usa un sufijo distinto según el tipo de cuenta —
   `"-VIP"` en la cuenta demo, `"-STD"` en la cuenta real. Dejar el
   valor que corresponda a la cuenta con la que estás logueado ahora
   mismo (ver `scripts/setup-mt4.sh` o `PROTOCOLOS_KRONOS_BOT.md`
   para más contexto de por qué existe este mapeo). Click OK.
5. **Activar el AutoTrading global.** Además del punto 3 (que es por
   EA/gráfico), hay un interruptor separado en la barra de
   herramientas principal de MT4: el botón **"AutoTrading"**. Tiene
   que estar en verde/activado — si está apagado, **ningún** EA
   ejecuta nada, aunque tenga "Allow live trading" tildado.
6. **Verificar que está corriendo.** Arriba a la derecha del gráfico,
   junto al nombre `KronosBridgeEA`, debe verse una carita 🙂 en
   verde (roja/triste = algo de los pasos 3 o 5 falta). En la pestaña
   **Experts** (panel inferior de MT4) debería aparecer el log
   `Kronos EA: iniciado. Polling de orders\pending\*.json cada 2s
   (Common\Files).`

**Si editás el `.mq4` y recompilás** (`F7`) con el EA ya corriendo en
un gráfico, la instancia en memoria sigue ejecutando el código
**viejo** — MT4 no recarga sola un EA ya adjunto. Hay que sacarlo y
volver a ponerlo: click derecho sobre el gráfico → `Expert Advisors →
Remove`, y volver a arrastrar `KronosBridgeEA` desde el Navigator.
Repetir esto cada vez que se recompile, incluidos cambios de
`InpSymbolSuffix` en el código fuente (cambiar el *valor* del input
desde Properties, en cambio, no requiere recompilar ni recargar — ver
punto 4).

## 11. Puente n8n → MT4 (escritura de órdenes)

n8n corre en Docker y no tiene acceso al filesystem del host donde
vive `mt4-bridge/orders/` (los symlinks de la sección 8 apuntan a
Wine, fuera del contenedor). Para que el nodo de n8n que escribe
`orders/pending/{signal_id}.json` funcione, hace falta un bind mount
adicional, ya configurado en `docker-compose.yml` pero que depende de
una variable de tu `.env`:

1. **Completar `MT4_ORDERS_HOST_PATH` en `.env`** (la dejamos vacía en
   la sección 3) con la ruta real de `Common/Files/orders` en tu
   prefijo de Wine:

   ```dotenv
   MT4_ORDERS_HOST_PATH=/home/<tu-usuario>/.wine-mt4/drive_c/users/<tu-usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders
   ```

   Es la misma carpeta padre de `pending/` y `results/` que ya
   verificaste en la sección 9 — no la subcarpeta `pending` sola.

2. **Recrear el contenedor de n8n** para que tome el volumen nuevo:

   ```bash
   docker compose up -d n8n
   ```

3. **Verificar el mount** escribiendo un archivo de prueba desde
   dentro del contenedor y comprobando que aparece del lado de Wine:

   ```bash
   docker exec kronos_bot-n8n-1 sh -c 'echo test > /mt4-bridge/orders/pending/test.json'
   cat ~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/orders/pending/test.json
   docker exec kronos_bot-n8n-1 sh -c 'rm /mt4-bridge/orders/pending/test.json'
   ```

`docker-compose.yml` también define `N8N_RESTRICT_FILE_ACCESS_TO`
para el servicio `n8n` — esto **no** requiere ninguna acción tuya (no
sale de `.env`), pero es importante saber que existe: n8n restringe
por defecto el acceso a filesystem de los nodos "Read/Write File" a
`~/.n8n-files`, y sin esta variable el nodo que escribe las órdenes
falla con `"The file ... is not writable"` aunque los permisos Unix
del archivo estén perfectamente bien. Si alguna vez ves ese error
exacto en una ejecución de n8n, la causa casi segura es que el
contenedor se recreó desde una versión vieja de `docker-compose.yml`
sin esta variable — ver sección 12.

## 12. Troubleshooting

**El nodo de n8n "Escribir orden pending (MT4)" falla con `"is not
writable"`:** falta `N8N_RESTRICT_FILE_ACCESS_TO` en el servicio
`n8n` de `docker-compose.yml` (sección 11), o el contenedor no se
recreó después de agregarla — `docker compose up -d n8n` para
aplicarla.

**Confirmás una señal en Telegram pero no aparece nada en
`orders/pending/` del lado de Wine:** revisar en este orden:
1. ¿`MT4_ORDERS_HOST_PATH` está seteada en `.env` y el contenedor
   `n8n` se recreó después de setearla? (sección 11).
2. ¿La ejecución del workflow en n8n (pestaña *Executions* de la UI)
   marca error en el nodo `Escribir orden pending (MT4)`? Ahí sale el
   motivo exacto.
3. Si el archivo sí aparece en `orders/pending/` pero nunca
   desaparece: el EA no está corriendo o no tiene AutoTrading activo
   (ver siguiente punto) — el archivo debería borrarse solo en
   segundos (polling cada `InpPollIntervalSeconds`, default 2s).

**El EA no ejecuta ninguna orden (el archivo de `pending/` desaparece
pero no pasa nada, o `results/{id}.json` reporta error):**
1. Revisar `results/{signal_id}.json` — el EA siempre escribe un
   resultado, éxito o fallo, con `error_message` legible.
2. Si el error es `INSTRUMENT_NOT_SUPPORTED` o `SYMBOL_NOT_FOUND`: el
   instrumento de la señal no está en el mapeo del EA (solo
   XAUUSD/EURUSD hoy), o `InpSymbolSuffix` no coincide con el sufijo
   real del símbolo en Market Watch de esa cuenta — revisar sección
   10, punto 4.
3. Si no se escribe ningún `results/` en absoluto: revisar la pestaña
   **Experts** de MT4 (logs del EA) y confirmar "Allow live trading"
   + AutoTrading global (sección 10, puntos 3 y 5).
4. **Si acabás de recompilar el `.mq4` y sigue fallando con un error
   que ya habías arreglado en el código:** con altísima probabilidad
   el EA en el gráfico sigue corriendo la versión vieja en memoria —
   sacarlo del gráfico y volver a arrastrarlo (sección 10, nota al
   final). Este es el bug más fácil de confundir con un error de
   código real.

---

*Este documento se actualiza junto con cada etapa nueva del proyecto.*
