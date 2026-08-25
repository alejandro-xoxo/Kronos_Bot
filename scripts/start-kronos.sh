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
# Las windowrules de kronos-layout.conf ya NO fijan tamaño/posición
# con `size %`/`move %`: cuando el monitor secundario (HDMI-A-1) no
# está conectado, Hyprland calcula esos porcentajes contra el monitor
# "asignado" al workspace (HDMI-A-1) en vez de contra el monitor donde
# el workspace realmente termina cayendo (eDP-1), y las ventanas
# aparecen con coordenadas negativas, fuera de pantalla — bug real,
# reproducido 2026-08-24 (se veía como "el gráfico no está" pese a que
# el proceso de MT4 sí estaba corriendo). Por eso el tamaño/posición se
# calculan acá, en píxeles reales, contra el monitor efectivo de cada
# ventana vía `hyprctl monitors`/`clients` — inmune a ese bug.
#
# Cada ventana se posiciona apenas SU PROPIA ventana existe en Hyprland
# (poll con timeout), no con un `sleep` fijo global: Telegram Web tarda
# bastante más en mapear su ventana que Dashboard (carga una SPA
# completa), así que un sleep único pensado para el caso rápido llegaba
# antes de que Telegram existiera, el dispatch de resize/move no
# encontraba la ventana y se perdía en silencio — quedaba con el
# tamaño/posición chico por defecto, tapada debajo del Dashboard, y
# parecía "no haber abierto" aunque el proceso sí estaba corriendo —
# bug real, reproducido 2026-08-24.
posicionar_ventanas_kronos() {
    command -v jq >/dev/null 2>&1 || { echo "jq no disponible, no se reposicionan ventanas."; return 0; }

    local x y w h reserved_top usable_h

    posicionar_una() {
        # clase_literal: nombre exacto tal cual aparece en `.class` de
        # hyprctl (sin escapar) — se usa para comparar con jq.
        # clase_regex: mismo nombre pero apto como patrón de `class:`
        # en hyprctl dispatch (con metacaracteres regex escapados,
        # ej. el punto de "terminal.exe"). Usar clase_regex también
        # para el filtro de jq (como se hacía antes) nunca matcheaba
        # "terminal.exe" porque jq compara texto literal, no regex —
        # bug real, reproducido 2026-08-24: la ventana de MT4 nunca se
        # encontraba y quedaba sin reposicionar.
        local clase_literal="$1" clase_regex="$2" frac_x="$3" frac_w="$4" timeout_s="${5:-20}"
        local esperado=0 mon_id=""
        while [ "${esperado}" -lt "${timeout_s}" ]; do
            mon_id="$(hyprctl clients -j | jq -r --arg c "${clase_literal}" '.[] | select(.class==$c) | .monitor' | head -n1)"
            [ -n "${mon_id}" ] && break
            sleep 1
            esperado=$((esperado + 1))
        done
        if [ -z "${mon_id}" ]; then
            echo "posicionar_ventanas_kronos: ${clase_literal} no apareció tras ${timeout_s}s, se omite."
            return 0
        fi

        local geo
        geo="$(hyprctl monitors -j | jq -r --argjson id "${mon_id}" '.[] | select(.id==$id) | "\(.x) \(.y) \(.width/.scale|floor) \(.height/.scale|floor) \(.reserved[1])"')"
        [ -n "${geo}" ] || return 0
        read -r x y w h reserved_top <<<"${geo}"
        usable_h=$((h - reserved_top))
        local win_x=$((x + (w * frac_x / 100)))
        local win_y=$((y + reserved_top))
        local win_w=$((w * frac_w / 100))
        hyprctl dispatch focuswindow "class:^(${clase_regex})\$" >/dev/null 2>&1
        hyprctl dispatch resizewindowpixel exact "${win_w} ${usable_h}","class:^(${clase_regex})\$" >/dev/null 2>&1
        hyprctl dispatch movewindowpixel exact "${win_x} ${win_y}","class:^(${clase_regex})\$" >/dev/null 2>&1
    }

    # Las tres corren en paralelo (cada una espera solo lo que su
    # propia ventana tarde) en vez de en secuencia, para no sumar los
    # timeouts de las que tardan.
    posicionar_una "KronosDashboard" "KronosDashboard" 0 65 &
    posicionar_una "KronosTelegram" "KronosTelegram" 65 35 &
    posicionar_una "terminal.exe" "terminal\\.exe" 0 100 &
    wait
}

if command -v hyprctl >/dev/null 2>&1; then
    systemd-run --user --unit="kronos-focus-ws9-$$" -- \
        bash -c 'sleep 1; hyprctl dispatch workspace 9; hyprctl dispatch workspace 10' >/dev/null 2>&1 || true
    systemd-run --user --unit="kronos-layout-$$" -- \
        bash -c "$(declare -f posicionar_ventanas_kronos); posicionar_ventanas_kronos" >/dev/null 2>&1 || true
fi

echo "== Listo. Dashboard: http://localhost:8088 =="
