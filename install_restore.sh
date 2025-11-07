#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Cartenz VPS – Install & Restore
# ==============================
# Struktur repo yang diharapkan:
# scripts/   -> /usr/bin (chmod +x)
# nginx/     -> /etc/nginx
# xray/      -> /etc/xray
# systemd/   -> /etc/systemd/system
# panel/     -> /opt/cartenz-panel  (Node.js + server.cjs)
# firewall/  -> (opsional) iptables rules
#
# Opsional: Let's Encrypt (certbot) jika --domain & --email diberikan (tanpa --no-ssl).

# -------- Args --------
DOMAIN=""
EMAIL=""
PANEL_PORT="8080"
USE_SSL="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --panel-port) PANEL_PORT="${2:-8080}"; shift 2 ;;
    --no-ssl) USE_SSL="no"; shift ;;
    *) echo "Argumen tidak dikenal: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Jalankan sebagai root: sudo bash install_restore.sh ..."
  exit 1
fi

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
err(){ echo -e "\033[1;31m[-]\033[0m $*" >&2; }

# -------- OS Check --------
if ! command -v apt >/dev/null 2>&1; then
  err "Skrip ini ditujukan untuk Ubuntu/Debian (APT)."
  exit 1
fi

# -------- Update & Packages --------
log "Update paket ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git jq unzip ufw \
  net-tools lsof tar gnupg2 tzdata

# Nginx + alat SSL
apt-get install -y nginx
if [[ "$USE_SSL" == "yes" ]]; then
  apt-get install -y certbot python3-certbot-nginx
fi

# Dropbear & Stunnel4
apt-get install -y dropbear stunnel4

# -------- Node.js (LTS) --------
if ! command -v node >/dev/null 2>&1; then
  log "Pasang Node.js 20 (NodeSource) ..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
log "Node.js: $(node -v), npm: $(npm -v)"

# -------- XRAY --------
if ! command -v xray >/dev/null 2>&1; then
  log "Pasang XRAY ..."
  bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install || true
fi
mkdir -p /etc/xray
# Domain file jika belum ada (akan di-overwrite bila ada di repo)
if [[ -n "$DOMAIN" ]]; then
  echo "$DOMAIN" >/etc/xray/domain || true
fi

# -------- badvpn-udpgw --------
if ! command -v badvpn-udpgw >/dev/null 2>&1; then
  log "Pasang badvpn-udpgw ..."
  cd /usr/local/bin
  ARCH="$(uname -m)"
  URL=""
  case "$ARCH" in
    x86_64|amd64) URL="https://raw.githubusercontent.com/ambrop72/badvpn/master/badvpn-udpgw" ;; # fallback kecil; ganti bila punya mirror binari
    aarch64|arm64) URL="https://raw.githubusercontent.com/ambrop72/badvpn/master/badvpn-udpgw" ;;
    *) URL="https://raw.githubusercontent.com/ambrop72/badvpn/master/badvpn-udpgw" ;;
  esac
  curl -fsSL "$URL" -o badvpn-udpgw || true
  chmod +x badvpn-udpgw || true
fi

# -------- Copy dari repo ke sistem --------
REPO_DIR="$(pwd)"

# A) scripts -> /usr/bin
if [[ -d "$REPO_DIR/scripts" ]]; then
  log "Restore scripts ke /usr/bin ..."
  cp -av "$REPO_DIR/scripts/." /usr/bin/
  chmod +x /usr/bin/* || true
else
  warn "Folder scripts/ tidak ditemukan, lewati."
fi

# B) nginx -> /etc/nginx
if [[ -d "$REPO_DIR/nginx" ]]; then
  log "Restore Nginx config ..."
  # Buat subdirs bila ada
  mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled
  cp -av "$REPO_DIR/nginx/nginx.conf" /etc/nginx/ 2>/dev/null || true
  cp -av "$REPO_DIR/nginx/proxy_params" /etc/nginx/ 2>/dev/null || true
  cp -av "$REPO_DIR/nginx/mime.types" /etc/nginx/ 2>/dev/null || true
  cp -av "$REPO_DIR/nginx/uwsgi_params" /etc/nginx/ 2>/dev/null || true
  cp -av "$REPO_DIR/nginx/fastcgi_params" /etc/nginx/ 2>/dev/null || true
  if [[ -d "$REPO_DIR/nginx/conf.d" ]]; then
    cp -av "$REPO_DIR/nginx/conf.d/." /etc/nginx/conf.d/
  fi
  if [[ -d "$REPO_DIR/nginx/sites-available" ]]; then
    cp -av "$REPO_DIR/nginx/sites-available/." /etc/nginx/sites-available/
  fi
else
  warn "Folder nginx/ tidak ditemukan, lewati restore config."
fi

# C) xray -> /etc/xray
if [[ -d "$REPO_DIR/xray" ]]; then
  log "Restore XRAY config ..."
  cp -av "$REPO_DIR/xray/." /etc/xray/
fi

# D) systemd -> /etc/systemd/system
if [[ -d "$REPO_DIR/systemd" ]]; then
  log "Restore unit systemd ..."
  cp -av "$REPO_DIR/systemd/." /etc/systemd/system/
fi

# E) panel -> /opt/cartenz-panel
if [[ -d "$REPO_DIR/panel" ]]; then
  log "Restore panel ke /opt/cartenz-panel ..."
  rsync -a --delete \
    --exclude 'node_modules' \
    --exclude '.env' \
    "$REPO_DIR/panel/" /opt/cartenz-panel/
  mkdir -p /opt/cartenz-panel
  cd /opt/cartenz-panel
  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev
  else
    npm i --omit=dev
  fi
  # ENV
  if [[ ! -f /etc/cartenz-panel.env ]]; then
    if [[ -f "$REPO_DIR/panel/.env.example" ]]; then
      cp -av "$REPO_DIR/panel/.env.example" /etc/cartenz-panel.env
    else
      touch /etc/cartenz-panel.env
    fi
    # Patch default port & session secret
    if ! grep -q '^PORT=' /etc/cartenz-panel.env 2>/dev/null; then
      echo "PORT=$PANEL_PORT" >> /etc/cartenz-panel.env
    else
      sed -i "s/^PORT=.*/PORT=$PANEL_PORT/" /etc/cartenz-panel.env
    fi
    if ! grep -q '^SESSION_SECRET=' /etc/cartenz-panel.env 2>/dev/null; then
      echo "SESSION_SECRET=$(openssl rand -hex 32)" >> /etc/cartenz-panel.env
    fi
  else
    # Sinkronkan port bila perlu
    sed -i "s/^PORT=.*/PORT=$PANEL_PORT/" /etc/cartenz-panel.env || true
  fi
else
  warn "Folder panel/ tidak ditemukan. Lewati deploy panel."
fi

# F) firewall (opsional)
if [[ -f "$REPO_DIR/firewall/iptables.up.rules" ]]; then
  log "Restore iptables rules ..."
  cp -av "$REPO_DIR/firewall/iptables.up.rules" /etc/iptables.up.rules
fi

# -------- Nginx site untuk panel (jika tidak tersedia di repo) --------
DEFAULT_SITE="/etc/nginx/sites-available/cartenz-panel.conf"
if [[ ! -f "$DEFAULT_SITE" ]]; then
  if [[ -z "$DOMAIN" ]]; then
    warn "DOMAIN kosong dan site Nginx tidak ditemukan. Buat site default untuk 127.0.0.1 ..."
    cat >"$DEFAULT_SITE" <<EOF
server {
  listen 80;
  server_name _;
  client_max_body_size 20m;

  location / {
    proxy_pass http://127.0.0.1:${PANEL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
EOF
  else
    log "Buat site Nginx untuk domain ${DOMAIN} ..."
    cat >"$DEFAULT_SITE" <<EOF
server {
  listen 80;
  server_name ${DOMAIN};
  client_max_body_size 20m;

  location / {
    proxy_pass http://127.0.0.1:${PANEL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
EOF
  fi
fi
ln -sf "$DEFAULT_SITE" /etc/nginx/sites-enabled/cartenz-panel.conf

# -------- Systemd unit untuk panel (jika tidak ada di repo) --------
if [[ ! -f /etc/systemd/system/cartenz-panel.service ]]; then
  log "Buat unit cartenz-panel.service ..."
  cat >/etc/systemd/system/cartenz-panel.service <<'EOF'
[Unit]
Description=Cartenz VPN Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/cartenz-panel.env
WorkingDirectory=/opt/cartenz-panel
ExecStart=/usr/bin/node /opt/cartenz-panel/server.cjs
Restart=always
RestartSec=3
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
fi

# -------- Systemd badvpn (jika belum ada) --------
if [[ ! -f /etc/systemd/system/badvpn-udpgw.service ]]; then
  log "Buat unit badvpn-udpgw.service ..."
  cat >/etc/systemd/system/badvpn-udpgw.service <<'EOF'
[Unit]
Description=BadVPN UDPGW Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 2048
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

# -------- Enable & start services --------
log "Enable & start services ..."
systemctl daemon-reload
systemctl enable --now nginx || true
systemctl enable --now xray || true
systemctl enable --now dropbear || true
systemctl enable --now stunnel4 || true
systemctl enable --now badvpn-udpgw || true
systemctl enable --now cartenz-panel || true

# -------- SSL (opsional) --------
if [[ "$USE_SSL" == "yes" && -n "$DOMAIN" && -n "$EMAIL" ]]; then
  log "Siapkan HTTPS untuk ${DOMAIN} ..."
  # Pastikan Nginx jalan di :80
  nginx -t && systemctl reload nginx || true
  # Dapatkan sertifikat; bila plugin nginx gagal, fallback certonly
  if certbot --nginx -d "$DOMAIN" -n --agree-tos -m "$EMAIL" --redirect; then
    log "Sertifikat berhasil dipasang via nginx plugin."
  else
    warn "Gagal memasang otomatis via --nginx, coba certonly ..."
    certbot certonly --webroot -w /var/www/html -d "$DOMAIN" -n --agree-tos -m "$EMAIL" || true
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
      warn "Sertifikat didapat. Sesuaikan blok SSL Nginx (jika perlu) dan reload."
    else
      warn "Sertifikat belum tersedia. Periksa DNS dan ulangi certbot nanti."
    fi
  fi
  systemctl restart nginx || true
else
  warn "SSL dilewati (gunakan --domain & --email tanpa --no-ssl untuk otomatis HTTPS)."
fi

# -------- Validasi akhir --------
log "Validasi konfigurasi Nginx ..."
nginx -t && systemctl reload nginx || true

log "Restart XRAY & Panel ..."
systemctl restart xray || true
systemctl restart cartenz-panel || true

# -------- Ringkasan --------
PADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "Selesai ✨"
echo "-----------------------------------------"
echo "Panel:       http://${DOMAIN:-$PADDR}/"
if [[ -n "$DOMAIN" && "$USE_SSL" == "yes" ]]; then
  echo "(Jika HTTPS aktif) https://${DOMAIN}/"
fi
echo "Panel port:  ${PANEL_PORT} (internal, via Nginx reverse proxy)"
echo "XRAY:        systemctl status xray"
echo "Dropbear:    systemctl status dropbear"
echo "Stunnel4:    systemctl status stunnel4"
echo "BadVPN:      systemctl status badvpn-udpgw"
echo "Nginx:       systemctl status nginx"
echo "-----------------------------------------"
echo "Tips:"
echo "- Ubah /etc/cartenz-panel.env lalu: systemctl restart cartenz-panel"
echo "- Edit Nginx di /etc/nginx/..., lalu: nginx -t && systemctl reload nginx"
echo "- Untuk SSL ulang: certbot --nginx -d ${DOMAIN:-your.domain} -m ${EMAIL:-you@email}"
