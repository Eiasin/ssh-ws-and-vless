#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info()   { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()  { echo -e "${RED}[✗]${NC} $1"; }

clear
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}   VLESS + Cloudflare + SSL Auto Setup  ${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# ─── User Input ───────────────────────────────────────────────
while true; do
    read -rp "Domain (e.g., vpn2.kanij.site): " DOMAIN
    [[ -n "$DOMAIN" ]] && break
    print_error "Domain cannot be empty!"
done

read -rp "Cloudflare Proxy IP (default: 104.16.119.28): " CF_IP
CF_IP=${CF_IP:-104.16.119.28}

read -rp "WS Path (default: /ray): " WS_PATH
WS_PATH=${WS_PATH:-/ray}

read -rp "Xray Port (default: 10000): " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-10000}

while true; do
    read -rp "Email for SSL certificate: " SSL_EMAIL
    [[ -n "$SSL_EMAIL" ]] && break
    print_error "Email cannot be empty!"
done

UUID=$(cat /proc/sys/kernel/random/uuid)

echo ""
print_info "Domain:    $DOMAIN"
print_info "CF IP:     $CF_IP"
print_info "Path:      $WS_PATH"
print_info "Port:      $XRAY_PORT"
print_info "Email:     $SSL_EMAIL"
print_info "UUID:      $UUID"
echo ""

read -rp "Confirm setup? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && { print_error "Cancelled!"; exit 1; }

echo ""

# ─── Step 1: System Update ────────────────────────────────────
print_info "Updating system..."
apt update -y > /dev/null 2>&1
apt upgrade -y > /dev/null 2>&1
apt install -y curl wget git jq ufw > /dev/null 2>&1
print_status "System updated"

# ─── Step 2: Install Xray ─────────────────────────────────────
print_info "Installing Xray..."
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install > /dev/null 2>&1
print_status "Xray installed"

# ─── Step 3: Xray Config ──────────────────────────────────────
print_info "Configuring Xray..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$UUID", "flow": ""}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "$WS_PATH",
        "headers": { "Host": "$DOMAIN" }
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
EOF

systemctl enable xray > /dev/null 2>&1
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    print_status "Xray running on port $XRAY_PORT"
else
    print_error "Xray failed to start!"
    journalctl -u xray -n 10 --no-pager
    exit 1
fi

# ─── Step 4: Install Nginx ────────────────────────────────────
print_info "Installing Nginx..."
apt install -y nginx > /dev/null 2>&1
systemctl enable nginx > /dev/null 2>&1
rm -f /etc/nginx/sites-enabled/*

# ─── Step 5: Nginx HTTP config ────────────────────────────────
cat > /etc/nginx/sites-enabled/vless <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

nginx -t > /dev/null 2>&1
systemctl restart nginx
print_status "Nginx HTTP ready"

# ─── Step 6: SSL Certificate ──────────────────────────────────
echo ""
echo -e "${YELLOW}════════════════════════════════════════${NC}"
echo -e "${YELLOW}   SSL Certificate Setup${NC}"
echo -e "${YELLOW}════════════════════════════════════════${NC}"
echo ""
print_info "Before continuing, make sure:"
echo "  1. Cloudflare DNS → $DOMAIN → Grey Cloud (DNS Only)"
echo "  2. Port 80 is open"
echo ""
read -rp "Is DNS set to Grey Cloud? (y/n): " DNS_READY

SSL_SUCCESS=false

if [[ "$DNS_READY" == "y" ]]; then
    print_info "Installing certbot..."
    apt install -y certbot python3-certbot-nginx > /dev/null 2>&1
    
    print_info "Getting SSL certificate..."
    certbot --nginx -d "$DOMAIN" \
        --email "$SSL_EMAIL" \
        --agree-tos \
        --non-interactive \
        --redirect 2>&1

    if [[ $? -eq 0 ]] && [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        print_status "SSL certificate obtained!"
        SSL_SUCCESS=true
    else
        print_error "SSL failed! Check if:"
        echo "  1. Domain DNS is pointing to this server IP"
        echo "  2. Grey Cloud (DNS Only) is set in Cloudflare"
        echo "  3. Port 80 is open"
        echo ""
        read -rp "Try SSL again? (y/n): " RETRY
        if [[ "$RETRY" == "y" ]]; then
            certbot --nginx -d "$DOMAIN" \
                --email "$SSL_EMAIL" \
                --agree-tos \
                --non-interactive \
                --redirect 2>&1
            if [[ $? -eq 0 ]] && [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
                print_status "SSL certificate obtained!"
                SSL_SUCCESS=true
            else
                print_error "SSL failed again! Continuing with HTTP..."
            fi
        fi
    fi
fi

# ─── Step 7: Nginx Final Config ───────────────────────────────
rm -f /etc/nginx/sites-enabled/*

if [[ "$SSL_SUCCESS" == "true" ]]; then
    cat > /etc/nginx/sites-enabled/vless <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF
    CLIENT_PORT=443
    CLIENT_TLS=tls
    print_status "Nginx SSL (443) configured"
else
    cat > /etc/nginx/sites-enabled/vless <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF
    CLIENT_PORT=80
    CLIENT_TLS=none
    print_info "Using HTTP (80) - SSL was not configured"
fi

nginx -t > /dev/null 2>&1
systemctl restart nginx

# ─── Step 8: Firewall ─────────────────────────────────────────
print_info "Configuring firewall..."
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
print_status "Firewall configured"

# ─── Step 9: Save Config ──────────────────────────────────────
cat > /etc/vless-config.conf <<EOF
DOMAIN=$DOMAIN
CF_IP=$CF_IP
WS_PATH=$WS_PATH
XRAY_PORT=$XRAY_PORT
CLIENT_PORT=$CLIENT_PORT
CLIENT_TLS=$CLIENT_TLS
EOF

# ─── Step 10: Copy Scripts ────────────────────────────────────
print_info "Setting up management scripts..."
mkdir -p /root/vless-setup

# Download scripts from GitHub
curl -Ls https://raw.githubusercontent.com/Eiasin/vless-setup/main/generate-vless-link.sh -o /root/vless-setup/generate-vless-link.sh
curl -Ls https://raw.githubusercontent.com/Eiasin/vless-setup/main/add-vless-user.sh -o /root/vless-setup/add-vless-user.sh
chmod +x /root/vless-setup/*.sh
print_status "Scripts ready"

# ─── Step 11: Generate Link ───────────────────────────────────
ENCODED_PATH=$(echo -n "$WS_PATH" | sed 's|/|%2F|g')

if [[ "$CLIENT_TLS" == "tls" ]]; then
    VLESS_LINK="vless://$UUID@$CF_IP:443?path=$ENCODED_PATH&host=$DOMAIN&type=ws&security=tls&sni=$DOMAIN&encryption=none#$DOMAIN"
else
    VLESS_LINK="vless://$UUID@$CF_IP:80?path=$ENCODED_PATH&host=$DOMAIN&type=ws&encryption=none#$DOMAIN"
fi

# Save first user
echo "admin:$UUID" >> /etc/xray-users.txt

# ─── Done ─────────────────────────────────────────────────────
clear
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}        Setup Complete! ✓               ${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Server Info:${NC}"
echo "  Domain:  $DOMAIN"
echo "  Port:    $CLIENT_PORT"
echo "  TLS:     $CLIENT_TLS"
echo "  Path:    $WS_PATH"
echo "  UUID:    $UUID"
echo ""
echo -e "${YELLOW}VLESS Link:${NC}"
echo -e "${GREEN}$VLESS_LINK${NC}"
echo ""

if [[ "$CLIENT_TLS" == "tls" ]]; then
    echo -e "${YELLOW}Cloudflare Settings:${NC}"
    echo "  1. DNS → $DOMAIN → Orange Cloud (Proxied)"
    echo "  2. SSL/TLS → Full"
    echo "  3. Network → WebSockets → ON"
else
    echo -e "${RED}⚠ SSL was not configured!${NC}"
    echo "  Run this to get SSL manually:"
    echo "  certbot --nginx -d $DOMAIN --email $SSL_EMAIL --agree-tos --non-interactive"
    echo ""
    echo -e "${YELLOW}Cloudflare Settings:${NC}"
    echo "  1. DNS → $DOMAIN → Orange Cloud (Proxied)"
    echo "  2. SSL/TLS → Flexible"
    echo "  3. Network → WebSockets → ON"
fi

echo ""
echo -e "${YELLOW}User Manager:${NC}"
echo "  bash /root/vless-setup/generate-vless-link.sh"
echo ""
