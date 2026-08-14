# Instalación en Windows

Guía para replicar el entorno de Kronos Bot en Windows nativo (pensada
para cuando se migre a un VPS Windows, o para cualquiera que use el
proyecto fuera de Linux). Documento **vivo**: se actualiza junto con
cada etapa nueva del proyecto. Estado actual: cubre hasta la Etapa 2
del lado Linux (Docker, n8n, Postgres, Telethon, MT4) — el equivalente
en Windows no se ha ejecutado todavía en la práctica, así que estos
pasos están documentados pero **no verificados end-to-end** como sí
lo está `docs/INSTALL_LINUX.md`. El EA en MQL4 (Etapa 3) todavía no
está documentado acá.

## 1. Docker

Dos opciones, cualquiera sirve para correr `docker compose`:

- **Docker Desktop para Windows** — instalador gráfico desde
  docker.com. Requiere WSL2 como backend (Docker Desktop lo pide y
  ayuda a instalarlo si falta).
- **WSL2 + Docker Engine dentro de la distro Linux del WSL** — si se
  prefiere evitar Docker Desktop, se puede instalar Docker Engine
  directamente dentro de una distro WSL2 (ej. Ubuntu), siguiendo la
  guía de esa distro Linux (misma lógica que `INSTALL_LINUX.md` pero
  dentro del WSL).

Cualquiera de las dos vías termina en el mismo resultado: `docker` y
`docker compose` disponibles en una terminal (PowerShell, si se usa
Docker Desktop; o la shell de la distro WSL2).

## 2. Clonar el repo

```powershell
git clone <url-del-repo> Kronos_Bot
cd Kronos_Bot
```

## 3. Variables de entorno (`.env`)

Igual que en Linux — crear `.env` en la raíz del repo (nunca se
commitea). Misma plantilla:

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

- `N8N_API_KEY` se genera desde la UI de n8n (Settings → n8n API →
  Create an API Key) después del primer arranque.

## 4. Levantar el stack de Docker

```powershell
docker compose up -d
```

Mismos 4 servicios que en Linux (`n8n`, `ngrok`, `postgres`,
`telethon`) — el `docker-compose.yml` es el mismo archivo, no hay
variante para Windows. `postgres` monta `./db/schema.sql` en
`/docker-entrypoint-initdb.d/` y lo aplica automáticamente si el
volumen `postgres_data` se crea desde cero.

## 5. Aplicar `schema.sql` manualmente (solo si el volumen ya existía)

```powershell
docker exec -i kronos_bot-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < db/schema.sql
```

Verificar:

```powershell
docker exec kronos_bot-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt"'
```

## 6. MT4 nativo (sin Wine)

En Windows, MT4 corre nativo — no hace falta Wine ni ningún prefijo
dedicado. El script `scripts/setup-mt4.ps1` automatiza la parte que
se puede automatizar:

```powershell
.\scripts\setup-mt4.ps1
```

Qué hace:

1. Crea la estructura `mt4-bridge\orders\{pending,results}\` en la
   raíz del repo (con `.gitkeep`).
2. Imprime los pasos manuales pendientes (siguiente sección).

No instala paquetes ni requiere permisos elevados — a diferencia del
script de Linux, no hay nada equivalente a `wine`/`winetricks` que
instalar.

## 7. Instalar MT4 (instalador de VT Markets)

1. Descargar `vtmarkets4setup.exe` desde el sitio de VT Markets.
2. Correr el instalador normalmente (doble clic), como cualquier
   programa de Windows — sin comandos especiales.
3. Seguir el instalador gráfico hasta el final.
4. Abrir MT4 (acceso directo en el escritorio o menú de inicio).
5. Loguearse con las credenciales reales de la cuenta VT Markets
   (número de cuenta, contraseña, servidor). Nunca se automatizan ni
   se guardan en el repo.

## 8. Diferencias de ruta: `Common\Files\` en Windows nativo vs Wine

En Linux con Wine, la carpeta `Common\Files\` vive dentro del prefijo
de Wine (`~/.wine-mt4/drive_c/users/<usuario>/AppData/Roaming/...`).
En Windows nativo, esa misma carpeta usada por MT4 es simplemente la
ruta estándar de `AppData` del usuario de Windows — no hay capa de
prefijo/emulación de por medio:

```
%APPDATA%\MetaQuotes\Terminal\Common\Files\
```

Que normalmente se resuelve a:

```
C:\Users\<usuario>\AppData\Roaming\MetaQuotes\Terminal\Common\Files\
```

Ubicarla (PowerShell):

```powershell
Get-ChildItem -Path "$env:APPDATA\MetaQuotes\Terminal" -Directory
```

La carpeta `Common` dentro de esa lista (junto a la carpeta con el ID
autogenerado del terminal específico) es la que se usa — igual que en
Linux, `Common\Files\` es fija y no depende del ID del terminal.

### Symlinks (mklink) en vez de symlinks de Unix

El mismo problema de la Etapa 2 en Linux aplica acá: MQL4 con
`FILE_COMMON` solo puede leer/escribir dentro de `Common\Files\`, no
en rutas arbitrarias como `mt4-bridge\` del repo. La solución
equivalente en Windows es un symlink de directorio con `mklink`
(requiere PowerShell/cmd como Administrador):

```powershell
Remove-Item -Recurse -Force mt4-bridge\orders\pending, mt4-bridge\orders\results

$CommonFiles = "$env:APPDATA\MetaQuotes\Terminal\Common\Files"
New-Item -ItemType Directory -Force -Path "$CommonFiles\orders\pending", "$CommonFiles\orders\results" | Out-Null

cmd /c mklink /D mt4-bridge\orders\pending "$CommonFiles\orders\pending"
cmd /c mklink /D mt4-bridge\orders\results "$CommonFiles\orders\results"
```

**Importante — igual que en Linux, esto es local y no se commitea.**
La ruta depende del usuario de Windows específico. Nunca hacer `git
add -A` en este repo — los `.gitkeep` de `mt4-bridge/orders/` quedan
versionados para que un clone nuevo (sin este paso hecho todavía)
tenga las carpetas como directorios reales vacíos.

## 9. Verificar el puente de archivos

```powershell
'{"test": true}' | Out-File -Encoding utf8 mt4-bridge\orders\pending\999.json
Get-Content "$env:APPDATA\MetaQuotes\Terminal\Common\Files\orders\pending\999.json"
Remove-Item mt4-bridge\orders\pending\999.json
```

Si el contenido coincide, el puente está listo para el EA (Etapa 3,
todavía pendiente de documentar acá).

---

*Este documento se actualiza junto con cada etapa nueva del proyecto.
Los pasos de Docker/`.env`/Postgres están alineados 1:1 con
`docs/INSTALL_LINUX.md`; solo difieren MT4 (nativo, sin Wine) y la
ruta de `Common\Files\`.*
