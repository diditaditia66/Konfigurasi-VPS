#!/usr/bin/env bash
# ------------------------------------------------------------------------------
#  install_restore.sh — Cartenz VPN Premium (Extended, aligned with upstream)
#  Tujuan: Menyamakan instalasi & port dengan setup.sh upstream secara presisi:
#   - OpenSSH 22
#   - SSH WebSocket 80 / 443
#   - Stunnel4 222, 777  (TIDAK pakai 443)
#   - Dropbear 109, 143
#   - Nginx 81
#   - Badvpn UDP 7100–7900
#   - XRAY WS 80/443 + gRPC 443
#   - IPSec + SSTP
#  Fitur: domain random/manual, cleanup konfigurasi lama, firewall, auto-menu,
#         health checks, dan output ringkasan.
# ------------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ======== UI & LOG ========
C0='\033[0m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; W='\033[97m'
log(){ echo -e "${C}[*]${C0} $*"; }
ok(){ echo -e "${G}[OK]${C0} $*"; }
warn(){ echo -e "${Y}[WARN]${C0} $*"; }
err(){ echo -e "${R}[ERR]${C0} $*" >&2; }
TRAP_CLEANUP(){ warn "Terjadi error pada baris $1. Lihat log jika ada."; }
trap 'TRAP_CLEANUP $LINENO' ERR

LOG_FILE="/root/log-install.txt"
touch "$LOG_FILE"

# ======== Guard & OS ========
[[ $EUID -eq 0 ]] || { err "Jalankan sebagai root"; exit 1; }
if [[ -f /etc/os-release ]]; then . /etc/os-release; ok "OS: $PRETTY_NAME"; fi
command -v systemd-detect-virt >/dev/null && [[ "$(systemd-detect-virt)" == "openvz" ]] && { err "OpenVZ tidak didukung"; exit 1; }

# ======== Util ========
aptx(){ apt-get update -y; apt-get install -y --no-install-recommends "$@"; }
svc_on(){
  local s="$1"
  systemctl daemon-reload || true
  systemctl enable "$s" >/dev/null 2>&1 || true
  systemctl restart "$s" || systemctl start "$s" || true
  if systemctl is-active --quiet "$s"; then ok "Service $s aktif"; else err "Service $s TIDAK aktif"; fi
}
file_has(){ local f="$1" p="$2"; [[ -f "$f" ]] && grep -qE "$p" "$f"; }

# ======== Domain ========
echo -e "${W}=== Pengaturan Domain ===${C0}"
echo "1) Domain Random (Cloudflare API vendor)"
echo "2) Masukkan Domain sendiri"
read -rp "Pilih [1/2]: " DNS_OPT

mkdir -p /etc/xray /etc/v2ray
: > /etc/xray/domain
: > /etc/v2ray/domain
: > /etc/xray/scdomain
: > /etc/v2ray/scdomain

if [[ "${DNS_OPT}" == "1" ]]; then
  log "Generate domain random via vendor…"
  curl -fsSL https://autoscript.caliphdev.com/ssh/cf.sh | bash
  DOMAIN="$(cat /etc/xray/domain 2>/dev/null || true)"
  [[ -n "${DOMAIN:-}" ]] || { err "Gagal mendapatkan domain dari vendor"; exit 1; }
else
  read -rp "Masukkan domain (contoh: vpn.example.com): " DOMAIN
  [[ -n "${DOMAIN}" ]] || { err "Domain kosong"; exit 1; }
  echo "IP=${DOMAIN}" > /var/lib/ipvps.conf
  for f in /root/scdomain /etc/xray/scdomain /etc/xray/domain /etc/v2ray/domain /root/domain; do
    echo "${DOMAIN}" > "$f"
  done
fi
ok "Domain VPN: $DOMAIN"

# ======== Paket dasar ========
log "Install paket dasar…"
aptx curl wget git jq tar unzip rsync gnupg ca-certificates lsb-release net-tools ufw neofetch nginx dropbear stunnel4

# ======== Cleanup konflik lama ========
log "Membersihkan konfigurasi & layanan lama…"
systemctl stop nginx stunnel4 xray ws-stunnel cartenz-panel 2>/dev/null || true
rm -f /etc/nginx/conf.d/xray.conf 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/xray.conf 2>/dev/null || true
rm -f /etc/systemd/system/ws-stunnel.service 2>/dev/null || true
# Optional: hapus vhost panel lama yang pakai 443 supaya 80/443 bebas
rm -f /etc/nginx/sites-enabled/cartenz-panel.conf 2>/dev/null || true
systemctl daemon-reload || true

# ======== Dropbear (seed, nanti vendor tambahkan 143 juga) ========
log "Konfigurasi Dropbear (seed port 109)…"
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

# ======== Stunnel — PASTIKAN 222 & 777 (bukan 443) ========
log "Set Stunnel pada port 222 & 777…"
mkdir -p /etc/stunnel
cat >/etc/stunnel/stunnel.conf <<'EOF'
foreground = no
pid = /var/run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
# Snakeoil cert cukup, upstream tidak pakai 443 untuk stunnel
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

# ======== NGINX panel di 81 (sesuai upstream) ========
log "Siapkan Nginx untuk panel di port 81…"
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
nginx -t && systemctl restart nginx || true
systemctl is-active --quiet nginx && ok "nginx aktif (port 81)" || warn "nginx belum aktif"

# ======== Jalankan installer vendor (persis upstream) ========
log "Install SSH/VPN (vendor)…"
cd /root
wget -q https://autoscript.caliphdev.com/ssh/ssh-vpn.sh && chmod +x ssh-vpn.sh && ./ssh-vpn.sh

log "Install XRAY (vendor)…"
wget -q https://autoscript.caliphdev.com/xray/ins-xray.sh && chmod +x ins-xray.sh && ./ins-xray.sh

log "Install SSH-WS (vendor)…"
wget -q https://autoscript.caliphdev.com/sshws/insshws.sh && chmod +x insshws.sh && ./insshws.sh

log "Install IPSec & SSTP (vendor)…"
wget -q https://autoscript.caliphdev.com/ipsec/ipsec.sh && chmod +x ipsec.sh && ./ipsec.sh
wget -q https://autoscript.caliphdev.com/sstp/sstp.sh && chmod +x sstp.sh && ./sstp.sh

# ======== Auto MENU saat login root (upstream style) ========
log "Aktifkan auto-menu saat login…"
cat >/root/.profile <<'EOF'
if [ "$BASH" ] && [ -f ~/.bashrc ]; then . ~/.bashrc; fi
mesg n || true
clear
neofetch
echo "Type 'menu' to display the vpn menu"
EOF
chmod 644 /root/.profile

# ======== Firewall (mirror upstream ports) ========
log "Konfigurasi firewall (UFW)…"
ufw --force enable || true
ufw allow 22/tcp
ufw allow 80,443/tcp
ufw allow 81/tcp
ufw allow 109,143/tcp
ufw allow 222,777/tcp
ufw allow 7100:7900/udp

# ======== Health check & Ringkasan ========
echo -e "\n${W}==============================${C0}"
echo -e "${W}  RINGKASAN INSTALASI (MATCH) ${C0}"
echo -e "${W}==============================${C0}"
for s in nginx xray stunnel4 dropbear; do
  if systemctl is-active --quiet "$s"; then ok "$s : active"; else err "$s : INACTIVE"; fi
done

echo -e "\n${W}Port (seharusnya):${C0}"
echo " - OpenSSH   : 22"
echo " - SSH-WS    : 80 / 443"
echo " - Stunnel4  : 222, 777"
echo " - Dropbear  : 109, 143"
echo " - Nginx     : 81"
echo " - Badvpn    : 7100–7900/UDP"
echo " - XRAY      : WS 80/443 + gRPC 443"

echo -e "\n${W}Cek cepat (port listen):${C0}"
ss -tulpen | grep -E '(:22|:80|:81|:109|:143|:222|:443|:777|:7100|:79[0-9]{2})' || true
echo

# ======== Simpan Catatan ========
{
  echo "Cartenz Install — $(date)"
  echo "Domain VPN : ${DOMAIN}"
  echo "Services   : nginx, xray, stunnel4, dropbear, ipsec, sstp, sshws"
} >> "$LOG_FILE"

# ======== Reboot ========
read -rp "Reboot sekarang? (Y/n): " RBT
if [[ "${RBT:-Y}" =~ ^[Yy]$ ]]; then
  echo "Rebooting in 5s…"; sleep 5; /sbin/reboot
else
  echo "Silakan logout/login kembali, lalu ketik: menu"
fi
