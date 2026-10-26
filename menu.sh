#!/usr/bin/env bash
#
# menu.sh — menu interaktif mesin-setup
#
# Opsi:
#   1) Install keseluruhan  → jalankan setup.sh (pulihkan mesin dari nol:
#                              paket dasar, Google Chrome, Brave wrapper
#                              --no-sandbox, Tailscale, OpenCode, upterm,
#                              web toko roti, tunnel, GitHub). Kalau setup.sh
#                              belum ada — misal habis reset, yang di-download
#                              cuma menu.sh — filenya diambil otomatis dari
#                              GitHub dulu.
#   2) Generate SSH         → upterm host --accept -- bash
#                              (cetak command SSH temporer — siapa pun yang
#                              command-nya dipegang bisa ikut shell yang sama.
#                              Sesi mati sendiri kalau host-nya keluar.)
#   3) Keluar
#
# Pemakaian:
#   bash /root/menu.sh        (jalur pendek; symlink ke mesin-setup/menu.sh)
#   bash menu.sh              (dari dalam repo)
#
# Restore dari nol (repo ini PUBLIK — tanpa token sama sekali):
#   curl -fsSL -o menu.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/menu.sh
#   bash menu.sh              → pilih 1 (setup.sh ikut diunduh otomatis)
#
# Atau langsung setup.sh saja:
#   curl -fsSL -o setup.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/setup.sh
#   bash setup.sh
#
set -uo pipefail   # tanpa -e: menu tidak boleh mati cuma karena satu opsi gagal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SETUP_SH="${SCRIPT_DIR}/setup.sh"
[ -f "$SETUP_SH" ] || SETUP_SH="/root/setup.sh"
SETUP_URL="https://raw.githubusercontent.com/AgungAG/mesin-setup/main/setup.sh"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# Unduh URL ke file — curl dulu, wget sebagai cadangan (sama seperti setup.sh).
fetch_to() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        return 1
    fi
}

# --- Opsi 1 ------------------------------------------------------------
# Pastikan setup.sh ada sebelum dijalankan; kalau belum → ambil sendiri dari
# GitHub. Tujuannya /root/setup.sh supaya langkah ensure_setup_repo di dalam
# setup.sh mengenali file hasil unduhan ini (pindah ke repo + symlink).
ensure_setup_sh() {
    [ -f "$SETUP_SH" ] && return 0
    warn "setup.sh tidak ditemukan → di-download otomatis dari GitHub..."
    if fetch_to "$SETUP_URL" "$SETUP_SH"; then
        log "setup.sh → $SETUP_SH"
        return 0
    fi
    rm -f "$SETUP_SH"   # sisa file gagal (kosong/terpotong) jangan ditinggal
    warn "download setup.sh gagal → cek koneksi ke raw.githubusercontent.com"
    return 1
}

install_all() {
    ensure_setup_sh || return 0
    log "Install keseluruhan: bash $SETUP_SH"
    bash "$SETUP_SH"
}

# --- Opsi 2 ------------------------------------------------------------
# `--accept` = tanpa otorisasi: siapa pun yang pegang command SSH-nya bisa
# masuk. Berjalan di foreground — sesi hidup selama bash-nya hidup.
host_session() {
    if ! command -v upterm >/dev/null 2>&1; then
        warn "upterm belum terinstall → jalankan opsi 1 dulu"
        return 0
    fi
    log "Mulai sesi: upterm host --accept -- bash"
    echo "Salin command SSH yang dicetak (contoh: ssh xxxx@uptermd.upterm.dev:2222)"
    echo "→ bagikan ke yang mau ikut sesi ini. Akhiri dengan 'exit' / Ctrl-D."
    echo
    upterm host --accept -- bash
}

# --- Menu --------------------------------------------------------------
while true; do
    cat <<'EOF'

  +-- mesin-setup ----------------------------------+
  |  1) Install keseluruhan (setup.sh)             |
  |  2) Generate SSH  (upterm host --accept -- bash)|
  |  3) Keluar                                     |
  +------------------------------------------------+
EOF
    read -r -p "  Pilih [1-3]: " pilih || { echo; pilih=3; }
    case "$pilih" in
        1)      install_all ;;
        2)      host_session ;;
        3|q|Q)  log "Keluar."; exit 0 ;;
        *)      warn "Pilihan tidak dikenal: '$pilih' (pakai 1/2/3)" ;;
    esac
done
