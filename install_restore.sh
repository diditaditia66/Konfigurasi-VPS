#!/usr/bin/env bash
# install_restore.sh — Cartenz VPN Premium (Konfigurasi-VPS-Baru)
# Restore semua layanan & konfigurasi otomatis
# Tested: Ubuntu/Debian (20.04, 22.04, 24.04, 11, 12)

set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ========== Warna ==========
C0='\033[0m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[34m'; C='\033[36m'; W='\033[97m'
log(){ echo -e "${C}[*]${C0} $*"; }
ok(){ echo -e "${G}[OK]${C0} $*"; }
warn(){ echo -e "${Y}[WARN]${C0} $*"; }
err(){ echo -e "${R}[ERR]${C0} $*" >&2; }

# ========== Cek hak akses ==========
if [[ $EUID -ne 0 ]]; then
  err "Harus dijalankan sebagai root!"
  exit 1
fi

# ========== Lokasi Repositori ==========
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="$REPO_ROOT/etc"
SCRIPT_DIR="$REPO_ROOT/scripts"
SYSTEMD_DIR="$REPO_ROOT/systemd"
PANEL_DIR="$REPO_ROOT/opt/cartenz-panel"
FIREWALL_DIR="$REPO_ROOT/firewall"

# ========== Fungsi Utilitas ==========
aptx(){
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}
enable_and_start(){
  systemctl daemon-reload
  systemctl enable "$1" >/dev/null 2>&1 || true
  systemctl restart "$1" || systemctl start "$1" || true
  systemctl is-active --quiet "$1" && ok "Service $1 aktif" || warn "Service $1 tidak aktif"
}

# ========== Deteksi OS ==========
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  ok "OS: $PRETTY_NAME"
else
  warn "Tidak dapat mendeteksi OS!"
fi

# ========== Domain & Email ==========
echo
read -rp "Masukkan domain PANEL (mis: panel.cartenz-vpn.my.id): " PANEL_DOMAIN
read -rp "Masukkan domain VPN (mis: vpn.cartenz-vpn.my.id): " VPN_DOMAIN
read -rp "Masukkan email Certbot (default: admin@$VPN_DOMAIN): " CERTBOT_EMAIL
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@$VPN_DOMAIN}"

# ========== Install Paket Dasar ==========
log "Instal paket dasar..."
aptx nginx certbot python3-certbot-nginx dropbear stunnel4 nodejs npm ufw curl wget jq git unzip tar socat

# ========== Restore Config NGINX ==========
log "Restore konfigurasi NGINX..."
mkdir -p /etc/nginx/conf.d
cp -rf "$ETC_DIR/nginx/"* /etc/nginx/ || true

# ========== Setup Dropbear ==========
log "Konfigurasi Dropbear..."
sed -i 's/^NO_START=.*/NO_START=0/' /etc/default/dropbear || true
sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=109/' /etc/default/dropbear || echo "DROPBEAR_PORT=109" >> /etc/default/dropbear
enable_and_start dropbear

# ========== Restore Stunnel ==========
log "Restore Stunnel..."
mkdir -p /etc/stunnel
cp -f "$ETC_DIR/stunnel/stunnel.conf" /etc/stunnel/stunnel.conf || true
sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 || true
enable_and_start stunnel4

# ========== Restore Xray ==========
log "Restore Xray..."
if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
fi
mkdir -p /etc/xray
cp -rf "$ETC_DIR/xray/"* /etc/xray/ || true
enable_and_start xray

# ========== Certbot ==========
log "Setup TLS dengan Certbot..."
systemctl stop nginx || true
certbot certonly --standalone -d "$VPN_DOMAIN" -d "$PANEL_DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n || warn "Certbot gagal, lanjutkan manual"
systemctl start nginx || true

# ========== NGINX untuk Panel & Xray ==========
log "Konfigurasi NGINX site..."
cat >/etc/nginx/sites-available/cartenz-panel.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $PANEL_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

cat >/etc/nginx/conf.d/xray.conf <<EOF
server {
    listen 443 ssl http2;
    server_name $VPN_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$VPN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$VPN_DOMAIN/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

nginx -t && enable_and_start nginx

# ========== Firewall ==========
log "Restore firewall..."
if [[ -f "$FIREWALL_DIR/iptables.up.rules" ]]; then
  cp -f "$FIREWALL_DIR/iptables.up.rules" /etc/iptables.up.rules
  iptables-restore < /etc/iptables.up.rules || warn "Gagal menerapkan iptables"
fi
ufw allow 80,443/tcp
ufw allow 109/tcp
ufw --force enable || true

# ========== Restore Systemd Services ==========
log "Restore file service systemd..."
cp -rf "$SYSTEMD_DIR/"*.service /etc/systemd/system/ || true
systemctl daemon-reload
for svc in cartenz-panel telebot ws-dropbear ws-stunnel xray; do
  enable_and_start "$svc" || true
done

# ========== Restore Panel ==========
log "Setup panel Cartenz..."
mkdir -p /opt/cartenz-panel
rsync -a --delete "$PANEL_DIR"/ /opt/cartenz-panel/
pushd /opt/cartenz-panel >/dev/null
npm ci --omit=dev || npm install --omit=dev
popd >/dev/null
enable_and_start cartenz-panel

# ========== Pasang Semua Skrip ==========
log "Menyalin semua skrip ke /usr/bin..."
install -m 0755 -D "$SCRIPT_DIR"/* /usr/bin/

# ========== Jalankan Menu ==========
if [[ -x /usr/bin/menu ]]; then
  clear
  /usr/bin/menu
else
  ok "Selesai restore, tapi /usr/bin/menu belum ditemukan."
fi

# ========== Ringkasan ==========
echo
echo -e "${W}=== Ringkasan Instalasi ===${C0}"
systemctl is-active --quiet xray           && ok "xray aktif" || warn "xray tidak aktif"
systemctl is-active --quiet nginx          && ok "nginx aktif" || warn "nginx tidak aktif"
systemctl is-active --quiet stunnel4       && ok "stunnel aktif" || warn "stunnel tidak aktif"
systemctl is-active --quiet dropbear       && ok "dropbear aktif" || warn "dropbear tidak aktif"
systemctl is-active --quiet cartenz-panel  && ok "cartenz-panel aktif" || warn "cartenz-panel tidak aktif"
echo
echo -e "${G}Panel URL: https://$PANEL_DOMAIN${C0}"
echo -e "${G}VPN Host : $VPN_DOMAIN${C0}"
echo
