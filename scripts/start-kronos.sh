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

# Antes esto comparaba WINEPREFIX leyendo /proc/<pid>/environ de cada
# proceso "terminal.exe" encontrado — frágil: si el kernel restringe la
# lectura de environ de otro proceso (ptrace_scope), la comparación
# fallaba en silencio, mt4_already_running quedaba vacío, y el script
# relanzaba MT4 igual aunque ya estuviera corriendo (bug real,
# reproducido 2026-08-21: el log del EA mostró 3 cargas duplicadas del
# mismo EA en la misma sesión). Como en esta máquina solo hay un
# prefijo de Wine con MT4 (~/.wine-mt4), alcanza con detectar CUALQUIER
# terminal.exe corriendo — no hace falta distinguir por prefijo.
mt4_already_running=""
if pgrep -x "terminal.exe" >/dev/null 2>&1; then
    mt4_already_running="1"
fi

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
# ~/.config/hypr/kronos-layout.conf: Dashboard (65%) + Telegram (35%)
# van al workspace 9; MT4/gráfico va solo, a pantalla completa, al
# workspace 10 — separado para no competir por espacio con el
# dashboard/Telegram. Ambos workspaces prefieren la pantalla
# secundaria (HDMI-A-1) si está conectada; si se usa solo el monitor
# del laptop (eDP-1, "monitor personal"), caen ahí solos — los tamaños
# son en porcentaje, así que el layout se mantiene en cualquiera de
# los dos monitores.


# Las ventanas quedan cada una en su workspace (9: Dashboard+Telegram,
# 10: MT4/gráfico — ver windowrules en kronos-layout.conf), pero sin
# forzar el cambio acá quedan fuera de vista si el/los monitores no
# están ya parados en esos workspaces — hay que llevarlos, si no,
# parece que "no abrió nada" aunque los procesos sí estén corriendo.
# `workspace` (no `focus workspace`) mueve el workspace al monitor que
# le corresponde sin robarle el foco al otro — con dos monitores esto
# deja ws9 en eDP-1 y ws10 en HDMI-A-1 visibles a la vez. Se despacha
# con un pequeño delay, desacoplado, porque si se hace mientras
# alacritty (este mismo script) sigue siendo la ventana activa, al
# cerrarse alacritty Hyprland devuelve el foco al workspace anterior y
# el cambio se pierde — reproducido.
if command -v hyprctl >/dev/null 2>&1; then
    systemd-run --user --unit="kronos-focus-ws9-$$" -- \
        bash -c 'sleep 1; hyprctl dispatch workspace 9; hyprctl dispatch workspace 10' >/dev/null 2>&1 || true
fi

echo "== Listo. Dashboard: http://localhost:8088 =="
