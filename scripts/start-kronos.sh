#!/usr/bin/env bash
# Levanta el stack completo de producción de Kronos Bot: contenedores
# Docker (n8n, postgres, telethon, dashboard, ngrok) y MT4 bajo Wine
# (~/.wine-mt4). Pensado para lanzarse desde el lanzador de aplicaciones
# del sistema (ver kronos-bot.desktop).
set -euo pipefail

REPO_DIR="/home/alejandroa/Proyectos/Kronos_Bot"
WINE_PREFIX_MT4="${HOME}/.wine-mt4"

cd "${REPO_DIR}"

echo "== Levantando stack Docker (n8n, postgres, telethon, dashboard, ngrok) =="
docker compose up -d

echo "== Levantando MT4 (producción, ~/.wine-mt4) =="
TERMINAL_EXE="$(find "${WINE_PREFIX_MT4}/drive_c/Program Files (x86)" -maxdepth 2 -iname "terminal.exe" 2>/dev/null | head -n1)"

if [ -z "${TERMINAL_EXE}" ]; then
    echo "ERROR: no se encontró terminal.exe en ${WINE_PREFIX_MT4}. ¿MT4 está instalado?" >&2
    exit 1
fi

mt4_already_running=""
for pid in $(pgrep -f "terminal.exe"); do
    if tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -qx "WINEPREFIX=${WINE_PREFIX_MT4}"; then
        mt4_already_running="1"
        break
    fi
done

if [ -n "${mt4_already_running}" ]; then
    echo "MT4 ya parece estar corriendo en este prefijo, no se relanza."
else
    WINEPREFIX="${WINE_PREFIX_MT4}" wine "${TERMINAL_EXE}" &
    disown
    echo "MT4 lanzado."
fi

echo "== Abriendo Telegram Web =="
chromium --app=https://web.telegram.org/k/ --class=KronosTelegram >/dev/null 2>&1 &
disown

echo "== Abriendo Spotify =="
if ! pgrep -x spotify >/dev/null 2>&1; then
    spotify >/dev/null 2>&1 &
    disown
fi

# Las ventanas se acomodan solas en el workspace 9 vía las reglas de
# ~/.config/hypr/kronos-layout.conf (Telegram mitad izquierda, MT4 y
# Spotify comparten la mitad derecha).
hyprctl dispatch workspace 9 >/dev/null 2>&1 || true

echo "== Listo. Dashboard: http://localhost:8088 =="
