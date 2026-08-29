#!/usr/bin/env bash
# Kronos Bot — valida que .env (o el archivo pasado como argumento)
# tenga todas las variables que docker-compose.yml realmente necesita,
# sin vacías. Pensado para correr después de crear .env desde la
# plantilla de docs/INSTALL_LINUX.md, antes de "docker compose up -d",
# para no descubrir una variable faltante recién cuando un contenedor
# falla en caliente.
#
# Uso:
#   bash scripts/check-env.sh                       # valida .env contra docker-compose.yml
#   bash scripts/check-env.sh .env.dev               # valida .env.dev contra docker-compose.dev.yml (auto-detectado)
#   bash scripts/check-env.sh .env.dev otro.compose.yml   # o especificá el compose a mano
#
# No imprime valores reales de las variables — solo si están presentes
# y no vacías.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${REPO_ROOT}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No se encontró $ENV_FILE — crealo primero (ver docs/INSTALL_LINUX.md sección 3)."
  exit 1
fi

# El compose a validar se pasa como 2do argumento, o se auto-detecta a
# partir del nombre del .env: ".env.dev" -> "docker-compose.dev.yml",
# cualquier otro nombre -> "docker-compose.yml" (producción). Sin esto,
# validar .env.dev contra el compose de producción da falsos positivos
# reales: docker-compose.dev.yml usa NGROK_AUTHTOKEN_DEV/
# MT4_ORDERS_HOST_PATH_DEV, no las variables sin sufijo de producción.
if [[ -n "${2:-}" ]]; then
  COMPOSE_FILE="$2"
elif [[ "$(basename "$ENV_FILE")" == ".env.dev" ]]; then
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.dev.yml"
else
  COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "No se encontró el compose a validar: $COMPOSE_FILE"
  exit 1
fi

# Variables realmente referenciadas en el compose (${VAR} o
# ${VAR:-default}) — se recalcula del archivo real en vez de tener una
# lista hardcodeada, así este script no queda desactualizado si se
# agrega/saca una variable del compose más adelante.
mapfile -t REQUIRED < <(
  grep -ohE '\$\{[A-Za-z0-9_]+(:-[^}]*)?\}' "$COMPOSE_FILE" \
    | sed -E 's/\$\{([A-Za-z0-9_]+).*/\1/' \
    | sort -u
)

missing=()
empty=()

for var in "${REQUIRED[@]}"; do
  # Busca "VAR=" al inicio de línea (ignora comentarios y espacios).
  line="$(grep -E "^${var}=" "$ENV_FILE" || true)"
  if [[ -z "$line" ]]; then
    missing+=("$var")
    continue
  fi
  value="${line#*=}"
  if [[ -z "$value" ]]; then
    empty+=("$var")
  fi
done

echo "== Kronos Bot — chequeo de $ENV_FILE contra $(basename "$COMPOSE_FILE") =="
echo

if [[ ${#missing[@]} -eq 0 && ${#empty[@]} -eq 0 ]]; then
  echo "OK — las ${#REQUIRED[@]} variables que usa $(basename "$COMPOSE_FILE") están presentes y con valor."
  exit 0
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Faltan por completo (ni siquiera aparece la línea \"VAR=\"):"
  for v in "${missing[@]}"; do echo "  - $v"; done
  echo
fi

if [[ ${#empty[@]} -gt 0 ]]; then
  echo "Están declaradas pero vacías:"
  for v in "${empty[@]}"; do echo "  - $v"; done
  echo
fi

echo "Ver docs/INSTALL_LINUX.md sección 3 para de dónde sale cada una."
echo "Nota: N8N_API_KEY y MT4_ORDERS_HOST_PATH se completan DESPUÉS del"
echo "primer arranque (dependen de pasos manuales posteriores) — es"
echo "normal que aparezcan vacías en un chequeo hecho antes de eso."
exit 1
