# Instalación en Windows

Guía para replicar el entorno de Kronos Bot en Windows nativo (pensada
para cuando se migre a un VPS Windows, o para cualquiera que use el
proyecto fuera de Linux). Documento **vivo**: se actualiza junto con
cada etapa nueva del proyecto. Estado actual: cubre hasta la Etapa 2
del lado Linux (Docker, n8n, Postgres, Telethon, MT4) — el equivalente
en Windows no se ha ejecutado todavía en la práctica, así que estos
pasos están documentados pero **no verificados end-to-end** como sí
lo está `docs/INSTALL_LINUX.md`. Los pasos de compilar/activar el EA
(sección 10) y el puente n8n → MT4 (sección 11) sí están escritos acá,
trasladados 1:1 de lo verificado en Linux (la UI de MetaEditor/MT4 y
los nodos de n8n son idénticos en ambas plataformas) — pero **la parte
de enlazar el `.mq4` automáticamente a `MQL4\Experts\` NO está
automatizada en Windows** (`scripts/setup-mt4.ps1` no lo hace, a
diferencia de `setup-mt4.sh` en Linux) — hay que copiarlo/enlazarlo a
mano, ver sección 8.

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

# Puente n8n -> MT4 (ver sección 11 — se completa DESPUÉS de instalar
# MT4, no antes)
MT4_ORDERS_HOST_PATH=
```

- `N8N_API_KEY` se genera desde la UI de n8n (Settings → n8n API →
  Create an API Key) después del primer arranque.
- `MT4_ORDERS_HOST_PATH` se completa en la sección 11.

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

### Enlazar el EA a `MQL4\Experts\` (manual en Windows)

A diferencia de Linux (donde `setup-mt4.sh` lo hace solo), acá hay que
enlazar `mt4-bridge\ea\KronosBridgeEA.mq4` a mano — mismo mecanismo
`mklink`, dirección inversa a los symlinks de arriba (acá el repo es
la fuente real, el symlink vive del lado de MT4):

```powershell
$TerminalId = (Get-ChildItem -Path "$env:APPDATA\MetaQuotes\Terminal" -Directory | Where-Object { $_.Name -ne "Common" }).Name
$ExpertsDir = "$env:APPDATA\MetaQuotes\Terminal\$TerminalId\MQL4\Experts"
$RepoEa = (Resolve-Path .\mt4-bridge\ea\KronosBridgeEA.mq4).Path

cmd /c mklink "$ExpertsDir\KronosBridgeEA.mq4" "$RepoEa"
```

Requiere PowerShell como Administrador. Repetir solo si el symlink se
rompe (ej. se reinstaló MT4 con un ID de terminal nuevo) — editar el
`.mq4` del repo no requiere rehacer este paso, solo recompilar (ver
sección 10).

## 9. Verificar el puente de archivos

```powershell
'{"test": true}' | Out-File -Encoding utf8 mt4-bridge\orders\pending\999.json
Get-Content "$env:APPDATA\MetaQuotes\Terminal\Common\Files\orders\pending\999.json"
Remove-Item mt4-bridge\orders\pending\999.json
```

Si el contenido coincide, el puente está listo para el EA.

## 10. Compilar y activar el EA en MT4

Mismos pasos que en Linux (la UI de MetaEditor/MT4 es idéntica en
Windows nativo, no cambia nada por no usar Wine):

1. **Compilar.** `Ctrl+N` en MT4 → Navigator → `Expert Advisors` →
   click derecho en `KronosBridgeEA` → `Modify` (o `F4` para abrir
   MetaEditor directo). Con el archivo abierto, `F7`. Debería dar
   `0 errors` (warnings menores tipo "description is too long" son
   normales).
2. **Arrastrar al gráfico** del instrumento que quieras (ej. XAUUSD)
   desde el Navigator.
3. **Pestaña Common → tildar "Allow live trading".**
4. **Pestaña Inputs → `InpSymbolSuffix`**: `"-VIP"` en cuenta demo,
   `"-STD"` en cuenta real (VT Markets usa un sufijo distinto según
   el tipo de cuenta).
5. **Botón global "AutoTrading"** de la barra de herramientas de MT4
   en verde — es un interruptor aparte del punto 3, y sin él ningún
   EA ejecuta nada.
6. **Verificar:** carita 🙂 verde junto al nombre del EA en el
   gráfico, y en la pestaña **Experts** el log `Kronos EA: iniciado...`.

**Si recompilás (`F7`) con el EA ya corriendo en un gráfico**, la
instancia en memoria sigue con el código viejo — sacarlo
(`Expert Advisors → Remove`) y volver a arrastrarlo. Cambiar el
*valor* de `InpSymbolSuffix` desde Properties, en cambio, no requiere
recompilar ni recargar.

## 11. Puente n8n → MT4 (escritura de órdenes)

n8n corre en Docker (Docker Desktop o WSL2) y no tiene acceso directo
al filesystem de Windows donde vive `mt4-bridge/orders/`. Hace falta
un bind mount, ya configurado en `docker-compose.yml`, que depende de
una variable de tu `.env`:

1. **Completar `MT4_ORDERS_HOST_PATH`** con la ruta de
   `Common\Files\orders` (sección 8), en formato compatible con Docker
   Desktop (rutas de Windows tipo `C:\Users\...` funcionan directo en
   Docker Desktop; si corrés Docker dentro de WSL2, usar la ruta
   `/mnt/c/Users/...` equivalente):

   ```dotenv
   MT4_ORDERS_HOST_PATH=C:\Users\<usuario>\AppData\Roaming\MetaQuotes\Terminal\Common\Files\orders
   ```

2. **Recrear el contenedor de n8n:**

   ```powershell
   docker compose up -d n8n
   ```

3. **Verificar** igual que en Linux, adaptando la ruta de Windows:

   ```powershell
   docker exec kronos_bot-n8n-1 sh -c 'echo test > /mt4-bridge/orders/pending/test.json'
   Get-Content "$env:APPDATA\MetaQuotes\Terminal\Common\Files\orders\pending\test.json"
   docker exec kronos_bot-n8n-1 sh -c 'rm /mt4-bridge/orders/pending/test.json'
   ```

`docker-compose.yml` también define `N8N_RESTRICT_FILE_ACCESS_TO`
para `n8n` (no requiere acción tuya en `.env`) — n8n restringe por
defecto el acceso a filesystem de los nodos "Read/Write File" a
`~/.n8n-files`; sin esa variable, el nodo que escribe las órdenes
falla con `"The file ... is not writable"` aunque los permisos estén
bien. Ver sección 12 si te aparece ese error.

## 12. Troubleshooting

Mismos síntomas y causas que en Linux (ver `docs/INSTALL_LINUX.md`
sección 12) — no se repiten acá para no duplicar mantenimiento; el
único punto realmente distinto en Windows es que si algo de la
sección 8 (symlink del EA) o 11 (bind mount de n8n) falla, revisar
primero permisos de Administrador (PowerShell) y, si Docker corre
dentro de WSL2, que la ruta de `MT4_ORDERS_HOST_PATH` esté en formato
`/mnt/c/...` y no `C:\...`.

---

*Este documento se actualiza junto con cada etapa nueva del proyecto.
Los pasos de Docker/`.env`/Postgres/EA están alineados 1:1 con
`docs/INSTALL_LINUX.md`; solo difieren MT4 (nativo, sin Wine), la ruta
de `Common\Files\`, y que el symlink del EA a `MQL4\Experts\` es
manual acá (sección 8) en vez de automatizado por script.*
