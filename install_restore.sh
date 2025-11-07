#!/usr/bin/env bash
# install_restore.sh — Cartenz VPN Premium (Konfigurasi-VPS-Baru)
# Restore & install semua layanan, issue TLS dua domain, start service, set auto-menu, reboot
# Dites: Ubuntu 20.04/22.04/24.04, Debian 11/12

set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ======== UI ========
C0='\033[0m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[34m'; C='\033[36m'; W='\033[97m'
log(){ echo -e "${C}[*]${C0} $*"; }
ok(){ echo -e "${G}[OK]${C0} $*"; }
warn(){ echo -e "${Y}[WARN]${C0} $*"; }
err(){ echo -e "${R}[ERR]${C0} $*" >&2; }

# ======== Guard & OS ========
[[ $EUID -eq 0 ]] || { err "Jalankan sebagai root"; exit 1; }
if [[ -f /etc/os-release ]]; then . /etc/os-release; ok "OS: $PRETTY_NAME"; fi

# ======== Path Repo ========
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="$REPO_ROOT/etc"
SCRIPT_DIR="$REPO_ROOT/scripts"
SYSTEMD_DIR="$REPO_ROOT/systemd"
PANEL_DIR="$REPO_ROOT/opt/cartenz-panel"
FIREWALL_DIR="$REPO_ROOT/firewall"
LOG_FILE="/root/log-install.txt"

# ======== Input ========
ask(){
  local p="$1" def="${2:-}" v;
  if [[ -n "${def}" ]]; then read -rp "$p [$def]: " v; v="${v:-$def}";
  else read -rp "$p: " v; fi
  echo "$v"
}
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
VPN_DOMAIN="${VPN_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

if [[ -z "$PANEL_DOMAIN" || -z "$VPN_DOMAIN" ]]; then
  echo -e "${W}=== Pengaturan Domain ===${C0}"
  [[ -z "$PANEL_DOMAIN" ]] && PANEL_DOMAIN="$(ask 'Domain Panel (mis: panel.cartenz-vpn.my.id)')"
  [[ -z "$VPN_DOMAIN"   ]] && VPN_DOMAIN="$(ask 'Domain VPN (mis: vpn.cartenz-vpn.my.id)')"
fi
[[ -z "$CERTBOT_EMAIL" ]] && CERTBOT_EMAIL="$(ask "Email Certbot" "admin@${VPN_DOMAIN}")"

ok "Panel domain: $PANEL_DOMAIN"
ok "VPN domain  : $VPN_DOMAIN"
ok "Email       : $CERTBOT_EMAIL"

# ======== Util ========
aptx(){ apt-get update -y; apt-get install -y --no-install-recommends "$@"; }
enable_and_start(){
  local svc="$1"
  systemctl daemon-reload
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc" || systemctl start "$svc" || true
  if systemctl is-active --quiet "$svc"; then ok "Service $svc aktif"; else err "Service $svc TIDAK aktif"; fi
}

# ======== Paket dasar ========
log "Install paket dasar…"
aptx ca-certificates curl wget gnupg lsb-release jq git unzip tar sudo ufw socat rsync net-tools openssl \
    nginx dropbear stunnel4 certbot python3-certbot-nginx nodejs npm

# ======== NGINX bootstrap untuk HTTP-01 ========
log "Siapkan nginx bootstrap (80) untuk validasi ACME…"
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html
cat >/etc/nginx/sites-available/cartenz-bootstrap.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PANEL_DOMAIN $VPN_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 200 "Cartenz bootstrap OK\n"; }
}
EOF
ln -sf /etc/nginx/sites-available/cartenz-bootstrap.conf /etc/nginx/sites-enabled/cartenz-bootstrap.conf
rm -f /etc/nginx/sites-enabled/default || true
nginx -t && enable_and_start nginx

# ======== Dropbear ========
log "Konfigurasi Dropbear…"
if [[ -f /etc/default/dropbear ]]; then
  sed -i 's/^NO_START=.*/NO_START=0/' /etc/default/dropbear || true
  if grep -q '^DROPBEAR_PORT=' /etc/default/dropbear; then
    sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=109/' /etc/default/dropbear
  else
    echo "DROPBEAR_PORT=109" >> /etc/default/dropbear
  fi
else
  cat >/etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=109
DROPBEAR_EXTRA_ARGS="-w"
EOF
fi
enable_and_start dropbear

# ======== Stunnel ========
log "Konfigurasi Stunnel…"
mkdir -p /etc/stunnel
if [[ -f "$ETC_DIR/stunnel/stunnel.conf" ]]; then
  cp -f "$ETC_DIR/stunnel/stunnel.conf" /etc/stunnel/stunnel.conf
else
  cat >/etc/stunnel/stunnel.conf <<EOF
foreground = yes
pid = /var/run/stunnel4/stunnel.pid
[stunnel-ssh]
accept = 443
connect = 127.0.0.1:22
cert = /etc/letsencrypt/live/$VPN_DOMAIN/fullchain.pem
key  = /etc/letsencrypt/live/$VPN_DOMAIN/privkey.pem
EOF
fi
sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 || true

# ======== Xray ========
log "Install & setup Xray…"
if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
fi
mkdir -p /etc/xray
echo "$VPN_DOMAIN" >/etc/xray/domain
echo "$VPN_DOMAIN" >/etc/xray/scdomain 2>/dev/null || true
ln -sf "/etc/letsencrypt/live/$VPN_DOMAIN/fullchain.pem" "/etc/xray/xray.crt" || true
ln -sf "/etc/letsencrypt/live/$VPN_DOMAIN/privkey.pem"  "/etc/xray/xray.key" || true
if [[ -f "$ETC_DIR/xray/config.json" ]]; then
  cp -f "$ETC_DIR/xray/config.json" /etc/xray/config.json
  sed -i "s/sgdo\.anya-vpn\.my\.id/$VPN_DOMAIN/g" /etc/xray/config.json || true
  sed -i "s/domain_placeholder/$VPN_DOMAIN/g" /etc/xray/config.json || true
else
  warn "etc/xray/config.json tidak ditemukan — gunakan bawaan installer bila ada."
  [[ -f /usr/local/etc/xray/config.json ]] && cp -f /usr/local/etc/xray/config.json /etc/xray/config.json || true
fi
[[ -f "$SYSTEMD_DIR/xray.service" ]] && cp -f "$SYSTEMD_DIR/xray.service" /etc/systemd/system/xray.service

# ======== Certbot dua domain (standalone) ========
log "Issue sertifikat TLS untuk Panel & VPN…"
systemctl stop nginx xray stunnel4 || true
sleep 1
certbot certonly --standalone -d "$PANEL_DOMAIN" -d "$VPN_DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n || warn "Certbot gagal — bisa coba ulang manual"
systemctl start nginx stunnel4 || true

# ======== NGINX Xray & Panel ========
log "Terapkan konfigurasi NGINX (Xray & Panel)…"
mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled

# Xray vhost
if [[ -f "$ETC_DIR/nginx/conf.d/xray.conf" ]]; then
  cp -f "$ETC_DIR/nginx/conf.d/xray.conf" /etc/nginx/conf.d/xray.conf
  sed -i "s/sgdo\.anya-vpn\.my\.id/$VPN_DOMAIN/g" /etc/nginx/conf.d/xray.conf || true
  sed -i "s/server_name .*/server_name $VPN_DOMAIN *.$VPN_DOMAIN;/" /etc/nginx/conf.d/xray.conf || true
else
  cat >/etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 http2;
    server_name $VPN_DOMAIN *.$VPN_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$VPN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$VPN_DOMAIN/privkey.pem;

    location /vmess {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location /vless {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location /trojan-ws {
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location /ss-ws {
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
fi

# Panel vhost
cat >/etc/nginx/sites-available/cartenz-panel.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 http2;
    server_name $PANEL_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
ln -sf /etc/nginx/sites-available/cartenz-panel.conf /etc/nginx/sites-enabled/cartenz-panel.conf
rm -f /etc/nginx/sites-enabled/cartenz-bootstrap.conf || true
nginx -t && enable_and_start nginx

# ======== WS-Stunnel (fallback socat jika unit tidak ada) ========
log "Siapkan SSH over WebSocket (ws-stunnel)…"
if [[ -f "$SYSTEMD_DIR/ws-stunnel.service" ]]; then
  cp -f "$SYSTEMD_DIR/ws-stunnel.service" /etc/systemd/system/ws-stunnel.service
else
  cat >/etc/systemd/system/ws-stunnel.service <<'EOF'
[Unit]
Description=SSH Over Websocket
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:80,reuseaddr,fork TCP:127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

# Restore systemd lain dari repo (opsional: ws-dropbear, telebot, dll)
if compgen -G "$SYSTEMD_DIR/*.service" >/dev/null 2>&1; then
  cp -f "$SYSTEMD_DIR/"*.service /etc/systemd/system/
fi
systemctl daemon-reload

# ======== Panel (Node.js) ========
log "Deploy Cartenz Panel…"
mkdir -p /opt/cartenz-panel
if [[ -d "$PANEL_DIR" ]]; then
  rsync -a --delete "$PANEL_DIR"/ /opt/cartenz-panel/
else
  warn "Folder panel tidak ditemukan di repo — lanjut tanpa overwrite."
fi

# Unit panel
if [[ -f "$SYSTEMD_DIR/cartenz-panel.service" ]]; then
  cp -f "$SYSTEMD_DIR/cartenz-panel.service" /etc/systemd/system/cartenz-panel.service
else
  cat >/etc/systemd/system/cartenz-panel.service <<'EOF'
[Unit]
Description=Cartenz VPN Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/cartenz-panel
Environment=NODE_ENV=production
Environment=PORT=8080
Environment=SESSION_SECRET=
ExecStart=/usr/bin/node /opt/cartenz-panel/server.cjs
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
fi

# inject SESSION_SECRET jika kosong
if grep -q 'SESSION_SECRET=$' /etc/systemd/system/cartenz-panel.service; then
  sed -i "s|SESSION_SECRET=$|SESSION_SECRET=$(openssl rand -hex 32)|" /etc/systemd/system/cartenz-panel.service
fi

# install deps panel
if [[ -f /opt/cartenz-panel/package.json ]]; then
  (cd /opt/cartenz-panel && npm ci --omit=dev || npm install --omit=dev)
fi

# branding kecil (opsional)
[[ -f /opt/cartenz-panel/public/index.html ]] && sed -i 's/Cartenz Panel/Cartenz VPN Premium/g' /opt/cartenz-panel/public/index.html || true

# ======== Pasang skrip ke /usr/bin ========
log "Menyalin skrip ke /usr/bin…"
if [[ -d "$SCRIPT_DIR" ]]; then
  install -m 0755 -D "$SCRIPT_DIR/"* /usr/bin/
else
  warn "Folder scripts/ tidak ditemukan."
fi

# ======== Firewall ========
log "Konfigurasi firewall (UFW)…"
apt-get install -y --no-install-recommends ufw || true
ufw allow OpenSSH || true
ufw allow 80,443/tcp || true
ufw allow 109,143/tcp || true
ufw allow 8080/tcp || true
ufw allow 10000:10005/tcp || true
ufw allow 7100:7900/udp || true   # UDPGW range (kalau dipakai)
ufw --force enable || true

# ======== Start semua service utama ========
log "Menyalakan semua service…"
enable_and_start stunnel4
enable_and_start xray
enable_and_start ws-stunnel
enable_and_start cartenz-panel
# aktifkan ws-dropbear bila ada unitnya
if systemctl list-unit-files | grep -q '^ws-dropbear.service'; then enable_and_start ws-dropbear; fi
# telebot opsional—jangan dipaksa start
if systemctl list-unit-files | grep -q '^telebot.service'; then
  warn "telebot dibiarkan nonaktif (opsional)."
fi

# ======== Auto MENU saat login ========
log "Set login otomatis menampilkan menu…"
cat >/etc/profile.d/99-cartenz-menu.sh <<'EOF'
# Tampilkan menu Cartenz VPN Premium saat login shell interaktif root
if [[ $EUID -eq 0 && -t 1 && -x /usr/bin/menu ]]; then
  echo
  echo "Launching Cartenz VPN Premium menu..."
  /usr/bin/menu || true
fi
EOF
chmod +x /etc/profile.d/99-cartenz-menu.sh

# ======== Ringkasan ========
echo
echo -e "${W}==============================${C0}"
echo -e "${W}  RINGKASAN INSTALASI CARTENZ ${C0}"
echo -e "${W}==============================${C0}"
for s in xray nginx stunnel4 dropbear ws-stunnel ws-dropbear cartenz-panel; do
  if systemctl is-active --quiet "$s"; then ok "$s : active"; else err "$s : INACTIVE"; fi
done
echo
echo -e "${G}Panel URL : https://$PANEL_DOMAIN${C0}"
echo -e "${G}VPN Host  : $VPN_DOMAIN${C0}"
echo -e "${Y}Jika issuance TLS gagal, ulang manual:\n  systemctl stop nginx xray stunnel4 && certbot certonly --standalone -d $PANEL_DOMAIN -d $VPN_DOMAIN -m $CERTBOT_EMAIL --agree-tos -n && systemctl start nginx stunnel4 xray${C0}"
echo

# ======== Simpan catatan & Reboot ========
echo "Cartenz Install — $(date)" > "$LOG_FILE"
echo "Panel: https://${PANEL_DOMAIN}" >> "$LOG_FILE"
echo "VPN  : ${VPN_DOMAIN}" >> "$LOG_FILE"

echo -e "${W}Reboot VPS untuk finalisasi. Setelah login, menu akan tampil otomatis.${C0}"
sleep 3
/sbin/reboot
