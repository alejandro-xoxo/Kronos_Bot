#!/usr/bin/env bash
# Kronos Bot — chequeo de conectividad end-to-end del stack real, de
# solo lectura: NUNCA escribe en mt4-bridge/orders/pending/ ni dispara
# ninguna ejecución real en MT4. Pensado para correr a mano cuando algo
# "se siente raro" (como el 2026-09-01: señal no notificada por una
# columna faltante, dashboard sin poder leer Postgres por una
# contraseña desincronizada, modelo de Gemini deprecado — ninguno de
# estos tres se hubiera notado con un "docker compose ps" normal,
# todos son fallas silenciosas de un componente puntual).
#
# Uso:
#   bash scripts/healthcheck.sh            # stack de producción (docker-compose.yml)
#   bash scripts/healthcheck.sh dev         # stack dev (docker-compose.dev.yml) — NO correr
#                                           # si producción está arriba (dev/prod no simultáneos,
#                                           # se roban el callback de Telegram)
#
# Exit code 0 = todo OK. Exit code 1 = al menos un chequeo falló —
# pensado para poder engancharse a un cron/alerta más adelante.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-prod}"

if [[ "$MODE" == "dev" ]]; then
  ENV_FILE="${REPO_ROOT}/.env.dev"
  PROJECT_PREFIX="kronos_bot"   # docker-compose.dev.yml no cambia el project name,
                                 # solo sufija nombres de servicio — ver DEV_SETUP.md
  N8N_URL="http://localhost:5679"   # puerto dev, ver docker-compose.dev.yml
  DASHBOARD_PORT="8089"
else
  ENV_FILE="${REPO_ROOT}/.env"
  N8N_URL="http://localhost:5678"
  DASHBOARD_PORT="8088"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No se encontró $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

FAILS=0
pass() { echo "  OK   $1"; }
fail() { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }
warn() { echo "  WARN $1"; }

echo "== Kronos Bot — healthcheck ($MODE) =="
echo

# --- 1. Contenedores levantados -------------------------------------------
echo "-- Contenedores --"
# Telethon solo existe en producción — dev captura señales con un
# Telegram Trigger normal (el usuario es admin del grupo de pruebas),
# no con la cuenta de usuario vía Telethon (ver DEV_SETUP.md sección 5
# y la regla de "nodos de entrada nunca se sincronizan" en CLAUDE.md).
if [[ "$MODE" == "dev" ]]; then
  EXPECTED_SERVICES=(n8n postgres dashboard caddy)
else
  EXPECTED_SERVICES=(n8n postgres telethon dashboard caddy)
fi
for svc in "${EXPECTED_SERVICES[@]}"; do
  cid="$(docker compose $( [[ "$MODE" == "dev" ]] && echo "-f docker-compose.dev.yml" ) ps -q "$svc" 2>/dev/null)"
  if [[ -z "$cid" ]]; then
    fail "$svc: no encontrado"
    continue
  fi
  status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
  if [[ "$status" == "running" ]]; then
    pass "$svc: running"
  else
    fail "$svc: $status"
  fi
done
echo

# --- 2. Postgres — conexión real por red (NO desde dentro del propio -----
#        contenedor, que usa pg_hba.conf "trust" y esconde una          --
#        contraseña desincronizada, como pasó el 2026-09-01) --------------
echo "-- Postgres (conexión de red real, misma ruta que usa el dashboard) --"
DASH_CID="$(docker compose $( [[ "$MODE" == "dev" ]] && echo "-f docker-compose.dev.yml" ) ps -q dashboard 2>/dev/null)"
if [[ -z "$DASH_CID" ]]; then
  fail "postgres: no se pudo probar (contenedor dashboard no encontrado)"
else
  result="$(docker exec "$DASH_CID" python3 -c "
import psycopg2, os, sys
try:
    conn = psycopg2.connect(host='postgres', dbname=os.environ['POSTGRES_DB'], user=os.environ['POSTGRES_USER'], password=os.environ['POSTGRES_PASSWORD'], connect_timeout=5)
    cur = conn.cursor()
    cur.execute('SELECT circuit_breaker_pct, capital_real FROM settings ORDER BY id DESC LIMIT 1')
    row = cur.fetchone()
    print('OK', row)
except Exception as e:
    print('FAIL', e)
    sys.exit(1)
" 2>&1)"
  if [[ "$result" == OK* ]]; then
    pass "conexión + columnas circuit_breaker_pct/capital_real: $result"
  else
    fail "conexión: $result"
  fi
fi
echo

# --- 3. n8n — API responde y los workflows core están activos ------------
echo "-- n8n --"
if [[ -z "${N8N_API_KEY:-}" ]]; then
  warn "N8N_API_KEY vacía en $ENV_FILE — no se puede chequear vía API"
else
  wf_json="$(curl -s -m 5 "${N8N_URL}/api/v1/workflows" -H "X-N8N-API-KEY: ${N8N_API_KEY}")"
  if [[ -z "$wf_json" ]]; then
    fail "API de n8n no respondió en ${N8N_URL}"
  else
    # Solo se chequean los workflows "Kronos N - ..." (los 9-10 reales del
    # sistema, numerados). Se ignoran a propósito workflows legados/
    # archivados con otro nombre (ej. "Kronos Bot - MVP Fase 3 ..."), que
    # están inactivos a propósito desde el refactor a split-mvp/split-dev.
    inactive="$(echo "$wf_json" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
items = d.get('data', d) if isinstance(d, dict) else d
pattern = re.compile(r'^Kronos( Dev)? \d')
names = [w['name'] for w in items if pattern.match(w['name']) and not w.get('active')]
print('\n'.join(names))
" 2>/dev/null)"
    total="$(echo "$wf_json" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
items = d.get('data', d) if isinstance(d, dict) else d
pattern = re.compile(r'^Kronos( Dev)? \d')
print(sum(1 for w in items if pattern.match(w['name'])))
" 2>/dev/null)"
    if [[ -z "$inactive" ]]; then
      pass "API responde, ${total:-?} workflows, todos activos"
    else
      fail "workflows inactivos: $(echo "$inactive" | tr '\n' ',' | sed 's/,$//')"
    fi
  fi
fi
echo

# --- 4. Dashboard — endpoints reales (misma ruta que el navegador) -------
echo "-- Dashboard --"
if [[ -z "${DASHBOARD_USER:-}" || -z "${DASHBOARD_PASSWORD:-}" ]]; then
  warn "DASHBOARD_USER/PASSWORD vacíos en $ENV_FILE — no se puede chequear"
else
  registros="$(curl -s -m 5 -u "${DASHBOARD_USER}:${DASHBOARD_PASSWORD}" "http://localhost:${DASHBOARD_PORT}/api/registros")"
  if echo "$registros" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(1 if 'error' in d else 0)" 2>/dev/null; then
    pass "/api/registros responde sin error (panel Crecimiento/PVG)"
  else
    fail "/api/registros: $(echo "$registros" | head -c 200)"
  fi

  positions="$(curl -s -m 5 -u "${DASHBOARD_USER}:${DASHBOARD_PASSWORD}" "http://localhost:${DASHBOARD_PORT}/api/positions")"
  if [[ -n "$positions" ]]; then
    pass "/api/positions responde (panel de control)"
  else
    fail "/api/positions no respondió"
  fi
fi
echo

# --- 5. Telethon — sigue corriendo y escuchando (solo logs, no manda ------
#        nada) --------------------------------------------------------------
echo "-- Telethon --"
if [[ "$MODE" == "dev" ]]; then
  echo "  (no aplica en dev — captura por Telegram Trigger, no Telethon)"
elif TEL_CID="$(docker compose ps -q telethon 2>/dev/null)" && [[ -z "$TEL_CID" ]]; then
  fail "telethon: contenedor no encontrado"
else
  recent_errors="$(docker logs "$TEL_CID" --since 30m 2>&1 | grep -ci "error\|traceback" || true)"
  if [[ "$recent_errors" -eq 0 ]]; then
    pass "sin errores en los últimos 30 min de logs"
  else
    fail "$recent_errors línea(s) de error en los últimos 30 min — revisar 'docker logs $TEL_CID'"
  fi
fi
echo

# --- 6. Puente MT4 — status.json actualizándose (NO se escribe nada) -----
echo "-- Puente MT4 (solo lectura — no se manda ninguna orden) --"
STATUS_PATH="${MT4_ORDERS_HOST_PATH:-}/status.json"
if [[ -z "${MT4_ORDERS_HOST_PATH:-}" || ! -f "$STATUS_PATH" ]]; then
  warn "MT4_ORDERS_HOST_PATH no configurado o status.json no existe todavía — normal si el EA nunca corrió en esta máquina"
else
  updated_at="$(python3 -c "
import json, sys
try:
    d = json.load(open('$STATUS_PATH'))
    print(d.get('updated_at', ''))
except Exception as e:
    print('')
")"
  if [[ -z "$updated_at" ]]; then
    fail "status.json existe pero no se pudo leer updated_at"
  else
    age_sec="$(python3 -c "
from datetime import datetime, timezone
try:
    ts = datetime.strptime('$updated_at', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    print(int((datetime.now(timezone.utc) - ts).total_seconds()))
except Exception:
    print(999999)
")"
    if [[ "$age_sec" -lt 120 ]]; then
      pass "status.json actualizado hace ${age_sec}s (EA reportando)"
    else
      fail "status.json desactualizado hace ${age_sec}s — el EA puede no estar corriendo"
    fi
  fi
fi
echo

# --- Resumen ----------------------------------------------------------------
echo "== Resumen =="
if [[ "$FAILS" -eq 0 ]]; then
  echo "Todo OK."
  exit 0
else
  echo "$FAILS chequeo(s) fallaron — revisar arriba."
  exit 1
fi
