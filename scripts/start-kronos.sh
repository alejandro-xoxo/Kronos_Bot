#!/usr/bin/env bash
# Levanta el stack completo de producción de Kronos Bot: contenedores
# Docker (n8n, postgres, telethon, dashboard, ngrok) y MT4 bajo Wine
# (~/.wine-mt4). Pensado para lanzarse desde el lanzador de aplicaciones
# del sistema (ver kronos-bot.desktop).
set -euo pipefail

REPO_DIR="/home/alejandroa/Proyectos/Kronos_Bot"
WINE_PREFIX_MT4="${HOME}/.wine-mt4"
KRONOS_LOG="/tmp/kronos-start.log"

exec > >(tee -a "${KRONOS_LOG}") 2>&1
echo "== $(date '+%Y-%m-%d %H:%M:%S') - arrancando start-kronos.sh =="

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
    setsid env WINEPREFIX="${WINE_PREFIX_MT4}" wine "${TERMINAL_EXE}" >/dev/null 2>&1 &
    echo "MT4 lanzado."
fi

# --class solo se respeta si Chromium corre sobre XWayland: con
# ozone-platform=wayland (default de este sistema) ignora --class y
# usa un app-id derivado de la URL, rompiendo las windowrule de
# ~/.config/hypr/kronos-layout.conf que matchean por clase. Además,
# cada --app necesita su propio --user-data-dir: si comparten perfil,
# Chromium fusiona la segunda ventana en el proceso de la primera vía
# IPC de instancia única y ambas terminan con la misma clase (la del
# último --app lanzado), rompiendo el layout.
#
# systemd-run --user --scope (no setsid a secas): Hyprland lanza
# alacritty (y por herencia este script) dentro de un scope systemd
# transitorio (app-Hyprland-alacritty-*.scope). Un proceso hijo
# desacoplado solo con setsid sigue en ese cgroup, así que al cerrarse
# alacritty systemd puede matarlo a mitad de arranque (bug real ya
# visto con Spotify). systemd-run crea un scope independiente, inmune
# a que el scope de alacritty se cierre.
echo "== Abriendo Dashboard =="
systemd-run --user --scope --unit="kronos-dashboard-$$" -- \
    chromium --ozone-platform=x11 --user-data-dir="${HOME}/.cache/kronos-chromium-dashboard" --app=http://localhost:8088 --class=KronosDashboard >/dev/null 2>&1 &
disown

echo "== Abriendo Telegram Web =="
systemd-run --user --scope --unit="kronos-telegram-$$" -- \
    chromium --ozone-platform=x11 --user-data-dir="${HOME}/.cache/kronos-chromium-telegram" --app=https://web.telegram.org/k/ --class=KronosTelegram >/dev/null 2>&1 &
disown

# Las ventanas se acomodan solas vía las reglas de
# ~/.config/hypr/kronos-layout.conf: MT4 queda oculto en un workspace
# especial (no aparece en ningún monitor), y Dashboard+Telegram van a
# la pantalla secundaria (HDMI-A-1), workspace 9. No se despacha
# ningún cambio de workspace acá a propósito: la pantalla principal
# (eDP-1) debe quedar completamente libre, sin que este script le
# robe el foco.


# Las ventanas de Dashboard/Telegram se abren en el workspace 9 (ver
# windowrules arriba), pero sin cambiar de workspace acá quedan
# abiertas fuera de vista si el monitor secundario no está ya parado
# ahí — hay que llevarlo, si no, parece que "no abrió nada" aunque los
# procesos sí estén corriendo.
if command -v hyprctl >/dev/null 2>&1; then
    hyprctl dispatch workspace 9 >/dev/null 2>&1 || true
fi

echo "== Listo. Dashboard: http://localhost:8088 =="
