#!/usr/bin/env bash
# Reposiciona Dashboard/Telegram/MT4 según el layout de Kronos, en
# píxeles reales calculados contra el monitor efectivo de cada
# ventana. Se invoca desde start-kronos.sh vía `systemd-run ... -- bash
# ${0}` — por RUTA, no embebido como string con `declare -f` + `bash
# -c`: systemd-run interpreta cualquier `$variable` dentro de un
# string de ExecStart como referencia a una variable de entorno del
# *unit* systemd (no del bash interno), y como esas variables
# (clase_literal, mon_id, etc.) nunca están definidas en el unit, las
# sustituye por vacío ANTES de que bash llegue a ejecutar nada —
# systemd lo reporta como "Referenced but unset environment variable
# evaluates to an empty string" en el journal. El resultado era que la
# función corría (exit 0, ~40ms) pero sin mover ni redimensionar
# ninguna ventana — bug real, reproducido 2026-08-24: el Dashboard
# quedó flotando chico en el centro de la pantalla pese a que el
# script terminó "Listo" sin errores. Al vivir en un archivo aparte e
# invocarse por ruta, systemd-run nunca ve el contenido del script como
# parte del ExecStart, así que no hay nada que reinterprete.
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq no disponible, no se reposicionan ventanas."; exit 0; }

posicionar_una() {
    # clase_literal: nombre exacto tal cual aparece en `.class` de
    # hyprctl (sin escapar) — se usa para comparar con jq.
    # clase_regex: mismo nombre pero apto como patrón de `class:` en
    # hyprctl dispatch (con metacaracteres regex escapados, ej. el
    # punto de "terminal.exe"). Usar clase_regex también para el
    # filtro de jq (como se hacía antes) nunca matcheaba
    # "terminal.exe" porque jq compara texto literal, no regex — bug
    # real, reproducido 2026-08-24: la ventana de MT4 nunca se
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

    local geo x y w h reserved_top usable_h win_x win_y win_w
    geo="$(hyprctl monitors -j | jq -r --argjson id "${mon_id}" '.[] | select(.id==$id) | "\(.x) \(.y) \(.width/.scale|floor) \(.height/.scale|floor) \(.reserved[1])"')"
    [ -n "${geo}" ] || return 0
    read -r x y w h reserved_top <<<"${geo}"
    usable_h=$((h - reserved_top))
    win_x=$((x + (w * frac_x / 100)))
    win_y=$((y + reserved_top))
    win_w=$((w * frac_w / 100))
    hyprctl dispatch focuswindow "class:^(${clase_regex})\$" >/dev/null 2>&1
    hyprctl dispatch resizewindowpixel exact "${win_w} ${usable_h}","class:^(${clase_regex})\$" >/dev/null 2>&1
    hyprctl dispatch movewindowpixel exact "${win_x} ${win_y}","class:^(${clase_regex})\$" >/dev/null 2>&1
}

# Las tres corren en paralelo (cada una espera solo lo que su propia
# ventana tarde) en vez de en secuencia, para no sumar los timeouts de
# las que tardan.
posicionar_una "KronosDashboard" "KronosDashboard" 0 65 &
posicionar_una "KronosTelegram" "KronosTelegram" 65 35 &
posicionar_una "terminal.exe" "terminal\\.exe" 0 100 &
wait
