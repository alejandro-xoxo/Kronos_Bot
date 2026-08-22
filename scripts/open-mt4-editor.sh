#!/usr/bin/env bash
# Abre MT4 (terminal) y MetaEditor de PRODUCCIÓN (~/.wine-mt4) para
# trabajar en el EA (KronosBridgeEA.mq4): compilar con F7, revisar
# Properties > Inputs, la pestaña Experts, etc.
#
# A propósito NO toca ~/.wine-mt4-demo (el prefijo de dev) ni el
# stack de Docker — es solo para el flujo de "cambiar/recompilar el
# EA de producción", separado de start-kronos.sh (que levanta todo
# el stack para operar).
set -euo pipefail

WINE_PREFIX_MT4="${HOME}/.wine-mt4"
MT4_DIR="$(find "${WINE_PREFIX_MT4}/drive_c/Program Files (x86)" -maxdepth 1 -iname "*MT4*" -type d 2>/dev/null | head -n1)"

if [ -z "${MT4_DIR}" ]; then
    echo "ERROR: no se encontró la carpeta de instalación de MT4 en ${WINE_PREFIX_MT4}. ¿Está instalado?" >&2
    exit 1
fi

TERMINAL_EXE="${MT4_DIR}/terminal.exe"
METAEDITOR_EXE="${MT4_DIR}/metaeditor.exe"

for exe in "${TERMINAL_EXE}" "${METAEDITOR_EXE}"; do
    if [ ! -f "${exe}" ]; then
        echo "ERROR: no se encontró ${exe}" >&2
        exit 1
    fi
done

# Igual que en start-kronos.sh: si MT4 ya está corriendo en este
# prefijo específico (por PID + WINEPREFIX real, no solo por nombre
# de proceso — evita confundirlo con una instancia del prefijo demo),
# no se relanza.
mt4_already_running=""
for pid in $(pgrep -f "terminal.exe" 2>/dev/null || true); do
    if tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -qx "WINEPREFIX=${WINE_PREFIX_MT4}"; then
        mt4_already_running="1"
        break
    fi
done

echo "== Prefijo de producción: ${WINE_PREFIX_MT4} =="

if [ -n "${mt4_already_running}" ]; then
    echo "MT4 (producción) ya está corriendo, no se relanza."
else
    echo "Abriendo MT4 (producción)..."
    setsid env WINEPREFIX="${WINE_PREFIX_MT4}" wine "${TERMINAL_EXE}" >/dev/null 2>&1 &
fi

echo "Abriendo MetaEditor (producción)..."
setsid env WINEPREFIX="${WINE_PREFIX_MT4}" wine "${METAEDITOR_EXE}" >/dev/null 2>&1 &

echo "== Listo. Verificá en la ventana de MT4 que la cuenta sea 23096429 (real), no 911260411 (demo). =="
