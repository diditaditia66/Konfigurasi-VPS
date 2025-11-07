#!/usr/bin/env bash
# auto_install.sh — Instal otomatis Cartenz VPN Premium dari repo GitHub
# Diuji di Ubuntu/Debian (20.04/22.04/24.04, 11/12)

set -euo pipefail
IFS=$'\n\t'

C0='\033[0m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; B='\033[36m'
log(){ echo -e "${B}[*]${C0} $*"; }
ok(){ echo -e "${G}[OK]${C0} $*"; }
warn(){ echo -e "${Y}[WARN]${C0} $*"; }
err(){ echo -e "${R}[ERR]${C0} $*" >&2; }

REPO_URL="https://github.com/diditaditia66/Konfigurasi-VPS-Baru.git"
REPO_DIR="Konfigurasi-VPS-Baru"

# Pastikan root
if [[ $EUID -ne 0 ]]; then
  err "Script ini harus dijalankan sebagai root!"
  exit 1
fi

# Cek ketersediaan git
if ! command -v git >/dev/null 2>&1; then
  log "Git belum terpasang. Menginstal git..."
  apt-get update -y && apt-get install -y git
  ok "Git terpasang."
fi

# Hapus folder lama bila ada
if [[ -d "$REPO_DIR" ]]; then
  warn "Folder $REPO_DIR sudah ada, menghapus dulu..."
  rm -rf "$REPO_DIR"
fi

# Clone repo dari GitHub
log "Meng-clone repo konfigurasi dari GitHub..."
git clone "$REPO_URL" "$REPO_DIR" || { err "Gagal clone repo!"; exit 1; }
ok "Repo berhasil di-clone."

# Jalankan installer
cd "$REPO_DIR"
chmod +x install_restore.sh
log "Menjalankan script install_restore.sh..."
bash install_restore.sh

ok "Instalasi selesai!"
echo -e "\n${G}Ketik 'menu' untuk membuka panel konfigurasi VPN.${C0}\n"
