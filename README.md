# Konfigurasi VPS – Cartenz VPN Premium

Repositori ini menyimpan konfigurasi dan skrip untuk men-setup layanan berikut di VPS baru:
- Panel web “Cartenz VPN Premium” (Node.js + Express + panel akun) pada port 8080, di-reverse proxy lewat Nginx + TLS.
- Layanan VPN: Xray (VMess/VLess/Trojan/Shadowsocks WS & gRPC), Dropbear (SSH), Stunnel4 (SSH SSL), WebSocket tunneling, Squid (opsional).
- Skrip add/trial: usernew, add-ws, trialvmess, add-vless, add-tr, trialssws, dst.

## Struktur repo yang disarankan  

Konfigurasi-VPS/
├─ cartenz-panel/ # kode panel (server.cjs, public/, package.json)
├─ usr-bin/ # skrip sistem untuk add/trial akun
├─ etc-overlay/ # template konfigurasi (nginx site, systemd unit, dll)
├─ install_restore.sh # installer otomatis untuk VPS baru
└─ README.md # panduan ini

> *Keamanan:* Jangan commit kunci privat (.pem/.key) atau data rahasia lainnya. Sertifikat akan diterbitkan ulang di VPS baru.

## Prasyarat  
1. Domain kamu (contoh: `cartenz-vpn.my.id`) sudah diarahkan ke IP VPS baru.  
2. Port 80 & 443 terbuka (untuk HTTPS).  
3. Akses root atau sudo tersedia.  
4. Git dapat menjalankan clone dari repo ini.

## Cara cepat instal  
```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/<username>/<repo>.git
cd <repo>
chmod +x install_restore.sh
sudo ./install_restore.sh --domain cartenz-vpn.my.id --email you@example.com

Script ini akan menginstall semua layanan, restaurasi konfigurasi, setup reverse proxy + TLS, deploy panel dan VPN.

##Setelah instalasi
- Akses panel di: https://cartenz-vpn.my.id
- Login default: admin / ganti_password (ubah segera).
- Cek layanan dengan:
  sudo systemctl status nginx xray dropbear stunnel4 ws-stunnel cartenz-panel

##Tips variabel
- SESSION_SECRET untuk panel session (bisa di‐override via systemd override).
- PORT untuk panel internal (default 8080) — tidak perlu diubah kecuali kamu tahu yang kamu lakukan.

##Backup & restore
- Simpan skrip dan konfigurasi non-rahasia ke repo ini.
- Jangan simpan kunci privat atau sertifikat lama.
- Untuk migrasi ke VPS baru: cukup jalankan install_restore.sh.

##Troubleshooting
- Panel “unauthorized” → pastikan akses lewat domain, bukan IP saja; cek zona waktu (timedatectl).
- Output skrip trial/add berantakan → gunakan browser biasa atau disable ANSI art di skrip.
- Certbot gagal → cek sudo nginx -t, port 80 terbuka, DNS sudah propagasi.
