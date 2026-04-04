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

# PostgreSQL backup using pg_dump
if docker exec nopcommerce_db pg_dump -U "${POSTGRES_USER:-nopcommerce}" -d nopcommerce -F c -f "/tmp/nopCommerce_${DATE}.dump" 2>/dev/null; then
    log "✓ Database backup created (pg_dump custom format)"

    # Copy the .dump file out of the container
    docker cp "nopcommerce_db:/tmp/nopCommerce_${DATE}.dump" \
        "${BACKUP_DIR}/nopCommerce_${DATE}.dump" 2>/dev/null || true

    # Clean up inside container
    docker exec nopcommerce_db rm -f "/tmp/nopCommerce_${DATE}.dump" || true
else
    log "⚠ Native PostgreSQL backup failed. Will use volume backup."
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
    -v nopcommerce_postgres_data:/data/postgres:ro \
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

        # Upload .dump file too if it exists
        if [[ -f "${BACKUP_DIR}/nopCommerce_${DATE}.dump" ]]; then
            aws s3 cp "${BACKUP_DIR}/nopCommerce_${DATE}.dump" \
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
deleted=$(find "${BACKUP_DIR}" -name "*.tar.gz" -o -name "*.dump" -mtime +${RETENTION_DAYS} | wc -l)
find "${BACKUP_DIR}" -name "*.tar.gz" -mtime +${RETENTION_DAYS} -delete
find "${BACKUP_DIR}" -name "*.dump" -mtime +${RETENTION_DAYS} -delete

if [[ "${deleted}" -gt 0 ]]; then
    log "Cleaned up ${deleted} backup(s) older than ${RETENTION_DAYS} days"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
total_size=$(du -sh "${BACKUP_DIR}" | cut -f1)
backup_count=$(find "${BACKUP_DIR}" -name "*.tar.gz" -o -name "*.dump" | wc -l)

log "=== Backup complete ==="
log "  Location: ${BACKUP_DIR}"
log "  Files:    ${backup_count} backup(s)"
log "  Size:     ${total_size} total"
