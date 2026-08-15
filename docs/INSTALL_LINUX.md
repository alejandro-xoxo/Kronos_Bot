# Instalación en Linux (distros basadas en Arch)

Guía para replicar el entorno completo de Kronos Bot desde un sistema
operativo recién instalado (Arch, CachyOS, Manjaro, EndeavourOS, etc.).
Este documento es **vivo**: se actualiza a medida que avanzan las
etapas del proyecto, no solo al final. Estado actual: cubre hasta la
Etapa 2 (Docker, n8n, Postgres, Telethon, Wine, MT4 instalado y
logueado). El EA en MQL4 (Etapa 3) todavía no está documentado acá.

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
```

- `N8N_API_KEY` se genera desde la propia UI de n8n (Settings → n8n
  API → Create an API Key) **después** del primer arranque — se
  agrega a `.env` en un segundo paso, no antes.
- `TELEGRAM_GROUP_ID` y `TELEGRAM_USER_CHAT_ID` se obtienen inspeccionando
  los IDs reales de Telegram (grupo de señales y tu chat privado con
  el bot, respectivamente).

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
EA (Etapa 3, todavía pendiente de documentar acá).

---

*Este documento se actualiza junto con cada etapa nueva del proyecto.
La próxima actualización debería cubrir la instalación del EA en
`MQL4/Experts/` (Etapa 3).*
