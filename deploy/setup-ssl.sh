#!/bin/bash
# =============================================================================
# nopCommerce SSL Setup Script (Let's Encrypt)
# Obtains a real SSL certificate for your domain and configures Nginx.
# Requires: a domain name pointing to this server's IP.
# =============================================================================
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
log "=== Let's Encrypt SSL Setup ==="

command -v certbot >/dev/null 2>&1 || die "Certbot not installed. Run: sudo apt-get install -y certbot python3-certbot-nginx"
command -v nginx >/dev/null 2>&1 || die "Nginx not installed"

PUBLIC_IP=$(curl -sf https://checkip.amazonaws.com 2>/dev/null || echo "<unknown>")

log "Server IP: ${PUBLIC_IP}"
echo ""
echo "Let's Encrypt requires a domain name. If you don't have one:"
echo "  1. Get a free domain from https://www.duckdns.org or https://freedns.afraid.org"
echo "  2. Point it to this IP: ${PUBLIC_IP}"
echo "  3. Wait for DNS propagation (usually a few minutes)"
echo "  4. Run this script again"
echo ""

read -r -p "Enter your domain name (or press Enter to skip): " DOMAIN

if [[ -z "${DOMAIN}" ]]; then
    log "No domain provided. Keeping self-signed certificate."
    exit 0
fi

# Validate domain resolves to this IP
log "Checking that ${DOMAIN} resolves to ${PUBLIC_IP}..."
RESOLVED_IP=$(dig +short "${DOMAIN}" 2>/dev/null | tail -1 || echo "")

if [[ "${RESOLVED_IP}" != "${PUBLIC_IP}" ]]; then
    log "WARNING: ${DOMAIN} resolves to '${RESOLVED_IP}', not '${PUBLIC_IP}'"
    read -r -p "Continue anyway? (y/N): " CONTINUE
    [[ "${CONTINUE}" =~ ^[Yy]$ ]] || exit 1
fi

# -----------------------------------------------------------------------------
# Obtain SSL certificate
# -----------------------------------------------------------------------------
log "Creating webroot directory..."
sudo mkdir -p /var/www/certbot

read -r -p "Enter your email for certificate notifications: " EMAIL
[[ -n "${EMAIL}" ]] || EMAIL="admin@${DOMAIN}"

log "Obtaining SSL certificate for ${DOMAIN}..."
sudo certbot certonly \
    --webroot \
    -w /var/www/certbot \
    -d "${DOMAIN}" \
    --agree-tos \
    --non-interactive \
    --email "${EMAIL}" || die "Certbot failed. Check that port 80 is open and DNS is configured."

# -----------------------------------------------------------------------------
# Update Nginx with real certificate
# -----------------------------------------------------------------------------
log "Updating Nginx configuration..."

sudo tee /etc/nginx/sites-available/nopcommerce > /dev/null <<EOF
upstream nopcommerce {
    server 127.0.0.1:5000;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_stapling on;
    ssl_stapling_verify on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    client_max_body_size 50m;

    location / {
        proxy_pass http://nopcommerce;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Accept-Encoding ""; # Force uncompressed HTML so sub_filter works
        proxy_cache_bypass \$http_upgrade;

        # Rewrite http:// to https:// in response bodies (fixes mixed content images)
        sub_filter "http://\$host" "https://\$host";
        sub_filter_once off;
        sub_filter_types text/html;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://nopcommerce;
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
    }
}
EOF

# Test and reload
log "Testing Nginx configuration..."
sudo nginx -t || die "Nginx config test failed! Reverting..."
sudo systemctl reload nginx
log "✓ Nginx reloaded with Let's Encrypt certificate"

# -----------------------------------------------------------------------------
# Setup auto-renewal
# -----------------------------------------------------------------------------
log "Setting up automatic certificate renewal..."

# Create renewal hook to reload Nginx
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# Add cron job for renewal (if not already present)
if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -
    log "✓ Auto-renewal cron job added (runs daily at 3 AM)"
else
    log "Auto-renewal cron job already exists"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log "=== SSL setup complete ==="
log ""
log "Your site is now accessible at: https://${DOMAIN}"
log "Certificate auto-renews via cron before expiry."
