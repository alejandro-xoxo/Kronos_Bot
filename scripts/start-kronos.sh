#!/usr/bin/env bash
# Levanta el stack completo de producción de Kronos Bot: contenedores
# Docker (n8n, postgres, telethon, dashboard, ngrok) y MT4 bajo Wine
# (~/.wine-mt4). Pensado para lanzarse desde el lanzador de aplicaciones
# del sistema (ver kronos-bot.desktop).
set -euo pipefail

REPO_DIR="/home/alejandroa/Proyectos/Kronos_Bot-prod"
WINE_PREFIX_MT4="${HOME}/.wine-mt4"
KRONOS_LOG="/tmp/kronos-start.log"

exec > >(tee -a "${KRONOS_LOG}") 2>&1
echo "== $(date '+%Y-%m-%d %H:%M:%S') - arrancando start-kronos.sh =="

cd "${REPO_DIR}"

# Si un lanzamiento anterior de Chromium se cortó de forma abrupta
# (kill, crash, cierre del scope de systemd), el perfil queda con un
# SingletonLock apuntando a un PID que ya no existe. Chromium detecta
# el lock y, en vez de detectar que está obsoleto, a veces simplemente
# se cierra sin abrir ventana ni avisar nada (stdout/stderr van a
# /dev/null) — se ve como si el script no hiciera nada. Si el PID del
# lock no está corriendo, se limpia antes de lanzar.
clear_stale_chromium_lock() {
    local profile_dir="$1"
    local lock_target pid
    [ -L "${profile_dir}/SingletonLock" ] || return 0
    lock_target="$(readlink "${profile_dir}/SingletonLock")"
    pid="${lock_target##*-}"
    if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
        echo "Lock obsoleto de Chromium en ${profile_dir} (PID ${pid} no existe), limpiando."
        rm -f "${profile_dir}/SingletonLock" "${profile_dir}/SingletonSocket" "${profile_dir}/SingletonCookie"
    fi
}

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
# systemd-run --user --scope + `&`/disown: Hyprland lanza alacritty
# (y por herencia este script) dentro de un scope systemd transitorio
# (app-Hyprland-alacritty-*.scope), y backgroundear un --scope desde
# este mismo shell entra en carrera con el cierre del script: si
# alacritty cierra antes de que systemd termine de mover el proceso
# recién forkeado a su cgroup nuevo, lo pierde con "No PIDs left to
# attach to the scope's control group, refusing" y el lanzamiento
# falla en silencio (stderr iba a /dev/null) — bug real, reproducido
# (se veía como "no abrió nada" pese a que el resto del script
# terminaba bien). Por eso se usa un *servicio* transient: systemd-run
# sin --scope pide el unit por D-Bus y vuelve al toque, sin `&`, sin
# relación de proceso con este shell — inmune a esa carrera.
# Si ya hay un Chromium corriendo con el mismo --user-data-dir, un
# segundo lanzamiento no abre ventana nueva de forma confiable: choca
# con el singleton-lock del perfil y puede quedar sin efecto visible.
# Igual que con MT4, si ya está corriendo no se relanza.
echo "== Abriendo Dashboard =="
if pgrep -f -- "--class=KronosDashboard" >/dev/null 2>&1; then
    echo "Dashboard ya está corriendo, no se relanza."
else
    clear_stale_chromium_lock "${HOME}/.cache/kronos-chromium-dashboard"
    systemd-run --user --unit="kronos-dashboard-$$" -- \
        chromium --ozone-platform=x11 --user-data-dir="${HOME}/.cache/kronos-chromium-dashboard" --app=http://localhost:8088 --class=KronosDashboard
fi

echo "== Abriendo Telegram Web =="
if pgrep -f -- "--class=KronosTelegram" >/dev/null 2>&1; then
    echo "Telegram Web ya está corriendo, no se relanza."
else
    clear_stale_chromium_lock "${HOME}/.cache/kronos-chromium-telegram"
    systemd-run --user --unit="kronos-telegram-$$" -- \
        chromium --ozone-platform=x11 --user-data-dir="${HOME}/.cache/kronos-chromium-telegram" --app=https://web.telegram.org/k/ --class=KronosTelegram
fi

# Las ventanas se acomodan solas vía las reglas de
# ~/.config/hypr/kronos-layout.conf: MT4 queda oculto en un workspace
# especial (no aparece en ningún monitor), y Dashboard+Telegram van a
# la pantalla secundaria (HDMI-A-1), workspace 9.


# Las ventanas de Dashboard/Telegram se abren en el workspace 9 (ver
# windowrules arriba), pero sin cambiar de workspace acá quedan
# abiertas fuera de vista si el monitor secundario no está ya parado
# ahí — hay que llevarlo, si no, parece que "no abrió nada" aunque los
# procesos sí estén corriendo. Se despacha con un pequeño delay,
# desacoplado, porque si se hace mientras alacritty (este mismo
# script) sigue siendo la ventana activa, al cerrarse alacritty
# Hyprland devuelve el foco al workspace anterior y el cambio se
# pierde — reproducido.
if command -v hyprctl >/dev/null 2>&1; then
    systemd-run --user --unit="kronos-focus-ws9-$$" -- \
        bash -c 'sleep 1; hyprctl dispatch workspace 9' >/dev/null 2>&1 || true
fi

echo "== Listo. Dashboard: http://localhost:8088 =="
