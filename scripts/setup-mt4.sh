#!/usr/bin/env bash
# Kronos Bot — Fase 6: preparación del entorno MT4 en distros Linux
# basadas en Arch (Arch, CachyOS, Manjaro, EndeavourOS, etc.), vía Wine.
#
# Para Windows, usar scripts/setup-mt4.ps1 en su lugar — ahí MT4 corre
# nativo, sin Wine.
#
# Automatiza lo que se puede automatizar (paquetes, prefijo de Wine
# aislado, carpeta de comunicación con n8n). La instalación de MT4
# en sí y el login a la cuenta VT Markets quedan como pasos manuales
# (requieren interacción gráfica con el instalador de MT4).
#
# Requiere pacman (gestor de paquetes de Arch y derivados). Si tu
# distro Arch-based usa un wrapper de AUR (yay, paru), pacman sigue
# funcionando igual para paquetes de los repos oficiales como wine.

set -euo pipefail

# Configurable vía env var para poder correr este mismo script contra
# el prefijo demo (WINE_PREFIX_MT4=~/.wine-mt4-demo bash scripts/setup-mt4.sh)
# sin tocar el archivo — antes estaba hardcodeado a ~/.wine-mt4, lo que
# hacía imposible reusarlo para un segundo prefijo sin editarlo a mano.
WINE_PREFIX_MT4="${WINE_PREFIX_MT4:-${HOME}/.wine-mt4}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MT4_BRIDGE_DIR="${REPO_ROOT}/mt4-bridge"

echo "== Kronos Bot — Setup MT4 (Fase 6, Linux/Arch) =="
echo

# Crea o repara el symlink mt4-bridge/orders/<name> -> <target>, de forma
# idempotente:
# - Si ya es un symlink que apunta exactamente a <target>, no toca nada.
# - Si es un symlink roto o apuntando a un prefijo viejo, lo recrea.
# - Si es una carpeta real (clone nuevo con .gitkeep, o resultado de un
#   `mkdir -p` de una corrida anterior sin Wine), la reemplaza por el
#   symlink — mismo procedimiento que estaba documentado a mano en
#   docs/INSTALL_LINUX.md sección 8.
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

    # Busca MQL4/Experts bajo cualquier carpeta de terminal QUE NO sea
    # "Common" (Common no tiene MQL4/Experts propio, es solo Files/).
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

if ! command -v pacman >/dev/null 2>&1; then
    echo "ERROR: este script requiere pacman (distro basada en Arch)." >&2
    echo "Para Windows, usa scripts/setup-mt4.ps1 en su lugar." >&2
    exit 1
fi

# 1. Instalar wine y winetricks
echo "-- Paso 1/4: instalando wine y winetricks --"
if ! command -v wine >/dev/null 2>&1 || ! command -v winetricks >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm wine winetricks
else
    echo "wine y winetricks ya están instalados, se omite."
fi
echo

# 2. Crear prefijo de Wine dedicado, aislado del prefijo por defecto (~/.wine)
echo "-- Paso 2/4: creando prefijo de Wine dedicado en ${WINE_PREFIX_MT4} --"
if [ -d "${WINE_PREFIX_MT4}" ]; then
    echo "El prefijo ${WINE_PREFIX_MT4} ya existe, se omite la creación."
else
    # Wine 7+ ya no soporta forzar WINEARCH=win32 en modo wow64 (arquitectura
    # combinada 32/64 bits por defecto desde Wine 7). El prefijo por defecto
    # corre MT4 (32 bits) sin necesidad de forzar la arquitectura.
    WINEPREFIX="${WINE_PREFIX_MT4}" wineboot --init
    echo "Prefijo creado en ${WINE_PREFIX_MT4}."
fi
echo

# 3. Crear/reparar mt4-bridge/orders/{pending,results} — carpetas reales
#    (clone nuevo sin Wine) o symlinks hacia Common/Files del prefijo de
#    Wine (MT4 ya instalado y corrido al menos una vez en esta máquina).
echo "-- Paso 3/4: preparando mt4-bridge/orders/{pending,results} --"
setup_bridge_dirs
echo
echo "-- Paso 3.5/4: enlazando KronosBridgeEA.mq4 en MQL4/Experts/ --"
link_ea_to_experts
echo

# 4. Instrucciones manuales
echo "-- Paso 4/4: pasos MANUALES pendientes --"
cat <<EOF

Lo automatizable ya quedó listo. Faltan estos pasos manuales:

1. Descargar el instalador de VT Markets desde vtmarkets.com
   ("vtmarkets4setup.exe") — a diferencia de lo que se pensó
   originalmente, VT Markets SÍ distribuye su propio instalador, no
   hace falta el genérico de metatrader4.com. Guárdalo en cualquier
   carpeta temporal, ej. ~/Descargas.

2. Correr el instalador usando el prefijo de Wine dedicado (NO el
   prefijo por defecto), para no mezclarlo con otras apps de Wine:

     WINEPREFIX="${WINE_PREFIX_MT4}" wine ~/Descargas/vtmarkets4setup.exe

3. Seguir el instalador gráfico hasta el final (Next, Next, Finish).
   MT4 debería quedar instalado dentro de:

     ${WINE_PREFIX_MT4}/drive_c/Program Files (x86)/VT Markets MT4/

4. Abrir MT4 con ese mismo prefijo:

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
   (ver salida del Paso 3.5 arriba). Abrir MetaEditor (F4 desde MT4),
   ubicarlo en Navigator > Experts, y compilar con F7. Si el script
   corrió ANTES de instalar MT4 por primera vez, hay que volver a
   correrlo una vez ya esté instalado y abierto al menos una vez —
   recién ahí existe la carpeta MQL4/Experts para enlazar.

Una vez logueado, viendo precios en tiempo real y con el EA
compilado sin errores, MT4 está listo para arrastrar el EA al
gráfico y activar AutoTrading.

EOF

echo "== Setup automatizado completado =="
