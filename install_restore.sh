# Simpan sebagai install_restore.sh di root repo
#!/usr/bin/env bash
# install_restore.sh — Cartenz VPN Premium (Full Auto)
# Restore & install semua layanan dari repo Konfigurasi-VPS-Baru
# Tested: Ubuntu 20.04/22.04/24.04 & Debian 11/12 (systemd)

set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ===== Warna & log =====
C0='\033[0m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[34m'; C='\033[36m'; W='\033[97m'
log(){ echo -e "${C}[*]${C0} $*"; }
ok(){ echo -e "${G}[OK]${C0} $*"; }
warn(){ echo -e "${Y}[WARN]${C0} $*"; }
err(){ echo -e "${R}[ERR]${C0} $*" >&2; }

# ===== Cek root & OS =====
if [[ ${EUID:-0} -ne 0 ]]; then err "Harus dijalankan sebagai root."; exit 1; fi
if [[ -f /etc/os-release ]]; then . /etc/os-release; ok "OS: $PRETTY_NAME"; else warn "Tidak bisa deteksi OS dengan /etc/os-release"; fi

# ===== Lokasi repo (relative) =====
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="$REPO_ROOT/etc"                # etc/{nginx,stunnel,xray}
SYSTEMD_DIR="$REPO_ROOT/systemd"        # *.service
SCRIPT_DIR="$REPO_ROOT/scripts"         # semua script CLI (menu, add-*, dll)
PANEL_DIR="$REPO_ROOT/opt/cartenz-panel"
FIREWALL_DIR="$REPO_ROOT/firewall"      # iptables.up.rules (opsional)

# ===== Input domain & email =====
echo
read -rp "Domain PANEL (mis: panel.cartenz-vpn.my.id): " PANEL_DOMAIN
while [[ -z "${PANEL_DOMAIN}" ]]; do read -rp "Domain PANEL tidak boleh kosong: " PANEL_DOMAIN; done

read -rp "Domain VPN (mis: vpn.cartenz-vpn.my.id): " VPN_DOMAIN
while [[ -z "${VPN_DOMAIN}" ]]; do read -rp "Domain VPN tidak boleh kosong: " VPN_DOMAIN; done

read -rp "Email Certbot (default: admin@${VPN_DOMAIN}): " CERTBOT_EMAIL
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@${VPN_DOMAIN}}"

ok "Panel domain: $PANEL_DOMAIN"
ok "VPN domain  : $VPN_DOMAIN"
ok "Email       : $CERTBOT_EMAIL"

# ===== Util =====
aptx(){ apt-get update -y && apt-get install -y --no-install-recommends "$@"; }
enable_and_start(){
  local svc="$1"
  systemctl daemon-reload
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc" || systemctl start "$svc" || true
  if systemctl is-active --quiet "$svc"; then ok "Service $svc aktif"; else warn "Service $svc belum aktif"; fi
}
replace_domain_in_file(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -i "s/sgdo\.anya-vpn\.my\.id/${VPN_DOMAIN}/g" "$file" || true
  sed -i "s/anya-vpn\.my\.id/${VPN_DOMAIN}/g" "$file" || true
  sed -i "s/domain_placeholder/${VPN_DOMAIN}/g" "$file" || true
  sed -i "s/panel\.cartenz-vpn\.my\.id/${PANEL_DOMAIN}/g" "$file" || true
  sed -i "s/cartenz-vpn\.my\.id/${VPN_DOMAIN}/g" "$file" || true
}

# ===== Paket dasar =====
log "Instal paket dasar..."
aptx ca-certificates curl wget gnupg lsb-release jq git unzip tar sudo \
    socat net-tools ufw nginx dropbear stunnel4 certbot python3-certbot-nginx \
    nodejs npm rsync

# ===== NGINX bootstrap (untuk HTTP-01) =====
log "Siapkan NGINX bootstrap di :80..."
mkdir -p /var/www/html
cat >/etc/nginx/sites-available/cartenz-bootstrap.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN} ${VPN_DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 200 "Cartenz bootstrap OK\n"; }
}
EOF
ln -sf /etc/nginx/sites-available/cartenz-bootstrap.conf /etc/nginx/sites-enabled/cartenz-bootstrap.conf
rm -f /etc/nginx/sites-enabled/default || true
nginx -t && enable_and_start nginx

# ===== Issue TLS (Panel via nginx, VPN via standalone) =====
log "Issue sertifikat TLS..."
# Panel
if ! certbot --nginx -d "$PANEL_DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n; then
  warn "Issue TLS panel via --nginx gagal, coba webroot..."
  certbot certonly --webroot -w /var/www/html -d "$PANEL_DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n || warn "TLS panel gagal (manual nanti)."
fi
# VPN
systemctl stop nginx || true
if ! certbot certonly --standalone -d "$VPN_DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n; then
  warn "Issue TLS VPN (standalone) gagal, coba webroot..."
  systemctl start nginx || true
  certbot certonly --webroot -w /var/www/html -d "$VPN_DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n || warn "TLS VPN gagal (manual nanti)."
else
  systemctl start nginx || true
fi
systemctl enable certbot.timer >/dev/null 2>&1 || true
ok "Certbot terpasang & timer aktif"

# ===== Restore NGINX configs dari repo (jika ada) =====
if [[ -d "$ETC_DIR/nginx" ]]; then
  log "Restore /etc/nginx dari repo..."
  rsync -a "$ETC_DIR/nginx/" /etc/nginx/
fi

# ===== Xray =====
log "Install & setup Xray..."
if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
fi
mkdir -p /etc/xray
# Tulis domain untuk kompatibilitas script
echo "$VPN_DOMAIN" >/etc/xray/domain
echo "$VPN_DOMAIN" >/etc/xray/scdomain
# Link cert ke lokasi yang umum dipakai config
if [[ -d "/etc/letsencrypt/live/$VPN_DOMAIN" ]]; then
  ln -sf "/etc/letsencrypt/live/$VPN_DOMAIN/fullchain.pem" "/etc/xray/xray.crt"
  ln -sf "/etc/letsencrypt/live/$VPN_DOMAIN/privkey.pem"  "/etc/xray/xray.key"
fi
# Restore config.json
if [[ -f "$ETC_DIR/xray/config.json" ]]; then
  cp -f "$ETC_DIR/xray/config.json" /etc/xray/config.json
  replace_domain_in_file /etc/xray/config.json
fi
# Restore file tambahan xray (opsional)
for f in domain scdomain xray.crt xray.key; do
  [[ -f "$ETC_DIR/xray/$f" ]] && cp -f "$ETC_DIR/xray/$f" "/etc/xray/$f" || true
done

# ===== Stunnel =====
log "Konfigurasi Stunnel4..."
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
cert = /etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem
key  = /etc/letsencrypt/live/${VPN_DOMAIN}/privkey.pem
EOF
fi
sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 || true

# ===== Dropbear =====
log "Konfigurasi Dropbear..."
if [[ -f /etc/default/dropbear ]]; then
  sed -i 's/^NO_START=.*/NO_START=0/' /etc/default/dropbear || true
  if grep -q '^DROPBEAR_PORT=' /etc/default/dropbear; then
    sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=109/' /etc/default/dropbear
  else
    echo "DROPBEAR_PORT=109" >> /etc/default/dropbear
  fi
else
  cat >/etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=109
DROPBEAR_EXTRA_ARGS="-w"
EOF
fi

# ===== NGINX site untuk Panel dan Xray =====
log "Terapkan site NGINX Panel & Xray..."
# Panel reverse proxy
cat >/etc/nginx/sites-available/cartenz-panel.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 http2;
    server_name ${PANEL_DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
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

# Xray reverse proxy — gunakan conf dari repo jika ada; kalau tidak, buat minimal
mkdir -p /etc/nginx/conf.d
if [[ -f "$ETC_DIR/nginx/conf.d/xray.conf" ]]; then
  cp -f "$ETC_DIR/nginx/conf.d/xray.conf" /etc/nginx/conf.d/xray.conf
  replace_domain_in_file /etc/nginx/conf.d/xray.conf
  sed -i "s/server_name .*/server_name ${VPN_DOMAIN} *.${VPN_DOMAIN};/" /etc/nginx/conf.d/xray.conf || true
else
  cat >/etc/nginx/conf.d/xray.conf <<'EOF'
# Template minimal reverse proxy ke Xray ws port 10000..10003
# Isi domain di bawah saat render
server {
    listen 443 ssl http2;
    listen [::]:443 http2;
    server_name __VPN_DOMAIN__ *.____VPN_DOMAIN__;
    ssl_certificate     /etc/letsencrypt/live/__VPN_DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__VPN_DOMAIN__/privkey.pem;

    location /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    location /trojan-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    location /ss-ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
EOF
  sed -i "s/__VPN_DOMAIN__/${VPN_DOMAIN}/g" /etc/nginx/conf.d/xray.conf
fi

# Hapus bootstrap jika sudah ada site final
rm -f /etc/nginx/sites-enabled/cartenz-bootstrap.conf || true
nginx -t && enable_and_start nginx

# ===== Panel (Node.js) =====
log "Restore Cartenz Panel..."
mkdir -p /opt/cartenz-panel
if [[ -d "$PANEL_DIR" ]]; then
  rsync -a --delete "$PANEL_DIR"/ /opt/cartenz-panel/
fi
pushd /opt/cartenz-panel >/dev/null || true
if [[ -f package.json ]]; then
  npm ci --omit=dev || npm install --omit=dev
fi
popd >/dev/null || true

# Unit cartenz-panel
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
# isi SESSION_SECRET saat pertama start bila kosong
Environment=SESSION_SECRET=
ExecStart=/usr/bin/node /opt/cartenz-panel/server.cjs
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
fi
# Auto generate SESSION_SECRET jika kosong
if grep -q 'Environment=SESSION_SECRET=$' /etc/systemd/system/cartenz-panel.service; then
  sed -i "s|Environment=SESSION_SECRET=$|Environment=SESSION_SECRET=$(openssl rand -hex 32)|" /etc/systemd/system/cartenz-panel.service
fi

# Branding panel (opsional)
[[ -f /opt/cartenz-panel/public/index.html ]] && sed -i 's/Cartenz Panel/Cartenz VPN Premium/g' /opt/cartenz-panel/public/index.html || true

# ===== Restore systemd lain dari repo =====
if [[ -d "$SYSTEMD_DIR" ]]; then
  log "Restore unit systemd dari repo..."
  cp -f "$SYSTEMD_DIR"/*.service /etc/systemd/system/ 2>/dev/null || true
fi

# ===== Pasang semua skrip ke /usr/bin =====
if [[ -d "$SCRIPT_DIR" ]]; then
  log "Menyalin skrip CLI ke /usr/bin..."
  install -m 0755 -D "$SCRIPT_DIR/"* /usr/bin/
fi

# ===== Firewall =====
log "Atur UFW..."
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80,443/tcp >/dev/null 2>&1 || true
ufw allow 109,143/tcp >/dev/null 2>&1 || true
[[ -f "$FIREWALL_DIR/iptables.up.rules" ]] && (cp -f "$FIREWALL_DIR/iptables.up.rules" /etc/iptables.up.rules && iptables-restore < /etc/iptables.up.rules || warn "Gagal apply iptables")
ufw --force enable || true

# ===== Start services =====
log "Enable & start services..."
for svc in dropbear stunnel4 xray nginx ws-stunnel ws-dropbear cartenz-panel telebot; do
  [[ -f "/etc/systemd/system/${svc}.service" || "$svc" =~ ^(dropbear|stunnel4|xray|nginx)$ ]] && enable_and_start "$svc" || true
done

# ===== Ringkasan =====
echo
echo -e "${W}================= RINGKASAN =================${C0}"
for svc in xray nginx stunnel4 dropbear ws-stunnel ws-dropbear cartenz-panel telebot; do
  if systemctl is-active --quiet "$svc"; then ok "$svc : active"; else warn "$svc : inactive"; fi
done
echo -e "${G}Panel URL : https://${PANEL_DOMAIN}${C0}"
echo -e "${G}VPN Host  : ${VPN_DOMAIN}${C0}"
echo -e "${C}Jika TLS untuk VPN gagal:\
\n  systemctl stop nginx xray && certbot certonly --standalone -d ${VPN_DOMAIN} -m ${CERTBOT_EMAIL} --agree-tos -n && systemctl start nginx xray${C0}"
echo

# ===== Jalankan menu =====
if command -v menu >/dev/null 2>&1; then
  echo -e "${B}Membuka MENU...${C0}"
  sleep 1
  clear
  menu
else
  warn "Perintah 'menu' belum tersedia di /usr/bin/. Cek folder scripts/ di repo."
fi
