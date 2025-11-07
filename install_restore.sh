#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# install_restore.sh — use your scripts + add optional Panel + Banner
# Layanan & port target (match upstream):
#   OpenSSH 22 | SSH-WS 80/443 | Xray WS 80/443 + gRPC 443 | Nginx 81
#   Stunnel 222,777 | Dropbear 109,143 | Badvpn UDP 7100–7900 | (opsional) IPSec, SSTP
# Panel (Node) dari repo kamu: opt/cartenz-panel/*, systemd/cartenz-panel.service
# Panel listen di :81 (HTTP). Opsi TLS via :4443 (tidak mengganggu 443 milik XRAY).
# Banner: pakai repo/etc/issue.net bila ada.
# ------------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

C0='\033[0m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; W='\033[97m'
log(){ echo -e "${C}[*]${C0} $*"; }
ok(){ echo -e "${G}[OK]${C0} $*"; }
warn(){ echo -e "${Y}[WARN]${C0} $*"; }
err(){ echo -e "${R}[ERR]${C0} $*" >&2; }

trap 'err "Error di baris $LINENO"; exit 1' ERR

[[ $EUID -eq 0 ]] || { err "Jalankan sebagai root"; exit 1; }
command -v systemd-detect-virt >/dev/null && [[ "$(systemd-detect-virt)" == "openvz" ]] && { err "OpenVZ tidak didukung"; exit 1; }
if [[ -f /etc/os-release ]]; then . /etc/os-release; ok "OS: $PRETTY_NAME"; fi

aptx(){ apt-get update -y; apt-get install -y --no-install-recommends "$@"; }
svc_on(){ systemctl daemon-reload || true; systemctl enable "$1" >/dev/null 2>&1 || true; systemctl restart "$1" || systemctl start "$1" || true; }
svc_ok(){ systemctl is-active --quiet "$1" && ok "Service $1 aktif" || warn "Service $1 belum aktif"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
PANEL_DIR="$REPO_ROOT/opt/cartenz-panel"
SYSTEMD_DIR="$REPO_ROOT/systemd"
REPO_ISSUE="$REPO_ROOT/etc/issue.net"

echo -e "${W}=== Pengaturan Domain VPN ===${C0}"
echo "1) Domain Random (via vendor cf.sh)"
echo "2) Masukkan Domain manual"
read -rp "Pilih [1/2]: " DNS_OPT

mkdir -p /etc/xray /etc/v2ray
: > /etc/xray/domain; : > /etc/xray/scdomain
: > /etc/v2ray/domain; : > /etc/v2ray/scdomain

if [[ "${DNS_OPT}" == "1" ]]; then
  log "Generate domain random dari vendor…"
  curl -fsSL https://autoscript.caliphdev.com/ssh/cf.sh | bash
  DOMAIN="$(cat /etc/xray/domain 2>/dev/null || true)"
  [[ -n "${DOMAIN:-}" ]] || { err "Gagal mengambil domain"; exit 1; }
else
  read -rp "Masukkan domain VPN (contoh: vpn.example.com): " DOMAIN
  [[ -n "${DOMAIN}" ]] || { err "Domain kosong"; exit 1; }
  echo "IP=${DOMAIN}" > /var/lib/ipvps.conf
  for f in /root/scdomain /etc/xray/scdomain /etc/xray/domain /etc/v2ray/domain /root/domain; do
    echo "${DOMAIN}" > "$f"
  done
fi
ok "Domain VPN: $DOMAIN"

# ===== Paket dasar =====
log "Install paket dasar…"
aptx curl wget git jq tar unzip rsync gnupg ca-certificates lsb-release \
    net-tools ufw neofetch nginx dropbear stunnel4 dos2unix whiptail nodejs npm

# ===== Bersihkan konflik lama =====
log "Bersihkan konflik (nginx/xray.conf custom, ws-2095)…"
systemctl stop nginx stunnel4 xray ws-stunnel cartenz-panel 2>/dev/null || true
rm -f /etc/nginx/conf.d/xray.conf /etc/nginx/sites-enabled/xray.conf /etc/systemd/system/ws-stunnel.service 2>/dev/null || true
systemctl daemon-reload || true

# ===== Nginx panel :81 =====
log "Siapkan Nginx panel di :81…"
mkdir -p /var/www/html
[[ -f /var/www/html/index.html ]] || echo "<h1>Cartenz Panel on :81</h1>" >/var/www/html/index.html
cat >/etc/nginx/sites-available/panel-81.conf <<'EOF'
server {
    listen 81;
    listen [::]:81;
    server_name _;
    root /var/www/html;
    index index.html index.htm;
}
EOF
ln -sf /etc/nginx/sites-available/panel-81.conf /etc/nginx/sites-enabled/panel-81.conf
rm -f /etc/nginx/sites-enabled/default || true
nginx -t && svc_on nginx
svc_ok nginx

# ===== Stunnel 222 & 777 =====
log "Konfigurasi Stunnel di 222 & 777…"
mkdir -p /etc/stunnel
cat >/etc/stunnel/stunnel.conf <<'EOF'
foreground = no
pid = /var/run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
cert = /etc/ssl/certs/ssl-cert-snakeoil.pem
key  = /etc/ssl/private/ssl-cert-snakeoil.key

[stunnel-ssh-222]
accept = 222
connect = 127.0.0.1:22

[stunnel-ssh-777]
accept = 777
connect = 127.0.0.1:22
EOF
sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 || true
svc_on stunnel4
svc_ok stunnel4

# ===== Dropbear 109 (vendor nanti tambahkan 143) =====
log "Aktifkan Dropbear di 109…"
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
svc_on dropbear
svc_ok dropbear

# ===== Pasang runtime/services dari vendor =====
cd /root
if ! command -v xray >/dev/null 2>&1 && [[ ! -x /usr/local/bin/xray ]]; then
  log "Install XRAY dari vendor…"
  wget -q https://autoscript.caliphdev.com/xray/ins-xray.sh && chmod +x ins-xray.sh && ./ins-xray.sh
else
  ok "XRAY sudah ada — skip"
fi

if ! systemctl list-unit-files | grep -Eiq '(sshws|ssh-ws|ws-ssh)'; then
  log "Install SSH-WS dari vendor…"
  wget -q https://autoscript.caliphdev.com/sshws/insshws.sh && chmod +x insshws.sh && ./insshws.sh
else
  ok "SSH-WS sudah ada — skip"
fi

log "Sinkron stack SSH/VPN vendor (dropbear, badvpn, nginx 81)…"
wget -q https://autoscript.caliphdev.com/ssh/ssh-vpn.sh && chmod +x ssh-vpn.sh && ./ssh-vpn.sh

read -rp "Pasang IPSec & SSTP (Y/n)? " INSTALL_VPNP
if [[ "${INSTALL_VPNP:-Y}" =~ ^[Yy]$ ]]; then
  log "Install IPSec & SSTP…"
  wget -q https://autoscript.caliphdev.com/ipsec/ipsec.sh && chmod +x ipsec.sh && ./ipsec.sh
  wget -q https://autoscript.caliphdev.com/sstp/sstp.sh  && chmod +x sstp.sh  && ./sstp.sh
else
  warn "Lewati IPSec/SSTP"
fi

# ===== Deploy scripts kamu =====
log "Deploy scripts operasional (menu/add/cek/del/renew/trial)…"
if [[ -d "$SCRIPTS_DIR" ]]; then
  install -m 0755 -D "$SCRIPTS_DIR/"* /usr/bin/
  # normalisasi
  for f in /usr/bin/*; do
    [[ -f "$f" ]] || continue
    dos2unix -q "$f" 2>/dev/null || true
    chmod +x "$f" || true
  done
  [[ -x /usr/bin/menu ]] && ok "menu milikmu terpasang" || warn "menu tidak ditemukan dalam scripts/"
else
  warn "Folder scripts/ tidak ada — lanjut tanpa tool custom"
fi

# ===== OPSIONAL: Deploy Panel dari repo =====
PANEL_ENABLE="N"
PANEL_TLS="N"
read -rp "Tambahkan dan jalankan Panel dari repo? (Y/n): " PANEL_ENABLE
if [[ "${PANEL_ENABLE:-Y}" =~ ^[Yy]$ ]]; then
  [[ -d "$PANEL_DIR" ]] || { err "Folder panel ($PANEL_DIR) tidak ada"; }

  # tanya domain panel (hanya untuk server_name; panel default via :81)
  read -rp "Masukkan domain Panel (mis: panel.example.com) [kosong=pakai _]: " PANEL_DOMAIN
  PANEL_DOMAIN="${PANEL_DOMAIN:-_}"

  # tulis vhost :81 khusus panel-domain agar rapi
  log "Konfigurasi Nginx vhost panel :81 untuk $PANEL_DOMAIN…"
  cat >/etc/nginx/sites-available/cartenz-panel-81.conf <<EOF
server {
    listen 81;
    listen [::]:81;
    server_name ${PANEL_DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/cartenz-panel-81.conf /etc/nginx/sites-enabled/cartenz-panel-81.conf
  nginx -t && svc_on nginx

  # deploy kode & service
  log "Deploy kode panel ke /opt/cartenz-panel…"
  mkdir -p /opt/cartenz-panel
  rsync -a --delete "$PANEL_DIR"/ /opt/cartenz-panel/
  if [[ -f "$SYSTEMD_DIR/cartenz-panel.service" ]]; then
    cp -f "$SYSTEMD_DIR/cartenz-panel.service" /etc/systemd/system/cartenz-panel.service
  else
    # fallback service minimal
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
  # inject secret jika kosong
  sed -i "s|^Environment=SESSION_SECRET=.*$|Environment=SESSION_SECRET=$(openssl rand -hex 32)|" /etc/systemd/system/cartenz-panel.service || true

  # deps panel
  if [[ -f /opt/cartenz-panel/package.json ]]; then
    (cd /opt/cartenz-panel && (npm ci --omit=dev || npm install --omit=dev)) || warn "Install deps panel gagal"
  fi
  svc_on cartenz-panel
  svc_ok cartenz-panel

  # opsi TLS via :4443 (tidak mengganggu 443)
  read -rp "Aktifkan TLS untuk Panel di port 4443 (menggunakan Certbot)? (y/N): " PANEL_TLS
  if [[ "${PANEL_TLS:-N}" =~ ^[Yy]$ && "$PANEL_DOMAIN" != "_" ]]; then
    read -rp "Email untuk Certbot (mis: admin@${PANEL_DOMAIN}): " PANEL_EMAIL
    PANEL_EMAIL="${PANEL_EMAIL:-admin@${PANEL_DOMAIN}}"

    log "Issue sertifikat (stop sementara layanan pada :80)…"
    systemctl stop nginx xray 2>/dev/null || true
    # SSH-WS vendor biasa pakai :80 — hentikan sebentar agar standalone bisa bind
    systemctl stop sshws 2>/dev/null || true
    certbot certonly --standalone -d "$PANEL_DOMAIN" -m "$PANEL_EMAIL" --agree-tos -n || warn "Certbot panel gagal"

    # tulis vhost SSL :4443
    if [[ -d "/etc/letsencrypt/live/$PANEL_DOMAIN" ]]; then
      cat >/etc/nginx/sites-available/cartenz-panel-4443.conf <<EOF
server {
    listen 4443 ssl http2;
    listen [::]:4443 ssl http2;
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
      ln -sf /etc/nginx/sites-available/cartenz-panel-4443.conf /etc/nginx/sites-enabled/cartenz-panel-4443.conf
      ufw allow 4443/tcp || true
    else
      warn "Sertifikat tidak ditemukan — skip vhost 4443"
    fi

    # nyalakan lagi layanan
    nginx -t && systemctl start nginx
    systemctl start xray 2>/dev/null || true
    systemctl start sshws 2>/dev/null || true
  fi
fi

# ===== Banner /etc/issue.net dari repo =====
if [[ -f "$REPO_ISSUE" ]]; then
  log "Pasang banner /etc/issue.net dari repo…"
  install -m 0644 -D "$REPO_ISSUE" /etc/issue.net
  # aktifkan Banner di sshd_config
  if grep -q '^#\?Banner' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's|^#\?Banner.*|Banner /etc/issue.net|' /etc/ssh/sshd_config
  else
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
  fi
  systemctl restart ssh || true
  ok "Banner diterapkan"
else
  warn "repo/etc/issue.net tidak ditemukan — lewati"
fi

# ===== Auto-menu saat login root (pakai menu kamu) =====
log "Aktifkan auto-menu saat login…"
cat >/root/.profile <<'EOF'
if [ "$BASH" ] && [ -f ~/.bashrc ]; then . ~/.bashrc; fi
mesg n || true
clear
neofetch
echo "Type 'menu' to display the VPN menu"
EOF
chmod 644 /root/.profile

# ===== Firewall (mirror upstream ports) =====
log "Konfigurasi firewall (UFW)…"
ufw --force enable || true
ufw allow 22/tcp
ufw allow 80,443/tcp
ufw allow 81/tcp
ufw allow 109,143/tcp
ufw allow 222,777/tcp
ufw allow 7100:7900/udp
# note: 4443 sudah dibuka di blok TLS panel jika diaktifkan

# ===== Start inti & Ringkasan =====
svc_on nginx;    svc_ok nginx
svc_on stunnel4; svc_ok stunnel4
svc_on dropbear; svc_ok dropbear
# Xray/SSH-WS menyala dari installer vendor

echo -e "\n${W}==============================${C0}"
echo -e "${W}  RINGKASAN (target ports & services) ${C0}"
echo -e "${W}==============================${C0}"
for s in nginx xray stunnel4 dropbear cartenz-panel; do
  systemctl is-active --quiet "$s" && ok "$s : active" || warn "$s : INACTIVE"
done
echo
echo "OpenSSH  : 22"
echo "SSH-WS   : 80 / 443"
echo "Xray     : WS 80/443 + gRPC 443"
echo "Nginx    : 81  ${PANEL_TLS:+(+ 4443 TLS jika diaktifkan)}"
echo "Stunnel  : 222, 777"
echo "Dropbear : 109, 143"
echo "Badvpn   : 7100–7900/UDP"
echo
ss -tulpen | grep -E '(:22|:80|:81|:109|:143|:222|:443|:4443|:777|:7100|:79[0-9]{2})' || true
echo

read -rp "Reboot sekarang? (Y/n): " RBT
if [[ "${RBT:-Y}" =~ ^[Yy]$ ]]; then
  echo "Rebooting in 5s…"; sleep 5; /sbin/reboot
else
  echo "Selesai. Logout/login kembali lalu jalankan: menu"
fi
