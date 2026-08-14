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

WINE_PREFIX_MT4="${HOME}/.wine-mt4"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MT4_BRIDGE_DIR="${REPO_ROOT}/mt4-bridge"

echo "== Kronos Bot — Setup MT4 (Fase 6, Linux/Arch) =="
echo

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
    WINEPREFIX="${WINE_PREFIX_MT4}" WINEARCH=win32 wineboot --init
    echo "Prefijo creado en ${WINE_PREFIX_MT4} (arquitectura win32, requerida por MT4)."
fi
echo

# 3. Crear carpeta mt4-bridge/ en la raíz del repo
echo "-- Paso 3/4: creando estructura de mt4-bridge/ --"
mkdir -p "${MT4_BRIDGE_DIR}/orders/pending"
mkdir -p "${MT4_BRIDGE_DIR}/orders/results"
if [ ! -f "${MT4_BRIDGE_DIR}/.gitkeep" ]; then
    touch "${MT4_BRIDGE_DIR}/orders/pending/.gitkeep"
    touch "${MT4_BRIDGE_DIR}/orders/results/.gitkeep"
fi
echo "Carpeta lista en ${MT4_BRIDGE_DIR} (orders/pending, orders/results)."
echo

# 4. Instrucciones manuales
echo "-- Paso 4/4: pasos MANUALES pendientes --"
cat <<EOF

Lo automatizable ya quedó listo. Faltan estos pasos manuales:

1. Descargar el instalador GENÉRICO de MetaTrader 4 desde el sitio
   oficial: https://www.metatrader4.com/es/download
   (NO existe un instalador separado de VT Markets — es el mismo
   software genérico para cualquier bróker; la conexión a VT Markets
   se hace después, desde dentro de la plataforma ya instalada).
   Guárdalo en cualquier carpeta temporal, ej. ~/Descargas
   (normalmente algo como "mt4setup.exe").

2. Correr el instalador usando el prefijo de Wine dedicado (NO el
   prefijo por defecto), para no mezclarlo con otras apps de Wine:

     WINEPREFIX="${WINE_PREFIX_MT4}" wine ~/Descargas/mt4setup.exe

3. Seguir el instalador gráfico hasta el final (Next, Next, Finish).
   MT4 debería quedar instalado dentro de:

     ${WINE_PREFIX_MT4}/drive_c/Program Files (x86)/MetaTrader 4/

4. Abrir MT4 con ese mismo prefijo:

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

Una vez logueado y viendo precios en tiempo real en el terminal,
MT4 está listo para el siguiente paso: instalar el EA puente
(Fase 6, pendiente — no implementado todavía).

EOF

echo "== Setup automatizado completado =="
