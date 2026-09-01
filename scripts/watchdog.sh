#!/usr/bin/env bash
# Kronos Bot — corre scripts/healthcheck.sh y, si algo falla, avisa por
# Telegram vía el webhook "Kronos 11 - Watchdog Alert"
# (n8n-workflows/split-mvp/11-watchdog-alert.json). Pensado para cron,
# NO para correr a mano en el flujo normal — usá healthcheck.sh
# directamente para eso, este script solo agrega el aviso automático y
# el anti-spam.
#
# No manda el bot token de Telegram nunca fuera de n8n: le pega al
# webhook con WATCHDOG_SECRET (un secreto propio, sin relación con el
# bot) y n8n arma y manda el mensaje con la credencial que ya tiene.
#
# Anti-spam: solo avisa la PRIMERA vez que algo falla; mientras el
# problema siga, no vuelve a mandar el mismo aviso en cada corrida del
# cron. En cuanto un healthcheck vuelve a salir OK, se resetea y el
# próximo fallo vuelve a avisar.
#
# Instalación (no se agrega solo, a criterio del usuario):
#   crontab -e
#   */5 * * * * /usr/bin/env bash /home/alejandroa/Proyectos/Kronos_Bot/scripts/watchdog.sh >> /home/alejandroa/Proyectos/Kronos_Bot/logs/watchdog.log 2>&1

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
STATE_FILE="/tmp/kronos-watchdog-alerted"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No se encontró $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

if [[ -z "${WATCHDOG_SECRET:-}" || -z "${N8N_HOST:-}" ]]; then
  echo "WATCHDOG_SECRET o N8N_HOST vacíos en .env — no se puede avisar por Telegram, solo corre healthcheck local."
  bash "${REPO_ROOT}/scripts/healthcheck.sh"
  exit $?
fi

output="$(bash "${REPO_ROOT}/scripts/healthcheck.sh" 2>&1)"
status=$?

echo "$output"

if [[ $status -eq 0 ]]; then
  rm -f "$STATE_FILE"
  exit 0
fi

if [[ -f "$STATE_FILE" ]]; then
  echo "(ya se avisó de este problema, no se repite el aviso hasta que se resuelva)"
  exit 1
fi

fails_summary="$(echo "$output" | grep "  FAIL" | sed 's/^  FAIL /- /')"
alert_text="El healthcheck automático detectó problemas:%0A%0A${fails_summary}%0A%0ARevisar con: bash scripts/healthcheck.sh"
alert_text="${alert_text//$'\n'/%0A}"

webhook_url="https://${N8N_HOST}/webhook/kronos-watchdog-alert?secret=${WATCHDOG_SECRET}"
payload="$(python3 -c "
import json, sys
fails = '''$fails_summary'''
print(json.dumps({'text': 'El healthcheck automático detectó problemas:\n\n' + fails + '\n\nRevisar con: bash scripts/healthcheck.sh'}))
")"

http_code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$webhook_url" -H "Content-Type: application/json" -d "$payload")"

if [[ "$http_code" == "200" ]]; then
  touch "$STATE_FILE"
  echo "Aviso enviado por Telegram."
else
  echo "No se pudo enviar el aviso por Telegram (HTTP $http_code) — revisar manualmente."
fi

exit 1
