#!/bin/bash
# =============================================================================
# nopCommerce Deploy Script
# Builds and starts all Docker containers using docker-compose.prod.yml.
# Safe to run multiple times (idempotent).
# =============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
readonly COMPOSE_FILE="${PROJECT_DIR}/docker-compose.prod.yml"
readonly MAX_WAIT=120  # seconds to wait for healthy containers

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
log "=== Deploying nopCommerce ==="

[[ -f "${COMPOSE_FILE}" ]] || die "docker-compose.prod.yml not found at ${COMPOSE_FILE}"
[[ -f "${PROJECT_DIR}/.env" ]] || die ".env file not found. Run: cp .env.example .env && nano .env"
command -v docker >/dev/null 2>&1 || die "Docker not installed"

# Validate .env has a real password
source "${PROJECT_DIR}/.env"
if [[ "${POSTGRES_PASSWORD:-}" == "ChangeMe!Strong123" ]] || [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    die "Change the POSTGRES_PASSWORD in .env before deploying! Current password is the default or empty."
fi

# -----------------------------------------------------------------------------
# Build and deploy
# -----------------------------------------------------------------------------
cd "${PROJECT_DIR}"

log "Stopping existing containers (if any)..."
docker compose -f docker-compose.prod.yml down --timeout 30 2>/dev/null || true

log "Building and starting containers..."
docker compose -f docker-compose.prod.yml up --build -d

# -----------------------------------------------------------------------------
# Wait for services to become healthy
# -----------------------------------------------------------------------------
log "Waiting for services to become healthy (max ${MAX_WAIT}s)..."
elapsed=0
interval=5

while [[ $elapsed -lt $MAX_WAIT ]]; do
    # Check if both containers are running
    running=$(docker compose -f docker-compose.prod.yml ps --status running --format json 2>/dev/null | wc -l || echo "0")

    if [[ "$running" -ge 2 ]]; then
        # Check if DB is healthy
        db_health=$(docker inspect --format='{{.State.Health.Status}}' nopcommerce_db 2>/dev/null || echo "unknown")

        if [[ "$db_health" == "healthy" ]]; then
            log "✓ Database is healthy"

            # Check if app is responding
            app_health=$(docker inspect --format='{{.State.Health.Status}}' nopcommerce_app 2>/dev/null || echo "unknown")
            if [[ "$app_health" == "healthy" ]]; then
                log "✓ Application is healthy"
                break
            elif [[ "$app_health" == "starting" ]]; then
                log "  App starting... (${elapsed}s/${MAX_WAIT}s)"
            fi
        else
            log "  DB status: ${db_health} (${elapsed}s/${MAX_WAIT}s)"
        fi
    else
        log "  Waiting for containers to start... (${elapsed}s/${MAX_WAIT}s)"
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
done

# -----------------------------------------------------------------------------
# Final status
# -----------------------------------------------------------------------------
echo ""
log "=== Container Status ==="
docker compose -f docker-compose.prod.yml ps

echo ""
PUBLIC_IP=$(curl -sf https://checkip.amazonaws.com 2>/dev/null || echo "<elastic-ip>")

# Check final state
app_status=$(docker inspect --format='{{.State.Status}}' nopcommerce_app 2>/dev/null || echo "not found")

if [[ "$app_status" == "running" ]]; then
    log "✓ Deployment successful!"
    log ""
    log "Website: https://${PUBLIC_IP}"
    log ""
    log "If this is a fresh install, complete the nopCommerce install wizard:"
    log "  1. Open https://${PUBLIC_IP} in your browser"
    log "  2. Select 'PostgreSQL'"
    log "  3. Server Name: nopcommerce_db"
    log "  4. Database / Username: nopcommerce"
    log "  5. Password: ${POSTGRES_PASSWORD}"
    log "  6. Click Install"
else
    log "✗ Deployment may have issues. Container status: ${app_status}"
    log ""
    log "Check logs with:"
    log "  docker compose -f docker-compose.prod.yml logs nopcommerce"
    log "  docker compose -f docker-compose.prod.yml logs db"
    exit 1
fi
