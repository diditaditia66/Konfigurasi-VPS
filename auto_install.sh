#!/usr/bin/env bash
# auto_install.sh — bootstrap satu baris untuk Cartenz VPN Premium
# Pakai: bash <(curl -fsSL https://raw.githubusercontent.com/diditaditia66/Konfigurasi-VPS-Baru/main/auto_install.sh)

set -euo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

REPO_URL_DEFAULT="https://github.com/diditaditia66/Konfigurasi-VPS-Baru.git"
REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
REPO_DIR="${REPO_DIR:-Konfigurasi-VPS-Baru}"

C0='\033[0m'; G='\033[32m'; R='\033[31m'; Y='\033[33m'; W='\033[97m'
ok(){ echo -e "${G}[OK]${C0} $*"; }
err(){ echo -e "${R}[ERR]${C0} $*" >&2; }
ask(){ local p="$1" v; read -rp "$p" v; echo "$v"; }

if [[ $EUID -ne 0 ]]; then err "Jalankan sebagai root"; exit 1; fi

echo
echo -e "${W}=== Cartenz VPN Premium — Auto Install ===${C0}"
PANEL_DOMAIN=$(ask "Masukkan domain Panel (contoh: panel.cartenz-vpn.my.id): ")
VPN_DOMAIN=$(ask   "Masukkan domain VPN   (contoh: vpn.cartenz-vpn.my.id)  : ")
read -rp "Email Certbot (kosongkan untuk admin@${VPN_DOMAIN}): " CERTBOT_EMAIL
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@${VPN_DOMAIN}}"

apt-get update -y
apt-get install -y --no-install-recommends git ca-certificates curl wget

if [[ -d "$REPO_DIR/.git" ]]; then
  echo "Repo sudah ada: $REPO_DIR → git pull"
  git -C "$REPO_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$REPO_DIR"
fi

chmod +x "$REPO_DIR/install_restore.sh"

# jalankan installer dengan ENV untuk skip prompt
PANEL_DOMAIN="$PANEL_DOMAIN" VPN_DOMAIN="$VPN_DOMAIN" CERTBOT_EMAIL="$CERTBOT_EMAIL" \
  bash "$REPO_DIR/install_restore.sh"
