#!/usr/bin/env bash
# Kronos Bot — dump diario de Postgres (signals, signal_modifications,
# settings, daily_pnl — toda la base) a un archivo local comprimido.
# Hoy no hay ningún backup: si el volumen de Postgres se corrompe, se
# pierde el historial completo de señales y P&L sin forma de
# recuperarlo.
#
# Uso manual:
#   bash scripts/backup-postgres.sh
#
# Instalación por cron (no se agrega solo, a criterio del usuario):
#   crontab -e
#   0 3 * * * /usr/bin/env bash /home/alejandroa/Proyectos/Kronos_Bot/scripts/backup-postgres.sh >> /home/alejandroa/Proyectos/Kronos_Bot/logs/backup.log 2>&1
#
# Retención: se guardan los últimos 30 dumps diarios, se borran los
# más viejos automáticamente.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
BACKUP_DIR="${REPO_ROOT}/backups/postgres"
RETENTION_DAYS=30

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No se encontró $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

CONTAINER="$(docker compose -f "${REPO_ROOT}/docker-compose.yml" ps -q postgres)"
if [[ -z "$CONTAINER" ]]; then
  echo "No se encontró el contenedor de postgres corriendo."
  exit 1
fi

mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_FILE="${BACKUP_DIR}/kronos_bot-${TIMESTAMP}.sql.gz"

# pg_dump corre DENTRO del contenedor (mismo usuario/rol que ya tiene
# acceso vía trust local, ver pg_hba.conf) y se comprime al vuelo antes
# de tocar disco del host.
docker exec "$CONTAINER" pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" | gzip > "$OUT_FILE"

if [[ ! -s "$OUT_FILE" ]]; then
  echo "El dump salió vacío — algo falló. Borrando archivo parcial."
  rm -f "$OUT_FILE"
  exit 1
fi

echo "Backup OK: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"

# Retención: borra dumps de más de RETENTION_DAYS días.
find "$BACKUP_DIR" -name 'kronos_bot-*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete -print | while read -r old; do
  echo "Borrado por retención (>${RETENTION_DAYS}d): $old"
done
