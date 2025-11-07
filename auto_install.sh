#!/usr/bin/env bash
set -e

echo "[*] Mengkloning repo konfigurasi..."
rm -rf Konfigurasi-VPS-Baru
git clone https://github.com/diditaditia66/Konfigurasi-VPS-Baru.git

cd Konfigurasi-VPS-Baru
chmod +x install_restore.sh

echo "[*] Menjalankan installer..."
bash install_restore.sh
