#!/usr/bin/env bash
# Kronos Bot — importa el workflow principal a una instancia de n8n
# recién levantada vía la API REST de n8n. Sin esto, un n8n nuevo
# arranca con CERO workflows — este paso no estaba documentado ni
# automatizado en docs/INSTALL_LINUX.md, había que hacerlo a mano
# desde la UI (Import from File) sin ninguna guía escrita.
#
# Requiere:
#   - N8N_API_KEY en .env (se genera desde la UI de n8n, Settings ->
#     n8n API -> Create an API Key, DESPUÉS del primer arranque —
#     ver docs/INSTALL_LINUX.md sección 3).
#   - El contenedor n8n ya levantado y respondiendo (docker compose up -d).
#   - curl, python3.
#
# Uso:
#   bash scripts/import-n8n-workflow.sh
#   bash scripts/import-n8n-workflow.sh n8n-workflows/webhook-dev-workflow.json --activate
#
# Sin argumento de archivo, importa n8n-workflows/webhook-mvp-workflow.json
# (el workflow de producción). --activate lo activa después de importarlo
# (requiere que las credenciales de Postgres/Telegram ya existan en esa
# instancia de n8n con los mismos IDs que trae el JSON, o falla — ver
# nota al final).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
WORKFLOW_FILE="${1:-${REPO_ROOT}/n8n-workflows/webhook-mvp-workflow.json}"
ACTIVATE=false
N8N_URL="${N8N_URL:-http://localhost:5678}"

for arg in "$@"; do
  if [[ "$arg" == "--activate" ]]; then ACTIVATE=true; fi
done

if [[ ! -f "$WORKFLOW_FILE" ]]; then
  echo "No existe el archivo de workflow: $WORKFLOW_FILE"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No se encontró $ENV_FILE — ver docs/INSTALL_LINUX.md sección 3."
  exit 1
fi

N8N_API_KEY="$(grep -E '^N8N_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)"
if [[ -z "$N8N_API_KEY" ]]; then
  cat <<'EOF'
N8N_API_KEY está vacía en el .env.

Generala primero desde la UI de n8n (con el stack ya levantado):
  1. Abrí n8n (ver N8N_HOST en tu .env, o http://localhost:5678 en local).
  2. Settings -> n8n API -> Create an API Key.
  3. Pegá el valor en N8N_API_KEY= dentro de .env.
  4. Volvé a correr este script.
EOF
  exit 1
fi

echo "== Kronos Bot — import de workflow a n8n =="
echo "Archivo:   $WORKFLOW_FILE"
echo "Instancia: $N8N_URL"
echo

# n8n espera solo {name, nodes, connections, settings} en el body del
# POST — el resto de campos que trae un export completo (id, active,
# etc.) hace que la API lo rechace. Se arma un payload limpio con
# python3 en vez de asumir que el archivo del repo ya viene en ese
# shape exacto (algunos, como los sincronizados con GET, traen campos
# de más).
if ! python3 -c "import json; json.load(open('$WORKFLOW_FILE'))" 2>/dev/null; then
  echo "El archivo no es JSON válido: $WORKFLOW_FILE"
  exit 1
fi

PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

python3 - "$WORKFLOW_FILE" "$PAYLOAD_FILE" <<'PYEOF'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

payload = {
    "name": data["name"],
    "nodes": data["nodes"],
    "connections": data["connections"],
    "settings": data.get("settings", {}),
}
with open(dst, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
PYEOF

RESPONSE="$(curl -sS -w '\n%{http_code}' \
  -X POST "${N8N_URL}/api/v1/workflows" \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  -H "Content-Type: application/json" \
  --data-binary @"$PAYLOAD_FILE")"

HTTP_CODE="$(echo "$RESPONSE" | tail -n1)"
BODY="$(echo "$RESPONSE" | sed '$d')"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Falló el import (HTTP $HTTP_CODE):"
  echo "$BODY"
  echo
  echo "Causa más común: las credenciales de Postgres/Telegram que"
  echo "referencia el JSON (por id) no existen todavía en esta"
  echo "instancia de n8n. Creálas primero desde la UI (Credentials ->"
  echo "New) y reseleccioná el workflow importado nodo por nodo, o"
  echo "importalo manualmente desde la UI (Import from File) para"
  echo "poder reasignar credenciales durante el import."
  exit 1
fi

WORKFLOW_ID="$(echo "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
echo "Importado OK — id: $WORKFLOW_ID"

if [[ "$ACTIVATE" == "true" ]]; then
  echo "Activando..."
  ACT_RESPONSE="$(curl -sS -w '\n%{http_code}' \
    -X POST "${N8N_URL}/api/v1/workflows/${WORKFLOW_ID}/activate" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}")"
  ACT_CODE="$(echo "$ACT_RESPONSE" | tail -n1)"
  if [[ "$ACT_CODE" == "200" ]]; then
    echo "Activado OK."
  else
    echo "No se pudo activar (HTTP $ACT_CODE) — revisar credenciales de cada nodo desde la UI antes de activarlo a mano."
    echo "$ACT_RESPONSE" | sed '$d'
  fi
else
  echo "No se activó (sin --activate). Antes de activarlo a mano:"
  echo "  1. Revisar cada nodo Postgres/Telegram en la UI y reasignar sus credenciales"
  echo "     a las que existen en esta instancia (los ids del JSON son de otra instancia)."
  echo "  2. Recién ahí, Settings del workflow -> Active."
fi
