#!/bin/bash
# =============================================================================
# nopCommerce Container Health Monitor
# Multi-layer monitoring: Docker health, system resources, webhook alerts
# =============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
readonly COMPOSE_FILE="${PROJECT_DIR}/docker-compose.prod.yml"
readonly LOG_FILE="/var/log/nopcommerce-monitor.log"
readonly STATE_DIR="/var/lib/nopcommerce-monitor"
readonly STATE_FILE="${STATE_DIR}/last_alert_state"

# Load webhook URL from .env if available
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    # We use grep/sed to read WEBHOOK_URL instead of sourcing .env 
    # to avoid potential shell parsing issues with passwords/special chars
    WEBHOOK_URL=$(grep '^WEBHOOK_URL=' "${PROJECT_DIR}/.env" | cut -d '=' -f2- | tr -d '"' | tr -d "'")
fi
readonly WEBHOOK_URL="${WEBHOOK_URL:-}"

# Ensure log and state directories exist
sudo touch "$LOG_FILE"
sudo chown ubuntu:ubuntu "$LOG_FILE"
mkdir -p "$STATE_DIR"

# =============================================================================
# Logging Functions
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    log "ERROR: $*" >&2
}

# =============================================================================
# Alert Management (Prevents Spam)
# =============================================================================

can_send_alert() {
    local alert_type="$1"
    local cooldown_minutes="${2:-30}"  # Default 30 min cooldown

    local last_alert_file="${STATE_FILE}_${alert_type}"

    if [[ -f "$last_alert_file" ]]; then
        local last_alert_time=$(cat "$last_alert_file")
        local current_time=$(date +%s)
        local time_diff=$(( (current_time - last_alert_time) / 60 ))

        if [[ $time_diff -lt $cooldown_minutes ]]; then
            return 1  # Cannot send (in cooldown)
        fi
    fi

    return 0  # Can send
}

record_alert() {
    local alert_type="$1"
    date +%s > "${STATE_FILE}_${alert_type}"
}

# =============================================================================
# Notification Functions
# =============================================================================

send_discord_notification() {
    local title="$1"
    local message="$2"
    local color="${3:-15158332}"  # Default red
    local priority="${4:-warning}"

    [[ -z "$WEBHOOK_URL" ]] && return 0

    local hostname=$(hostname)
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local payload=$(cat <<EOF
{
    "embeds": [{
        "title": "$title",
        "description": "$message",
        "color": $color,
        "timestamp": "$timestamp",
        "footer": {"text": "Server: $hostname | Priority: $priority"}
    }]
}
EOF
)

    if curl -sf -X POST -H "Content-Type: application/json" \
        -d "$payload" "$WEBHOOK_URL" > /dev/null 2>&1; then
        log "Notification sent successfully: $title"
        return 0
    else
        log_error "Failed to send notification"
        return 1
    fi
}

send_alert() {
    local alert_type="$1"
    local message="$2"
    local priority="${3:-warning}"

    log "ALERT [$priority/$alert_type]: $message"

    # Check cooldown
    if ! can_send_alert "$alert_type" 30; then
        log "Alert $alert_type in cooldown period, skipping notification"
        return 0
    fi

    # Determine color based on priority
    local color="16776960"  # Yellow
    [[ "$priority" == "critical" ]] && color="15158332"  # Red
    [[ "$priority" == "info" ]] && color="3447003"       # Blue

    # Send notification
    if send_discord_notification "nopCommerce Health Alert" "$message" "$color" "$priority"; then      
        record_alert "$alert_type"
    fi
}

# =============================================================================
# Health Check Functions
# =============================================================================

check_docker_containers() {
    local issues=0

    # Check if docker-compose file exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "Docker compose file not found: $COMPOSE_FILE"
        return 1
    fi

    # Check nopCommerce app container
    if ! docker compose -f "$COMPOSE_FILE" ps --format "{{.Status}}" | grep -q "Up"; then        
        send_alert "container_app" "nopCommerce container is NOT RUNNING!" "critical"
        issues=$((issues + 1))
    else
        # Check health status
        local app_health=$(docker inspect --format='{{.State.Health.Status}}' nopcommerce_app 2>/dev/null || echo "unknown")
        if [[ "$app_health" == "unhealthy" ]]; then
            send_alert "container_app_health" "nopCommerce health status: $app_health (site check failed)" "warning"
            issues=$((issues + 1))
        fi
    fi

    # Check database container
    if ! docker compose -f "$COMPOSE_FILE" ps --format "{{.Status}}" | grep -q "Up"; then
        send_alert "container_db" "Database container is NOT RUNNING!" "critical"
        issues=$((issues + 1))
    else
        local db_health=$(docker inspect --format='{{.State.Health.Status}}' nopcommerce_db 2>/dev/null || echo "unknown")
        if [[ "$db_health" == "unhealthy" ]]; then
            send_alert "container_db_health" "Database health status: $db_health (SQL logs check failed)" "critical"
            issues=$((issues + 1))
        fi
    fi

    return $issues
}

check_disk_space() {
    local usage=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
    local priority="warning"

    if [[ "$usage" -gt 95 ]]; then
        priority="critical"
        send_alert "disk_space" "Disk usage is at ${usage}% - CRITICAL! Server may freeze soon." "$priority"
    elif [[ "$usage" -gt 85 ]]; then
        send_alert "disk_space" "Disk usage is at ${usage}% - consider cleaning docker logs/images." "$priority"
    fi
}

check_memory() {
    # Calculate memory usage percentage
    local mem_info=$(free | grep Mem)
    local mem_total=$(echo "$mem_info" | awk '{print $2}')
    local mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_pct=$(( mem_used * 100 / mem_total ))

    if [[ "$mem_pct" -gt 95 ]]; then
        send_alert "memory" "Memory usage is at ${mem_pct}% - CRITICAL! OOM killer may trigger." "critical"
    elif [[ "$mem_pct" -gt 90 ]]; then
        send_alert "memory" "Memory usage is at ${mem_pct}% - High swapped/used RAM detected." "warning"
    fi
}

check_application_response() {
    # Quick internal check if the app is responding to HTTP
    if ! curl -sf http://localhost:5000/health > /dev/null 2>&1; then
        send_alert "app_response" "Internal health check (localhost:5000/health) failed!" "warning"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    log "=== Starting health check ==="

    local exit_code=0

    check_docker_containers || exit_code=1
    check_disk_space
    check_memory
    check_application_response

    if [[ $exit_code -eq 0 ]]; then
        log "=== Health check completed - all systems normal ==="
    else
        log "=== Health check completed - ISSUES DETECTED ==="
    fi

    return $exit_code
}

# Run main function
main "$@"
