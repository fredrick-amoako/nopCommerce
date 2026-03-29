#!/bin/bash
# =============================================================================
# nopCommerce Backup Script
# Backs up the database and Docker volumes. Optionally uploads to S3.
# Run manually or via cron: 0 2 * * * /opt/nopcommerce/deploy/backup.sh
# =============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
readonly BACKUP_DIR="${PROJECT_DIR}/backups"
readonly DATE=$(date +%Y%m%d_%H%M%S)
readonly RETENTION_DAYS=7

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# Load environment variables
[[ -f "${PROJECT_DIR}/.env" ]] || die ".env file not found at ${PROJECT_DIR}/.env"
set -a; source "${PROJECT_DIR}/.env"; set +a

S3_BUCKET="${S3_BUCKET:-}"

mkdir -p "${BACKUP_DIR}"

log "=== Starting Backup: ${DATE} ==="

# -----------------------------------------------------------------------------
# 1. Database backup (SQL Server native backup)
# -----------------------------------------------------------------------------
log "Backing up database..."

# Create backup directory inside container
docker exec nopcommerce_db mkdir -p /var/opt/mssql/backup 2>/dev/null || true

# Try native SQL backup first (preferred)
if docker exec nopcommerce_db /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "${DB_PASSWORD}" \
    -Q "BACKUP DATABASE [nopCommerce] TO DISK = N'/var/opt/mssql/backup/nopCommerce_${DATE}.bak'" \
    -C -b 2>/dev/null; then
    log "✓ Database backup created (native SQL backup with compression)"

    # Copy the .bak file out of the container
    docker cp nopcommerce_db:/var/opt/mssql/backup/nopCommerce_${DATE}.bak \
        "${BACKUP_DIR}/nopCommerce_${DATE}.bak" 2>/dev/null || true

    # Clean up inside container (keep only last 3)
    docker exec nopcommerce_db bash -c \
        'ls -t /var/opt/mssql/backup/*.bak 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null' || true
else
    log "⚠ Native SQL backup failed (sqlcmd not available). Will use volume backup."
fi

# -----------------------------------------------------------------------------
# 2. Volume backup (compressed tar of all Docker volumes)
# -----------------------------------------------------------------------------
log "Creating compressed backup of Docker volumes..."

docker run --rm \
    -v nopcommerce_app_data:/data/app_data:ro \
    -v nopcommerce_plugins:/data/plugins:ro \
    -v nopcommerce_images:/data/images:ro \
    -v nopcommerce_logs:/data/logs:ro \
    -v nopcommerce_mssql_data:/data/mssql:ro \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar -czf "/backup/nopcommerce_volumes_${DATE}.tar.gz" -C /data .

BACKUP_SIZE=$(du -sh "${BACKUP_DIR}/nopcommerce_volumes_${DATE}.tar.gz" | cut -f1)
log "✓ Volume backup created: ${BACKUP_SIZE}"

# -----------------------------------------------------------------------------
# 3. Upload to S3 (if configured)
# -----------------------------------------------------------------------------
if [[ -n "${S3_BUCKET}" ]]; then
    log "Uploading backups to S3: s3://${S3_BUCKET}/backups/..."

    if command -v aws >/dev/null 2>&1; then
        aws s3 cp "${BACKUP_DIR}/nopcommerce_volumes_${DATE}.tar.gz" \
            "s3://${S3_BUCKET}/backups/" --quiet

        # Upload .bak file too if it exists
        if [[ -f "${BACKUP_DIR}/nopCommerce_${DATE}.bak" ]]; then
            aws s3 cp "${BACKUP_DIR}/nopCommerce_${DATE}.bak" \
                "s3://${S3_BUCKET}/backups/" --quiet
        fi

        log "✓ Uploaded to S3"
    else
        log "⚠ AWS CLI not installed. Skipping S3 upload."
    fi
else
    log "ℹ S3_BUCKET not set. Backups stored locally only."
fi

# -----------------------------------------------------------------------------
# 4. Clean up old local backups
# -----------------------------------------------------------------------------
deleted=$(find "${BACKUP_DIR}" -name "*.tar.gz" -o -name "*.bak" -mtime +${RETENTION_DAYS} | wc -l)
find "${BACKUP_DIR}" -name "*.tar.gz" -mtime +${RETENTION_DAYS} -delete
find "${BACKUP_DIR}" -name "*.bak" -mtime +${RETENTION_DAYS} -delete

if [[ "${deleted}" -gt 0 ]]; then
    log "Cleaned up ${deleted} backup(s) older than ${RETENTION_DAYS} days"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
total_size=$(du -sh "${BACKUP_DIR}" | cut -f1)
backup_count=$(find "${BACKUP_DIR}" -name "*.tar.gz" -o -name "*.bak" | wc -l)

log "=== Backup complete ==="
log "  Location: ${BACKUP_DIR}"
log "  Files:    ${backup_count} backup(s)"
log "  Size:     ${total_size} total"
