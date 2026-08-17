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
# prefijo de Wine aislado, symlinks de mt4-bridge/orders/ y del EA a
# MQL4/Experts/). La instalación de MT4 en sí y el login a la cuenta
# VT Markets quedan como pasos manuales (requieren interacción
# gráfica con el instalador de MT4) — en un server headless, esa
# parte gráfica necesita Xvfb + acceso VNC/RDP, o X11 forwarding por
# SSH, al menos una vez (ver mensajes finales de este script).
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

# Crea o repara el symlink mt4-bridge/orders/<name> -> <target>, de forma
# idempotente (ver scripts/setup-mt4.sh — misma lógica, sin duplicar
# comentarios acá).
link_bridge_dir() {
    local name="$1" target="$2"
    local link_path="${MT4_BRIDGE_DIR}/orders/${name}"

    if [ -L "${link_path}" ]; then
        if [ "$(readlink -- "${link_path}")" = "${target}" ]; then
            echo "  ${name}: symlink ya apunta a ${target}, se omite."
            return
        fi
        echo "  ${name}: symlink existente (roto o de un prefijo viejo) -> se recrea apuntando a ${target}"
        rm -f -- "${link_path}"
        ln -s -- "${target}" "${link_path}"
    elif [ -d "${link_path}" ]; then
        echo "  ${name}: reemplazando carpeta real por symlink hacia ${target}"
        rm -rf -- "${link_path}"
        ln -s -- "${target}" "${link_path}"
    elif [ -e "${link_path}" ]; then
        echo "ERROR: ${link_path} existe y no es ni carpeta ni symlink, revisar a mano." >&2
        exit 1
    else
        ln -s -- "${target}" "${link_path}"
    fi
}

# Decide entre carpetas reales (sin Wine/MT4 todavía) o symlinks hacia
# Common/Files del prefijo de Wine (MT4 ya corrió al menos una vez).
setup_bridge_dirs() {
    local metaquotes_common common_files

    mkdir -p "${MT4_BRIDGE_DIR}/orders"

    metaquotes_common="$(find "${WINE_PREFIX_MT4}/drive_c/users" -maxdepth 6 -type d -ipath '*/MetaQuotes/Terminal/Common' 2>/dev/null | head -n1 || true)"

    if [ -n "${metaquotes_common}" ]; then
        common_files="${metaquotes_common}/Files"
        echo "Prefijo de Wine con MT4 detectado. Common/Files en:"
        echo "  ${common_files}"
        mkdir -p "${common_files}/orders/pending" "${common_files}/orders/results"
        link_bridge_dir "pending" "${common_files}/orders/pending"
        link_bridge_dir "results" "${common_files}/orders/results"
    elif [ -L "${MT4_BRIDGE_DIR}/orders/pending" ] || [ -L "${MT4_BRIDGE_DIR}/orders/results" ]; then
        echo "AVISO: ya hay symlinks locales en mt4-bridge/orders/, pero todavía no se"
        echo "encuentra la carpeta MetaQuotes/Terminal/Common en ${WINE_PREFIX_MT4}."
        echo "Esto es normal si el prefijo de Wine se acaba de crear o si MT4 nunca"
        echo "corrió en esta máquina. No se tocan los symlinks existentes — volvé a"
        echo "correr este script después de instalar y abrir MT4 al menos una vez."
    else
        echo "MT4 todavía no está instalado en ${WINE_PREFIX_MT4} — se usan carpetas"
        echo "reales con .gitkeep (estado normal de un clone nuevo sin Wine configurado)."
        mkdir -p "${MT4_BRIDGE_DIR}/orders/pending" "${MT4_BRIDGE_DIR}/orders/results"
        [ -e "${MT4_BRIDGE_DIR}/orders/pending/.gitkeep" ] || touch "${MT4_BRIDGE_DIR}/orders/pending/.gitkeep"
        [ -e "${MT4_BRIDGE_DIR}/orders/results/.gitkeep" ] || touch "${MT4_BRIDGE_DIR}/orders/results/.gitkeep"
    fi
}

# Crea/repara un symlink en MQL4/Experts/ del terminal (NO Common,
# eso es exclusivo de MT4, no compartido) apuntando al .mq4 del repo.
# Dirección inversa a link_bridge_dir a propósito: acá el repo es la
# fuente real (versionada en git), así que el symlink vive del lado
# de Wine — evita tener que re-copiar el archivo cada vez que se edita
# el EA, solo hay que recompilar en MetaEditor (F7).
link_ea_to_experts() {
    local terminal_experts source_ea link_path

    source_ea="${MT4_BRIDGE_DIR}/ea/KronosBridgeEA.mq4"
    if [ ! -f "${source_ea}" ]; then
        echo "  AVISO: no se encontró ${source_ea}, se omite el symlink del EA."
        return
    fi

    terminal_experts="$(find "${WINE_PREFIX_MT4}/drive_c/users" -maxdepth 8 -type d -ipath '*/MetaQuotes/Terminal/*/MQL4/Experts' ! -ipath '*/Terminal/Common/*' 2>/dev/null | head -n1 || true)"

    if [ -z "${terminal_experts}" ]; then
        echo "  MT4 todavía no está instalado/corrido en esta máquina — no se encontró"
        echo "  MQL4/Experts. Se omite el symlink del EA (correr este script de nuevo"
        echo "  después de instalar y abrir MT4 al menos una vez)."
        return
    fi

    link_path="${terminal_experts}/KronosBridgeEA.mq4"

    if [ -L "${link_path}" ]; then
        if [ "$(readlink -- "${link_path}")" = "${source_ea}" ]; then
            echo "  KronosBridgeEA.mq4: symlink ya apunta al repo, se omite."
            return
        fi
        echo "  KronosBridgeEA.mq4: symlink existente apunta a otro lado -> se recrea."
        rm -f -- "${link_path}"
    elif [ -e "${link_path}" ]; then
        echo "  KronosBridgeEA.mq4: ya existe un archivo real (no symlink) en Experts/,"
        echo "  probablemente de una compilación manual previa -> se reemplaza por el symlink."
        rm -f -- "${link_path}"
    fi

    ln -s -- "${source_ea}" "${link_path}"
    echo "  KronosBridgeEA.mq4 enlazado en: ${terminal_experts}"
    echo "  (abrir MetaEditor y compilar con F7 — el .ex4 resultante queda del lado de Wine, no se versiona)"
}

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: este script requiere apt-get (distro basada en Ubuntu/Debian)." >&2
    echo "Para Arch y derivados, usa scripts/setup-mt4.sh en su lugar." >&2
    echo "Para Windows, usa scripts/setup-mt4.ps1 en su lugar." >&2
    exit 1
fi

# 1. Agregar el repo oficial de WineHQ e instalar wine + winetricks
echo "-- Paso 1/6: agregando repo de WineHQ e instalando wine y winetricks --"
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
echo "-- Paso 2/6: instalando xvfb (framebuffer virtual, opcional/sugerido) --"
if ! command -v xvfb-run >/dev/null 2>&1; then
    sudo apt-get install -y xvfb
else
    echo "xvfb ya está instalado, se omite."
fi
echo

# 3. Crear prefijo de Wine dedicado, aislado del prefijo por defecto (~/.wine)
echo "-- Paso 3/6: creando prefijo de Wine dedicado en ${WINE_PREFIX_MT4} --"
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

# 4. Crear/reparar mt4-bridge/orders/{pending,results} — carpetas reales
#    (clone nuevo sin Wine) o symlinks hacia Common/Files del prefijo de
#    Wine (MT4 ya instalado y corrido al menos una vez en esta máquina).
echo "-- Paso 4/6: preparando mt4-bridge/orders/{pending,results} --"
setup_bridge_dirs
echo

# 4.5. Enlazar el EA a MQL4/Experts/ (idempotente, mismo mecanismo que
#      la variante Arch de este script).
echo "-- Paso 4.5/6: enlazando KronosBridgeEA.mq4 en MQL4/Experts/ --"
link_ea_to_experts
echo

# 5. Instrucciones manuales
echo "-- Paso 5/6: pasos MANUALES pendientes --"
cat <<EOF

Lo automatizable ya quedó listo. Faltan estos pasos manuales:

1. Descargar el instalador de VT Markets desde vtmarkets.com
   ("vtmarkets4setup.exe") — a diferencia de lo que se pensó
   originalmente, VT Markets SÍ distribuye su propio instalador, no
   hace falta el genérico de metatrader4.com. Guárdalo en cualquier
   carpeta temporal, ej. ~/Descargas.

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
        DISPLAY=:1 WINEPREFIX="${WINE_PREFIX_MT4}" wine ~/Descargas/vtmarkets4setup.exe

   b) X11 forwarding por SSH (más simple si tenés X11 corriendo en tu
      máquina local, ej. otra Linux con escritorio):

        ssh -X usuario@server
        WINEPREFIX="${WINE_PREFIX_MT4}" wine ~/Descargas/vtmarkets4setup.exe

   c) xvfb-run para pasos que NO requieren ver nada (ej. dejar que el
      instalador corra con sus defaults sin intervención) — no sirve
      para loguearte en MT4 ni compilar el EA en MetaEditor, ambos
      necesitan ver la ventana de verdad:

        WINEPREFIX="${WINE_PREFIX_MT4}" xvfb-run -a wine ~/Descargas/vtmarkets4setup.exe

3. Seguir el instalador gráfico hasta el final (Next, Next, Finish).
   MT4 debería quedar instalado dentro de:

     ${WINE_PREFIX_MT4}/drive_c/Program Files (x86)/VT Markets MT4/

4. Abrir MT4 con ese mismo prefijo (de nuevo, necesitás VNC o X11
   forwarding real acá, no xvfb-run solo):

     WINEPREFIX="${WINE_PREFIX_MT4}" wine "${WINE_PREFIX_MT4}/drive_c/Program Files (x86)/VT Markets MT4/terminal.exe"

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

6. Este script ya dejó KronosBridgeEA.mq4 enlazado en MQL4/Experts/
   (ver salida del Paso 4.5 arriba). Abrir MetaEditor (F4 desde MT4,
   viendo la ventana por VNC o X11 forwarding), ubicarlo en
   Navigator > Experts, y compilar con F7. Si el script corrió ANTES
   de instalar MT4 por primera vez, hay que volver a correrlo una vez
   ya esté instalado y abierto al menos una vez — recién ahí existen
   MQL4/Experts y Common/Files para enlazar (pasos 4 y 4.5).

Una vez logueado, viendo precios en tiempo real, y con el EA
compilado sin errores, MT4 está listo para arrastrar el EA al
gráfico y activar AutoTrading — ver docs/INSTALL_UBUNTU_SERVER.md
para el resto (activación del EA, puente n8n -> MT4, troubleshooting).

EOF

echo "== Setup automatizado completado =="
