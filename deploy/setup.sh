#!/bin/bash
# =============================================================================
# nopCommerce Initial Setup Script
# Run this ONCE after deploying the EC2 instance to configure Nginx and SSL.
# =============================================================================
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
log "=== nopCommerce Setup Script ==="

[[ $EUID -eq 0 ]] && die "Do not run this script as root. Use a regular user with sudo."
command -v nginx >/dev/null 2>&1 || die "Nginx not installed. Wait for EC2 UserData to finish."
command -v docker >/dev/null 2>&1 || die "Docker not installed. Wait for EC2 UserData to finish."

# Check .env file exists
[[ -f "${PROJECT_DIR}/.env" ]] || {
    log "No .env file found. Creating from .env.example..."
    if [[ -f "${PROJECT_DIR}/.env.example" ]]; then
        cp "${PROJECT_DIR}/.env.example" "${PROJECT_DIR}/.env"
        chmod 600 "${PROJECT_DIR}/.env"
        log "WARNING: .env created from template. Edit it with a STRONG password before deploying!"
        log "  nano ${PROJECT_DIR}/.env"
        exit 1
    else
        die ".env.example not found either. Cannot continue."
    fi
}

# -----------------------------------------------------------------------------
# Generate self-signed SSL certificate (for initial HTTPS before Let's Encrypt)
# -----------------------------------------------------------------------------
log "Generating self-signed SSL certificate..."
sudo mkdir -p /etc/ssl/private
if [[ ! -f /etc/ssl/certs/nginx-selfsigned.crt ]]; then
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/nginx-selfsigned.key \
        -out /etc/ssl/certs/nginx-selfsigned.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost" 2>/dev/null
    log "Self-signed certificate created."
else
    log "Self-signed certificate already exists. Skipping."
fi

# -----------------------------------------------------------------------------
# Create Nginx configuration
# -----------------------------------------------------------------------------
log "Creating Nginx configuration..."
sudo mkdir -p /var/www/certbot

sudo tee /etc/nginx/sites-available/nopcommerce > /dev/null <<'NGINX_CONF'
upstream nopcommerce {
    server 127.0.0.1:5000;
}

# HTTP - Redirect to HTTPS
server {
    listen 80;
    server_name _;

    # Allow Let's Encrypt validation
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect everything else to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS - Main application
server {
    listen 443 ssl http2;
    server_name _;

    # SSL Configuration (self-signed initially, replaced by Let's Encrypt)
    ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;

    # SSL Security settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    # Client body size (for file uploads in nopCommerce admin)
    client_max_body_size 50m;

    # Proxy to nopCommerce
    location / {
        proxy_pass http://nopcommerce;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Accept-Encoding ""; # Force uncompressed HTML so sub_filter works
        proxy_cache_bypass $http_upgrade;

        # Rewrite http:// to https:// in response bodies (fixes mixed content images)
        sub_filter "http://$host" "https://$host";
        sub_filter_once off;
        sub_filter_types text/html;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Static file caching
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://nopcommerce;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        expires 30d;
        add_header Cache-Control "public, immutable";
        # Re-declare security headers (Nginx doesn't inherit add_header into nested blocks)
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
    }
}
NGINX_CONF

# Enable site, disable default
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/nopcommerce /etc/nginx/sites-enabled/

# -----------------------------------------------------------------------------
# Test and reload Nginx
# -----------------------------------------------------------------------------
log "Testing Nginx configuration..."
sudo nginx -t || die "Nginx config test failed!"
sudo systemctl reload nginx

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
PUBLIC_IP=$(curl -sf https://checkip.amazonaws.com 2>/dev/null || echo "<unknown>")

log "=== Setup complete ==="
log ""
log "Next steps:"
log "  1. Deploy containers:  ./deploy.sh"
log "  2. Open browser:       https://${PUBLIC_IP}"
log "     (You'll see a certificate warning - that's expected)"
log "  3. Complete the install wizard to configure the database"
log "  4. Setup real SSL:     ./setup-ssl.sh"
