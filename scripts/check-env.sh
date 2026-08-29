#!/usr/bin/env bash
# Kronos Bot — valida que .env (o el archivo pasado como argumento)
# tenga todas las variables que docker-compose.yml realmente necesita,
# sin vacías. Pensado para correr después de crear .env desde la
# plantilla de docs/INSTALL_LINUX.md, antes de "docker compose up -d",
# para no descubrir una variable faltante recién cuando un contenedor
# falla en caliente.
#
# Uso:
#   bash scripts/check-env.sh            # valida .env
#   bash scripts/check-env.sh .env.dev   # valida otro archivo (ej. dev)
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

# Variables realmente referenciadas en docker-compose.yml (${VAR} o
# ${VAR:-default}) — se recalcula del archivo real en vez de tener una
# lista hardcodeada, así este script no queda desactualizado si se
# agrega/saca una variable del compose más adelante.
mapfile -t REQUIRED < <(
  grep -ohE '\$\{[A-Za-z0-9_]+(:-[^}]*)?\}' "${REPO_ROOT}/docker-compose.yml" \
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

echo "== Kronos Bot — chequeo de $ENV_FILE =="
echo

if [[ ${#missing[@]} -eq 0 && ${#empty[@]} -eq 0 ]]; then
  echo "OK — las ${#REQUIRED[@]} variables que usa docker-compose.yml están presentes y con valor."
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
