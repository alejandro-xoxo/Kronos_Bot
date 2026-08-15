#!/usr/bin/env bash
# Kronos Bot — Fase 6: preparación del entorno MT4 en Ubuntu Server
# (apt-based, sin entorno gráfico de escritorio asumido — headless),
# vía Wine.
#
# Para distros Arch-based (Arch, CachyOS, Manjaro, EndeavourOS, etc.),
# usar scripts/setup-mt4.sh en su lugar. Para Windows, usar
# scripts/setup-mt4.ps1 — ahí MT4 corre nativo, sin Wine.
#
# Automatiza lo que se puede automatizar (repo de WineHQ, paquetes,
# prefijo de Wine aislado, carpeta de comunicación con n8n). La
# instalación de MT4 en sí y el login a la cuenta VT Markets quedan
# como pasos manuales (requieren interacción gráfica con el
# instalador de MT4) — en un server headless, esa parte gráfica
# necesita Xvfb + acceso VNC/RDP, o X11 forwarding por SSH, al menos
# una vez (ver mensajes finales de este script).
#
# Requiere apt-get (Ubuntu/Debian y derivados). Ubuntu trae una
# versión de Wine desactivada/vieja en los repos default — este
# script agrega el repositorio oficial de WineHQ
# (https://wiki.winehq.org/Ubuntu) para instalar una versión moderna
# (Wine 7+), necesaria para el modo wow64 sin forzar WINEARCH=win32.

set -euo pipefail

WINE_PREFIX_MT4="${HOME}/.wine-mt4"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MT4_BRIDGE_DIR="${REPO_ROOT}/mt4-bridge"

echo "== Kronos Bot — Setup MT4 (Fase 6, Ubuntu Server) =="
echo

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: este script requiere apt-get (distro basada en Ubuntu/Debian)." >&2
    echo "Para Arch y derivados, usa scripts/setup-mt4.sh en su lugar." >&2
    echo "Para Windows, usa scripts/setup-mt4.ps1 en su lugar." >&2
    exit 1
fi

# 1. Agregar el repo oficial de WineHQ e instalar wine + winetricks
echo "-- Paso 1/5: agregando repo de WineHQ e instalando wine y winetricks --"
if ! command -v wine >/dev/null 2>&1 || ! command -v winetricks >/dev/null 2>&1; then
    # El wine de los repos default de Ubuntu suele ser viejo (o no
    # existir en Ubuntu Server mínimo). Seguimos la guía oficial de
    # WineHQ para Ubuntu: https://wiki.winehq.org/Ubuntu
    sudo dpkg --add-architecture i386
    sudo mkdir -pm755 /etc/apt/keyrings
    sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key

    UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    sudo wget -NP /etc/apt/sources.list.d/ \
        "https://dl.winehq.org/wine-builds/ubuntu/dists/${UBUNTU_CODENAME}/winehq-${UBUNTU_CODENAME}.sources"

    sudo apt-get update
    sudo apt-get install --install-recommends -y winehq-stable winetricks
else
    echo "wine y winetricks ya están instalados, se omite."
fi
echo

# 2. Xvfb (framebuffer virtual) — sugerido para la parte no interactiva
#    en un server headless (correr el instalador de MT4 sin monitor real)
echo "-- Paso 2/5: instalando xvfb (framebuffer virtual, opcional/sugerido) --"
if ! command -v xvfb-run >/dev/null 2>&1; then
    sudo apt-get install -y xvfb
else
    echo "xvfb ya está instalado, se omite."
fi
echo

# 3. Crear prefijo de Wine dedicado, aislado del prefijo por defecto (~/.wine)
echo "-- Paso 3/5: creando prefijo de Wine dedicado en ${WINE_PREFIX_MT4} --"
if [ -d "${WINE_PREFIX_MT4}" ]; then
    echo "El prefijo ${WINE_PREFIX_MT4} ya existe, se omite la creación."
else
    # Igual que en setup-mt4.sh (Arch): NO forzar WINEARCH=win32. Wine 7+
    # ya no soporta forzarlo en modo wow64 (arquitectura combinada 32/64
    # bits por defecto desde Wine 7). El prefijo por defecto corre MT4
    # (32 bits) sin necesidad de forzar la arquitectura.
    #
    # En un server headless sin X real todavía disponible, wineboot
    # puede fallar si no hay ningún display. Si no hay DISPLAY exportado
    # y xvfb-run está disponible, usamos un framebuffer virtual efímero
    # solo para esta inicialización (no interactiva).
    if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
        WINEPREFIX="${WINE_PREFIX_MT4}" xvfb-run -a wineboot --init
    else
        WINEPREFIX="${WINE_PREFIX_MT4}" wineboot --init
    fi
    echo "Prefijo creado en ${WINE_PREFIX_MT4} (wow64 por defecto — WINEARCH=win32 ya no es válido en Wine 7+)."
fi
echo

# 4. Crear carpeta mt4-bridge/ en la raíz del repo
echo "-- Paso 4/5: creando estructura de mt4-bridge/ --"
mkdir -p "${MT4_BRIDGE_DIR}/orders/pending"
mkdir -p "${MT4_BRIDGE_DIR}/orders/results"
if [ ! -f "${MT4_BRIDGE_DIR}/.gitkeep" ]; then
    touch "${MT4_BRIDGE_DIR}/orders/pending/.gitkeep"
    touch "${MT4_BRIDGE_DIR}/orders/results/.gitkeep"
fi
echo "Carpeta lista en ${MT4_BRIDGE_DIR} (orders/pending, orders/results)."
echo

# 5. Instrucciones manuales
echo "-- Paso 5/5: pasos MANUALES pendientes --"
cat <<EOF

Lo automatizable ya quedó listo. Faltan estos pasos manuales:

1. Descargar el instalador GENÉRICO de MetaTrader 4 desde el sitio
   oficial: https://www.metatrader4.com/es/download
   (NO existe un instalador separado de VT Markets — es el mismo
   software genérico para cualquier bróker; la conexión a VT Markets
   se hace después, desde dentro de la plataforma ya instalada).
   Guárdalo en cualquier carpeta temporal, ej. ~/Descargas
   (normalmente algo como "mt4setup.exe").

   En un server headless, descargalo con wget/curl directo en el
   server, o copialo por scp desde tu máquina local.

2. Correr el instalador usando el prefijo de Wine dedicado (NO el
   prefijo por defecto), para no mezclarlo con otras apps de Wine.

   Esta parte ES gráfica (el instalador de MT4 no tiene modo
   silencioso confiable), así que en un server headless necesitás
   UNA de estas opciones para verla:

   a) Xvfb + VNC (recomendado para no depender de que quede una
      sesión SSH con X forwarding abierta): levantar un framebuffer
      virtual con un display fijo y exponerlo por VNC con x11vnc
      (instalar aparte: "sudo apt-get install x11vnc"), y desde tu
      máquina local conectarte con un cliente VNC por túnel SSH:

        Xvfb :1 -screen 0 1024x768x24 &
        x11vnc -display :1 -nopw -forever &
        # en tu máquina local: ssh -L 5900:localhost:5900 usuario@server
        # y ahí conectar un cliente VNC a localhost:5900
        DISPLAY=:1 WINEPREFIX="${WINE_PREFIX_MT4}" wine ~/Descargas/mt4setup.exe

   b) X11 forwarding por SSH (más simple si tenés X11 corriendo en tu
      máquina local, ej. otra Linux con escritorio):

        ssh -X usuario@server
        WINEPREFIX="${WINE_PREFIX_MT4}" wine ~/Descargas/mt4setup.exe

   c) xvfb-run para pasos que NO requieren ver nada (ej. dejar que el
      instalador corra con sus defaults sin intervención) — no sirve
      para loguearte en MT4 ni compilar el EA en MetaEditor, ambos
      necesitan ver la ventana de verdad:

        WINEPREFIX="${WINE_PREFIX_MT4}" xvfb-run -a wine ~/Descargas/mt4setup.exe

3. Seguir el instalador gráfico hasta el final (Next, Next, Finish).
   MT4 debería quedar instalado dentro de:

     ${WINE_PREFIX_MT4}/drive_c/Program Files (x86)/MetaTrader 4/

4. Abrir MT4 con ese mismo prefijo (de nuevo, necesitás VNC o X11
   forwarding real acá, no xvfb-run solo):

     WINEPREFIX="${WINE_PREFIX_MT4}" wine "${WINE_PREFIX_MT4}/drive_c/Program Files (x86)/MetaTrader 4/terminal.exe"

5. Recién AHORA, dentro de la plataforma ya instalada, conectarte al
   servidor específico de VT Markets: en MT4 ir a
   Archivo > Iniciar sesión en cuenta de trading (o la ventana de
   login que aparece al abrir por primera vez) e ingresar:
     - Número de cuenta
     - Contraseña
     - Servidor (el nombre exacto que te dio VT Markets, ej. algo
       como "VTMarkets-Live" o "VTMarkets-Demo" — puede requerir
       buscarlo en la lista de servidores si no aparece por defecto)
   Estas credenciales NO se automatizan ni se guardan en ningún
   archivo del repo, se ingresan a mano en la ventana de login.

6. Compilar el EA puente (mt4-bridge/ea/KronosBridgeEA.mq4) con
   MetaEditor (F7 dentro de MT4) — también requiere acceso gráfico
   real, mismo mecanismo (VNC o X11 forwarding) que los pasos 2 y 4.

Una vez logueado y viendo precios en tiempo real en el terminal,
y con el EA compilado, seguí con docs/INSTALL_UBUNTU_SERVER.md
(sección de symlinks a Common/Files) para conectar mt4-bridge/ con
la carpeta real de Wine.

EOF

echo "== Setup automatizado completado =="
