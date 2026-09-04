#!/usr/bin/env bash
#
# deploy-nginx.sh
# Sets up nginx as a TLS-terminating reverse proxy with a realistic decoy
# website, falling back to xhttp/VLESS on a randomized secret path.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/unnk2004/<repo>/main/deploy-nginx.sh | bash
# or
#   bash deploy-nginx.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Must run as root
# ---------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root (sudo bash deploy-nginx.sh)" >&2
    exit 1
fi

REPO_RAW_BASE="https://raw.githubusercontent.com/unnk2004/decoy-nginx-site/main/site"
XRAY_PORT="12345"

# ---------------------------------------------------------------------------
# 1. Ask for the domain
# ---------------------------------------------------------------------------
echo "=================================================="
echo " nginx + xhttp reverse proxy deploy"
echo "=================================================="
read -rp "Domain (e.g. de.skynets.uk): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "Domain cannot be empty." >&2
    exit 1
fi

CERT_DIR="/root/cert/${DOMAIN}"
WEBROOT="/var/www/${DOMAIN}"

if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
    echo
    echo "WARNING: certificates not found at:"
    echo "  ${CERT_DIR}/fullchain.pem"
    echo "  ${CERT_DIR}/privkey.pem"
    read -rp "Continue anyway? (y/N): " CONT
    if [[ "$CONT" != "y" && "$CONT" != "Y" ]]; then
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 2. Generate a realistic, non-obvious secret path for the proxy
#    e.g. /api/v2/edge/sync-7f2a
# ---------------------------------------------------------------------------
RAND_HEX=$(head -c4 /dev/urandom | xxd -p)
SECRET_PATHS=("api/v2/edge/sync" "api/v1/collector/ingest" "api/v2/agent/poll" "api/internal/telemetry/push" "api/v2/probe/checkin")
SECRET_BASE=${SECRET_PATHS[$RANDOM % ${#SECRET_PATHS[@]}]}
PROXY_PATH="/${SECRET_BASE}-${RAND_HEX}"

echo
echo "Generated proxy path: ${PROXY_PATH}"
echo "(Use this as the xhttp 'path' in your Xray/3x-ui inbound config)"
echo

# ---------------------------------------------------------------------------
# 3. Install nginx if missing
# ---------------------------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1; then
    echo "nginx not found — installing..."
    apt-get update -y
    apt-get install -y nginx
else
    echo "nginx already installed: $(nginx -v 2>&1)"
fi

systemctl enable nginx >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3b. Detect nginx version to pick the right http2 syntax
#     http2 >= 1.25.1  -> standalone "http2 on;" directive
#     http2 <  1.25.1  -> combined "listen ... ssl http2;" syntax
# ---------------------------------------------------------------------------
NGINX_VERSION=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
USE_NEW_HTTP2_SYNTAX=false
if [[ -n "$NGINX_VERSION" ]]; then
    IFS='.' read -r NV_MAJOR NV_MINOR NV_PATCH <<< "$NGINX_VERSION"
    # Compare to 1.25.1
    if (( NV_MAJOR > 1 )) || \
       { (( NV_MAJOR == 1 )) && (( NV_MINOR > 25 )); } || \
       { (( NV_MAJOR == 1 )) && (( NV_MINOR == 25 )) && (( NV_PATCH >= 1 )); }; then
        USE_NEW_HTTP2_SYNTAX=true
    fi
fi
echo "Detected nginx version: ${NGINX_VERSION:-unknown} (new http2 syntax: ${USE_NEW_HTTP2_SYNTAX})"

# ---------------------------------------------------------------------------
# 4. Back up and wipe existing nginx site configuration
#    NOTE: copy the *contents* of /etc/nginx into BACKUP_DIR (trailing /.)
#    so BACKUP_DIR itself mirrors /etc/nginx directly — no extra nesting.
# ---------------------------------------------------------------------------
BACKUP_DIR="/root/nginx-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/nginx/. "$BACKUP_DIR"/ 2>/dev/null || true
echo "Full backup of /etc/nginx saved to: $BACKUP_DIR"

rm -f /etc/nginx/sites-enabled/*
rm -f /etc/nginx/sites-available/*
mkdir -p /etc/nginx/conf.d
rm -f /etc/nginx/conf.d/*.conf

# ---------------------------------------------------------------------------
# 5. Hide nginx version / fingerprint
# ---------------------------------------------------------------------------
if grep -q "server_tokens" /etc/nginx/nginx.conf; then
    sed -i 's/server_tokens.*/server_tokens off;/' /etc/nginx/nginx.conf
else
    sed -i '/http {/a \    server_tokens off;' /etc/nginx/nginx.conf
fi

# ---------------------------------------------------------------------------
# 6. Download the decoy website from GitHub
# ---------------------------------------------------------------------------
mkdir -p "$WEBROOT"
echo "Downloading decoy site pages..."

PAGES=(
    "index.html" "pricing.html" "docs.html" "status.html"
    "about.html" "blog.html" "careers.html"
    "privacy.html" "terms.html" "imprint.html"
    "styles.css" "404.html" "robots.txt"
)

for page in "${PAGES[@]}"; do
    if curl -fsSL "${REPO_RAW_BASE}/${page}" -o "${WEBROOT}/${page}"; then
        echo "  fetched ${page}"
    else
        echo "  WARNING: failed to fetch ${page} (continuing)"
    fi
done

# Substitute the real domain into robots.txt
if [[ -f "${WEBROOT}/robots.txt" ]]; then
    sed -i "s/__DOMAIN__/${DOMAIN}/g" "${WEBROOT}/robots.txt"
fi

# Minimal fallback if download failed entirely (no network / repo unreachable)
if [[ ! -f "${WEBROOT}/index.html" ]]; then
    echo "  Falling back to a minimal placeholder page."
    cat > "${WEBROOT}/index.html" <<'EOF'
<!DOCTYPE html><html><head><title>Pulsewatch</title></head>
<body><h1>Pulsewatch</h1><p>Infrastructure monitoring.</p></body></html>
EOF
fi

# ---------------------------------------------------------------------------
# 7. Write the nginx server block
# ---------------------------------------------------------------------------
CONF_FILE="/etc/nginx/sites-available/${DOMAIN}.conf"

if [[ "$USE_NEW_HTTP2_SYNTAX" == "true" ]]; then
    LISTEN_443_BLOCK="    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;"
else
    LISTEN_443_BLOCK="    listen 443 ssl http2;
    listen [::]:443 ssl http2;"
fi

cat > "$CONF_FILE" <<EOF
# Redirect plain HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
${LISTEN_443_BLOCK}
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    root ${WEBROOT};
    index index.html;

    # Custom error page so a 404 looks like part of the site, not nginx's default
    error_page 404 /404.html;
    location = /404.html {
        internal;
    }

    # Hide common probe targets some scanners check by default
    location ~ /\.(git|env|htaccess) {
        deny all;
        return 404;
    }

    location = /robots.txt {
        try_files \$uri =404;
    }

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    # Static site — looks and behaves like an ordinary marketing site
    location / {
        try_files \$uri \$uri.html \$uri/ =404;
    }

    # xhttp / VLESS reverse proxy on a randomized, non-obvious path
    location ${PROXY_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_PORT};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # xhttp requires no buffering and long-lived connections
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        proxy_connect_timeout 60s;
        proxy_send_timeout 1h;
        proxy_read_timeout 1h;

        client_max_body_size 0;
    }
}
EOF

ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

# ---------------------------------------------------------------------------
# 8. Test and reload
#    NOTE: restore by copying BACKUP_DIR's *contents* back into /etc/nginx
#    (trailing /.) to match how the backup was taken in step 4 — avoids the
#    double-nesting bug that left /etc/nginx/nginx.conf missing.
# ---------------------------------------------------------------------------
echo
echo "Testing nginx configuration..."
if nginx -t; then
    systemctl reload nginx
    echo "nginx reloaded successfully."
else
    echo "nginx config test FAILED — restoring previous configuration."
    rm -rf /etc/nginx
    mkdir -p /etc/nginx
    cp -r "$BACKUP_DIR"/. /etc/nginx/
    nginx -t && systemctl reload nginx
    exit 1
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo
echo "=================================================="
echo " Done."
echo "=================================================="
echo " Domain:        https://${DOMAIN}/"
echo " Decoy site:    ${WEBROOT}"
echo " Proxy path:    ${PROXY_PATH}  -->  127.0.0.1:${XRAY_PORT}"
echo " Config file:   ${CONF_FILE}"
echo " Backup of old config: ${BACKUP_DIR}"
echo
echo " >>> Update your Xray/3x-ui xhttp inbound 'path' setting to: ${PROXY_PATH}"
echo " >>> Make sure that inbound's 'host' is set to: ${DOMAIN}"
echo " >>> Make sure that inbound's 'security' is set to: none (TLS terminates at nginx)"
echo "=================================================="
