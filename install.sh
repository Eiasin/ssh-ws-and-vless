#!/bin/bash

# ═══════════════════════════════════════════════════════
#   SSH WebSocket VPN + VLESS Combined Auto Installer
# ═══════════════════════════════════════════════════════

clear
Red='\e[0;31m'
Green='\e[0;32m'
Yellow='\e[0;33m'
Cyan='\e[0;36m'
NC='\e[0m'

echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "   ${Yellow}SSH WS VPN + VLESS Combined Installer${NC}   "
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

while true; do
    read -rp " Domain (e.g. vpn.kanij.site): " DOMAIN
    [[ -n "$DOMAIN" ]] && break
    echo -e "${Red} Domain cannot be empty!${NC}"
done

read -rp " SSH WebSocket Port (default: 8080): " WS_PORT
WS_PORT=${WS_PORT:-8080}

read -rp " Cloudflare IP (default: 104.16.119.28): " CF_IP
CF_IP=${CF_IP:-104.16.119.28}

read -rp " VLESS Path (default: /ray): " VLESS_PATH
VLESS_PATH=${VLESS_PATH:-/ray}

read -rp " Xray Port (default: 10000): " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-10000}

while true; do
    read -rp " Email (SSL এর জন্য): " SSL_EMAIL
    [[ -n "$SSL_EMAIL" ]] && break
    echo -e "${Red} Email cannot be empty!${NC}"
done

UUID=$(cat /proc/sys/kernel/random/uuid)

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Yellow}তোমার তথ্য:${NC}"
echo -e " Domain      : $DOMAIN"
echo -e " SSH WS Port : $WS_PORT"
echo -e " CF IP       : $CF_IP"
echo -e " VLESS Path  : $VLESS_PATH"
echo -e " Xray Port   : $XRAY_PORT"
echo -e " Email       : $SSL_EMAIL"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -rp " সঠিক আছে? Install শুরু করবো? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && { echo -e "${Red} বাতিল!${NC}"; exit 1; }

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[1/8] System Update হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
apt update -y && apt upgrade -y
apt install -y curl wget git jq ufw nginx certbot python3-certbot-nginx python3
echo -e "${Green} ✅ System Update সম্পন্ন${NC}"

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[2/8] Xray (VLESS) Install হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install > /dev/null 2>&1

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": ""}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "$VLESS_PATH",
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
    echo -e "${Green} ✅ Xray চালু (port $XRAY_PORT)${NC}"
else
    echo -e "${Red} ❌ Xray চালু হয়নি!${NC}"
    exit 1
fi

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[3/8] SSH WebSocket Proxy তৈরি হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

cat > /usr/local/bin/ws-proxy.py << PYEOF
import socket, threading, select, time

def proxy(src, dst):
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [])
            if src in r:
                data = src.recv(4096)
                if not data: break
                dst.sendall(data)
            if dst in r:
                data = dst.recv(4096)
                if not data: break
                src.sendall(data)
    except: pass
    finally:
        src.close()
        dst.close()

def handle(client):
    try:
        req = client.recv(4096)
        if b"Upgrade: websocket" in req or b"Upgrade: Websocket" in req:
            client.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            ssh.connect(('127.0.0.1', 22))
            proxy(client, ssh)
    except: client.close()

def start_server(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', port))
    server.listen(100)
    while True:
        c, a = server.accept()
        threading.Thread(target=handle, args=(c,)).start()

PORT = $WS_PORT
threading.Thread(target=start_server, args=(PORT,), daemon=True).start()
while True:
    time.sleep(60)
PYEOF

cat > /etc/systemd/system/ws-proxy.service << SVCEOF
[Unit]
Description=SSH WebSocket Proxy
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable ws-proxy
systemctl start ws-proxy
sleep 2

if systemctl is-active --quiet ws-proxy; then
    echo -e "${Green} ✅ SSH WebSocket চালু (port $WS_PORT)${NC}"
else
    echo -e "${Red} ❌ SSH WebSocket চালু হয়নি!${NC}"
fi

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[4/8] SSH Password Auth Enable হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
echo -e "${Green} ✅ SSH Password Auth Enable${NC}"

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[5/8] SSL Certificate নেওয়া হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

rm -f /etc/nginx/sites-enabled/*
cat > /etc/nginx/sites-enabled/temp <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / { return 200 'ok'; }
}
EOF
nginx -t > /dev/null 2>&1
systemctl restart nginx

echo ""
echo -e "${Yellow} SSL নেওয়ার আগে নিশ্চিত করুন:${NC}"
echo -e "   1. $DOMAIN → Grey Cloud (DNS Only) করো"
echo -e "   2. Port 80 open আছে"
echo ""
read -rp " Grey Cloud set করা হয়েছে? (y/n): " DNS_READY

SSL_SUCCESS=false

if [[ "$DNS_READY" == "y" ]]; then
    certbot certonly --nginx -d "$DOMAIN" \
        --email "$SSL_EMAIL" \
        --agree-tos \
        --non-interactive 2>&1

    if [[ $? -eq 0 ]] && [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        echo -e "${Green} ✅ SSL Certificate সফল!${NC}"
        SSL_SUCCESS=true
    else
        echo -e "${Red} ❌ SSL ব্যর্থ!${NC}"
        read -rp " আবার চেষ্টা? (y/n): " RETRY
        if [[ "$RETRY" == "y" ]]; then
            certbot certonly --nginx -d "$DOMAIN" \
                --email "$SSL_EMAIL" \
                --agree-tos \
                --non-interactive 2>&1
            if [[ $? -eq 0 ]]; then
                SSL_SUCCESS=true
                echo -e "${Green} ✅ SSL Certificate সফল!${NC}"
            fi
        fi
    fi
fi

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[6/8] Nginx Config তৈরি হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

rm -f /etc/nginx/sites-enabled/*

if [[ "$SSL_SUCCESS" == "true" ]]; then
    cat > /etc/nginx/sites-enabled/vpn <<EOF
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
    location / {
        proxy_pass http://127.0.0.1:$WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_buffering off;
    }
    location $VLESS_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF
    CLIENT_PORT=443
    CLIENT_TLS=tls
    echo -e "${Green} ✅ Nginx SSL (443) Config সম্পন্ন${NC}"
else
    cat > /etc/nginx/sites-enabled/vpn <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_buffering off;
    }
    location $VLESS_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_buffering off;
    }
}
EOF
    CLIENT_PORT=80
    CLIENT_TLS=none
    echo -e "${Yellow} ⚠ Nginx HTTP (80) Config${NC}"
fi

nginx -t > /dev/null 2>&1
systemctl restart nginx

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[7/8] Firewall Configure হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 80/tcp > /dev/null 2>&1
ufw allow 443/tcp > /dev/null 2>&1
ufw allow $WS_PORT/tcp > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
echo -e "${Green} ✅ Firewall সম্পন্ন${NC}"

echo ""
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}[8/8] Scripts ও Config Save হচ্ছে...${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

cat > /etc/vless-config.conf <<EOF
DOMAIN=$DOMAIN
CF_IP=$CF_IP
WS_PATH=$VLESS_PATH
XRAY_PORT=$XRAY_PORT
CLIENT_PORT=$CLIENT_PORT
CLIENT_TLS=$CLIENT_TLS
WS_PORT=$WS_PORT
EOF

mkdir -p /root/vless-setup
curl -Ls https://raw.githubusercontent.com/Eiasin/vless-setup/main/generate-vless-link.sh -o /root/vless-setup/generate-vless-link.sh
chmod +x /root/vless-setup/generate-vless-link.sh

echo "admin:$UUID" >> /etc/xray-users.txt

cat > /usr/local/bin/ws << WSEOF
#!/bin/bash
clear
Cyan='\e[0;36m'
Yellow='\e[0;33m'
Green='\e[0;32m'
Red='\e[0;31m'
NC='\e[0m'
DOMAIN="$DOMAIN"
PORT="$WS_PORT"
echo -e "\${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e "       \${Yellow}CREATE SSH WS ACCOUNT\${NC}          "
echo -e "\${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
read -p " Username       : " Login
if id "\$Login" &>/dev/null; then
    echo -e "\${Red} Error: User already exists!\${NC}"
    exit 1
fi
read -p " Password       : " Pass
read -p " Expired (days) : " masaaktif
exp_date=\$(date -d "\$masaaktif days" +"%Y-%m-%d")
exp_display=\$(date -d "\$masaaktif days" +"%B %d, %Y")
useradd -e "\$exp_date" -s /bin/false -M "\$Login"
echo -e "\$Pass\n\$Pass" | passwd "\$Login" &> /dev/null
IP=\$(curl -sS ifconfig.me)
clear
echo -e "\${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e "         \${Yellow}SSH WS VPN ACCOUNT\${NC}             "
echo -e "\${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e " Username    : \$Login"
echo -e " Password    : \$Pass"
echo -e " Expired On  : \$exp_display"
echo -e "\${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e " IP          : \$IP"
echo -e " Host        : \$DOMAIN"
echo -e " OpenSSH     : 22"
echo -e " SSH WS Port : \$PORT"
echo -e "\${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e " \${Green}DarkTunnel Proxy Mode:\${NC}"
echo -e " Target  : \$DOMAIN:443"
echo -e " Proxy   : যেকোনো CDN proxy:80"
echo -e " Payload : GET / HTTP/1.1[crlf]Host: \$DOMAIN[crlf]Upgrade: websocket[crlf][crlf]"
echo -e "\${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
read -n 1 -s
WSEOF

chmod +x /usr/local/bin/ws
echo -e "${Green} ✅ Scripts সম্পন্ন${NC}"

ENCODED_PATH=$(echo -n "$VLESS_PATH" | sed 's|/|%2F|g')
if [[ "$CLIENT_TLS" == "tls" ]]; then
    VLESS_LINK="vless://$UUID@$CF_IP:443?path=$ENCODED_PATH&host=$DOMAIN&type=ws&security=tls&sni=$DOMAIN&encryption=none#$DOMAIN"
else
    VLESS_LINK="vless://$UUID@$CF_IP:80?path=$ENCODED_PATH&host=$DOMAIN&type=ws&encryption=none#$DOMAIN"
fi

IP=$(curl -sS ifconfig.me 2>/dev/null)
clear
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "   ${Green}✅ Installation Complete!${NC}   "
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " IP          : $IP"
echo -e " Host        : $DOMAIN"
echo -e " OpenSSH     : 22"
echo -e " SSH WS Port : $WS_PORT"
echo -e " SSL         : $([ "$SSL_SUCCESS" == "true" ] && echo "✅ Active" || echo "❌ Not configured")"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Yellow}DarkTunnel (SSH WebSocket):${NC}"
echo -e " Target  : $DOMAIN:443"
echo -e " Proxy   : $CF_IP:80"
echo -e " Payload : GET / HTTP/1.1[crlf]Host: $DOMAIN[crlf]Upgrade: websocket[crlf][crlf]"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Yellow}VLESS Link (v2rayNG):${NC}"
echo -e " ${Green}$VLESS_LINK${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$SSL_SUCCESS" == "true" ]]; then
    echo -e " ${Yellow}Cloudflare:${NC}"
    echo -e "  1. DNS → Orange Cloud (Proxied)"
    echo -e "  2. SSL/TLS → Full"
    echo -e "  3. Network → WebSockets → ON"
else
    echo -e " ${Red}⚠ SSL configure হয়নি!${NC}"
    echo -e " certbot --nginx -d $DOMAIN --email $SSL_EMAIL --agree-tos --non-interactive"
fi
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${Green}SSH User: ws${NC}"
echo -e " ${Green}VLESS User: bash /root/vless-setup/generate-vless-link.sh${NC}"
echo -e "${Cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
