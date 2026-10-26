#!/usr/bin/env bash
#
# menu.sh — menu interaktif mesin-setup
#
# Opsi:
#   1) Install keseluruhan  → jalankan setup.sh penuh (restore mesin dari nol:
#                              paket dasar, Google Chrome, Brave wrapper
#                              --no-sandbox, Tailscale, OpenCode, upterm,
#                              web toko roti, tunnel, GitHub). Kalau setup.sh
#                              belum ada — misal habis reset, yang di-download
#                              cuma menu.sh — filenya diambil otomatis dari
#                              GitHub dulu.
#   2) apt update + gh + opencode + Brave + upterm
#                           → `bash setup.sh tools` (mode ringan): refresh
#                              repo lalu pasang gh, opencode, Brave, upterm.
#                              Tidak menyentuh service/supervisor → aman
#                              kapan saja.
#   3) Generate SSH         → upterm host --accept -- bash. Begitu command
#                              SSH tercetak, OTOMATIS disalin ke clipboard
#                              (OSC 52 ke terminal + xclip di desktop VNC)
#                              dan disimpan ke /root/upterm-ssh.txt → tinggal
#                              paste di mesin lain. Sesi mati kalau host-nya
#                              keluar.
#   4) Keluar
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
SSH_FILE="/root/upterm-ssh.txt"

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

# Penanda bahwa file itu benar-benar setup.sh (bukan file yang tertukar).
SETUP_MARKER='setup.sh — Restore mesin ini dari nol'
SETUP_MIN_BYTES=10000   # setup.sh utuh ±54 KB; di bawah itu pasti terpotong

# Cek isi file, bukan cuma keberadaannya. Cek `[ -f ]` saja ternyata tidak
# cukup: kalau setup.sh pernah ketimpa salinan menu.sh (ukurannya sama persis
# dengan menu.sh), opsi 1/2 akan "jalan" tapi tidak melakukan apa-apa karena
# yang dipanggil justru menu lagi.
setup_sh_valid() {
    [ -f "$SETUP_SH" ] || return 1
    grep -qF "$SETUP_MARKER" "$SETUP_SH" 2>/dev/null || return 1
    [ "$(wc -c < "$SETUP_SH")" -ge "$SETUP_MIN_BYTES" ] || return 1
    return 0
}

# Pastikan setup.sh ada DAN isinya benar; kalau tidak → ambil sendiri dari
# GitHub (repo publik).
ensure_setup_sh() {
    if setup_sh_valid; then
        return 0
    fi
    if [ -f "$SETUP_SH" ]; then
        warn "setup.sh ada tapi isinya salah (tertukar/rusak/terpotong) → di-download ulang..."
        rm -f "$SETUP_SH"
    else
        warn "setup.sh tidak ditemukan → di-download otomatis dari GitHub..."
    fi
    if fetch_to "$SETUP_URL" "$SETUP_SH" && setup_sh_valid; then
        log "setup.sh → $SETUP_SH"
        return 0
    fi
    rm -f "$SETUP_SH"   # sisa file gagal (kosong/terpotong/salah isi) jangan ditinggal
    warn "download setup.sh gagal → cek koneksi ke raw.githubusercontent.com"
    return 1
}

# --- Opsi 1 ------------------------------------------------------------
install_all() {
    ensure_setup_sh || return 0
    log "Install keseluruhan: bash $SETUP_SH"
    laporkan_status bash "$SETUP_SH"
}

# --- Opsi 2 ------------------------------------------------------------
# Mode ringan setup.sh: apt update + Brave + upterm. Tanpa setup penuh.
install_tools() {
    ensure_setup_sh || return 0
    laporkan_status bash "$SETUP_SH" tools
}

# Jalankan setup.sh lalu TAMPILKAN kalau dia berhenti dengan status gagal.
# Dulu statusnya dibuang begitu saja → langkah yang gagal (mis. install Brave)
# cuma meninggalkan satu baris warning yang tenggelam di antara log panjang.
laporkan_status() {
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "setup.sh berhenti dengan status $rc → baca pesan error/warning di atas"
        warn "  jalankan ulang: bash $SETUP_SH ${2:-}"
    else
        log "Selesai tanpa error (status 0)"
    fi
    return 0
}

# --- Opsi 3 ------------------------------------------------------------
# Sesi upterm dibungkus `script` (pty) supaya keluarannya bisa DIBACA sambil
# tetap interaktif. Begitu baris command SSH muncul di log, watcher menyalinnya:
#   1. OSC 52  → clipboard TERMINAL yang memutar sesi ini (ikut lewat SSH,
#                 asal klien terminalnya mendukung OSC 52)
#   2. xclip   → clipboard desktop VNC (kalau DISPLAY ada & xclip terpasang)
#   3. file    → /root/upterm-ssh.txt sebagai cadangan tempel manual
host_session() {
    if ! command -v upterm >/dev/null 2>&1; then
        warn "upterm belum terinstall → jalankan opsi 1 atau 2 dulu"
        return 0
    fi
    if ! command -v script >/dev/null 2>&1; then
        warn "perintah 'script' tidak ada → command SSH harus disalin manual"
        upterm host --accept -- bash
        return 0
    fi

    local sess_log watcher cmd b64 i
    sess_log=$(mktemp)
    log "Mulai sesi: upterm host --accept -- bash"
    echo "Begitu command SSH tercetak, otomatis:"
    echo "  • disalin ke clipboard — tinggal paste di mesin lain"
    echo "  • disimpan di $SSH_FILE"
    echo

    # watcher: polling cepat (0,5 detik) supaya command tertangkap walau
    # sesinya sangat singkat; berhenti sendiri setelah ketemu atau 30 detik
    (
        cmd=""
        for i in $(seq 60); do
            cmd=$(grep -ohE 'ssh [A-Za-z0-9]+@uptermd\.upterm\.dev' "$sess_log" 2>/dev/null | head -1 || true)
            [ -n "$cmd" ] && break
            sleep 0.5
        done
        [ -n "$cmd" ] || exit 0

        printf '%s\n' "$cmd" > "$SSH_FILE"

        # OSC 52: base64 tanpa wrap; tulis ke /dev/tty bila ada, kalau tidak
        # (misal dijalankan tanpa terminal) jatuh ke stdout biasa
        b64=$(printf '%s' "$cmd" | base64 -w0 2>/dev/null || printf '%s' "$cmd" | base64)
        { printf '\033]52;c;%s\007' "$b64" > /dev/tty; } 2>/dev/null \
            || printf '\033]52;c;%s\007' "$b64" 2>/dev/null \
            || true

        # cadangan lokal: clipboard X11 (desktop VNC bawaan image)
        if command -v xclip >/dev/null 2>&1; then
            printf '%s' "$cmd" | xclip -selection clipboard 2>/dev/null || true
        fi

        printf '\n\033[1;32m==>\033[0m Command SSH disalin ke clipboard (juga: %s)\n\033[1;92m    %s\033[0m\n' \
            "$SSH_FILE" "$cmd"
    ) &
    watcher=$!

    script -qefc "upterm host --accept -- bash" "$sess_log" || true

    # sesi sudah selesai → beri watcher waktu 3 detik buat menangkap sisa
    # log, lalu hentikan; dia juga berhenti sendiri setelah 30 detik
    for i in 1 2 3 4 5 6; do
        kill -0 "$watcher" 2>/dev/null || break
        sleep 0.5
    done
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    rm -f "$sess_log"
    return 0
}

# --- Menu --------------------------------------------------------------
while true; do
    cat <<'EOF'

  +-- mesin-setup ----------------------------------+
  |  1) Install keseluruhan (setup.sh)              |
  |  2) apt update + gh + opencode + Brave + upterm |
  |  3) Generate SSH (upterm) + copy clipboard      |
  |  4) Keluar                                      |
  +-------------------------------------------------+
EOF
    read -r -p "  Pilih [1-4]: " pilih || { echo; pilih=4; }
    case "$pilih" in
        1)      install_all ;;
        2)      install_tools ;;
        3)      host_session ;;
        4|q|Q)  log "Keluar."; exit 0 ;;
        *)      warn "Pilihan tidak dikenal: '$pilih' (pakai 1/2/3/4)" ;;
    esac
done
