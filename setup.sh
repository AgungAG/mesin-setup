#!/usr/bin/env bash
#
# setup.sh — Restore mesin ini dari nol (setelah reset)
#
# Semua langkah IDEMPOTEN: boleh dijalankan berkali-kali, hasilnya tetap sama.
#
# Yang disetup:
#   0. Repo Google Chrome : buang sisa keyring+sources.list lama, pasang ulang
#                       — jalan PALING AWAL, sebelum apt update pertama
#                       (lihat "Kenapa duluan" di ensure_google_chrome_repo)
#   1. Paket dasar    : git, tmux, jq, curl, ca-certificates
#                       + gh dari repo resmi GitHub CLI (cli.github.com)
#   2. Google Chrome  : google-chrome-stable (bisa dimatikan: INSTALL_CHROME=0)
#   2b. Brave         : brave-browser dari repo resmi Brave + wrapper `brave`
#                       yang selalu menambah --no-sandbox (container jalan sebagai
#                       root → sandbox Chromium menolak start). Bisa dimatikan:
#                       INSTALL_BRAVE=0
#   2c. Upterm        : upterm — bikin sesi SSH temporer (`upterm host --accept
#                       --skip-host-key-check -- bash`) biar orang lain bisa ikut
#                       di shell yang sama.
#                       Dipakai oleh menu interaktif menu.sh (opsi 3).
#   2d. TeraBox       : jendela aplikasi ANTI BLANK — wrapper `terabox` membuka
#                       www.terabox.com lewat flag --app Chrome/Brave dengan
#                       --no-sandbox (container root) + profil khusus
#                       (~/.config/terabox-app) + anti-crash renderer, plus
#                       ikon desktop. Buka: `terabox` atau ikon TeraBox.
#   3. Tailscale      : install + tailscaled jalan + login (--ssh)
#   4. OpenCode       : install + PATH di .bashrc + service background
#                       (`opencode serve --service`) dijaga supervisor
#                       (25-opencode.conf) — bot Telegram butuh service ini
#                       buat menjawab, jadi sudah nyala sejak boot
#   4a. Alias         : oce → opencode, age → bash /root/menu.sh — ditulis ke
#                       /root/.bashrc (idempoten; ikut di mode tools)
#   5. SSH            : TIDAK dipasang — akses masuk lewat Tailscale SSH
#   6. Web toko roti  : http.server :8000 di /root/toko-roti
#   7. Akses online   : tailscale serve (URL tetap) + tunnel cloudflared (opsional)
#   8. GitHub         : gh login dari GH_TOKEN, identitas git, auto-commit toko-roti
#   9. Bot Telegram   : bot AI (@..._bot) → model gratis OpenCode, dijaga
#                       supervisor (30-tgbot.conf). bot.py disimpan sebagai
#                       kode BERSIH di repo ini; rahasia TIDAK ikut ke GitHub —
#                       token/chat id dibuat lokal dari env / .machine-secrets.
#   10. Keep-alive    : session-keepalive (40-keepalive.conf) — jalan terus
#                       sejak boot, bikin mesin SELALU terlihat dipakai manusia
#                       supaya sesi tidak keluar otomatis: screensaver/DPMS X
#                       dimatikan (bawaan image blank tiap 600 detik), pointer
#                       digerakkan 2px tiap siklus (xdotool), tmux session
#                       dibuat lagi kalau hilang, dan Tailscale login ulang
#                       otomatis kalau keburu keluar (key expiry).
#
# CARA KERJA PENTING:
#   tailscaled, web server, tunnel, service OpenCode, dan bot Telegram
#   dijaga SUPERVISORD — yang memang sudah jalan sejak container hidup dan
#   auto-restart. Bukan `nohup &` manual. Jadi service ikut bangun sendiri
#   tiap mesin hidup, tanpa diapa-apain — termasuk bot Telegram + service
#   OpenCode yang diajaknya (langsung bisa menjawab begitu setup selesai).
#   Desktop/VNC/nginx itu urusan image bawaan — script ini tidak menyentuhnya.
#
# SSH:
#   TIDAK ada openssh-server/sshd — percuma, karena akses masuk lewat Tailscale
#   SSH yang ditangani langsung oleh tailscaled, bukan oleh sshd. openssh-client
#   tetap ada (buat git ssh dan `tailscale ssh`). Alasan lengkap: remove_sshd.
#
# Pemakaian:
#   bash setup.sh               Setup penuh dari nol (Full Install).
#   bash setup.sh tools         Mode ringan (Only Tools): apt update + install
#                               gh, opencode, Brave, upterm, TeraBox, alias
#                               oce/age + setup bot Telegram (conf supervisor &
#                               start bot-nya saja — service lain tidak
#                               disentuh). Dipakai menu.sh opsi 2.
#   Menu interaktif (Full Install / Only Tools / Generate SSH (Upterm) /
#   list & stop sesi upterm / keluar):
#     bash /root/menu.sh        (atau singkat: age)
#
# RESTORE DARI NOL (mesin baru / habis reset, /root sudah bersih):
#   curl -fsSL -o setup.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/setup.sh
#   bash setup.sh
#   Repo setup.sh ini PUBLIK supaya bisa diambil tanpa token sama sekali.
#   Yang dibutuhkan tinggal: TS_AUTHKEY / GH_TOKEN (isi via env
#   atau tulis ke /root/.machine-secrets dengan format NAME=value, chmod 600).
#   Repo toko-roti PRIVAT → butuh GH_TOKEN untuk clone/push.
#   TIDAK ada password root: akses masuk pakai Tailscale SSH (login Tailscale).
#
# Environment variable (semua opsional; juga bisa dititip di /root/.machine-secrets
# supaya tidak perlu diketik ulang tiap restore):
#   TS_AUTHKEY=tskey-auth-xxxx  Login Tailscale otomatis tanpa klik link.
#                               Ambil dari: https://login.tailscale.com/admin/settings/keys
#   GH_TOKEN=ghp_xxxx           Token GitHub supaya gh login otomatis.
#   INSTALL_CHROME=0           Lewati install google-chrome-stable (default 1).
#                               Repo Chrome-nya tetap dipasang di langkah 0.
#   INSTALL_BRAVE=0            Lewati install brave-browser (default 1).
#                               Repo Brave-nya tetap dipasang, dan wrapper
#                               `brave` (--no-sandbox) tetap dibuat kalau binary
#                               sudah ada dari install sebelumnya.
#   SITE_REPO=AgungAG/toko-roti Repo tujuan push backup toko-roti.
#   TG_BOT_TOKEN=12345:AA... Token bot Telegram (dari @BotFather) — RAHASIA,
#                               jangan taruh di GitHub. Simpan juga ke
#                               /root/.machine-secrets biar ikut pulih tiap reset.
#   TG_CHAT_IDS=123456789     Chat ID yang diizinkan pakai bot (pisah koma/spasi).
#                               Ambil ID: kirim /start ke bot, balasannya
#                               memuat "ID Anda: <angka>".
#   SITE_PORT=8000              Port web toko roti (default 8000).
#   USE_CLOUDFLARED=0           Matikan tunnel publik (default: 1 = aktif).
#   TAKE_TAILSCALE=0            Tunda ambil-alih tailscaled ke supervisor.
#                               Dipakai kalau ada sesi Tailscale SSH aktif yang
#                               tidak boleh diputus. Default: 1 (langsung pindah).
#                               Ambil-alih nanti:  TAKE_TAILSCALE=1 bash setup.sh
#                               Dianjurkan dari dalam tmux (biar sesi nggak ikut
#                               mati); kalau dari sesi biasa, log-nya otomatis
#                               dialihkan ke /root/setup-takeover.log.
#   DEV_SESSION=oce             Nama tmux session yang disiapkan.
#   KEEPALIVE_INTERVAL=30       Jeda (detik) siklus session-keepalive —
#                               gerak pointer + cek layar/tmux/Tailscale.
#                               Default 60; mis. 300 kalau mau lebih jarang.
#
set -euo pipefail

# ---------- Konfigurasi ----------
OPENCODE_DIR="/root/.opencode/bin"
SITE_DIR="/root/toko-roti"
SITE_PORT="${SITE_PORT:-8000}"
USE_CLOUDFLARED="${USE_CLOUDFLARED:-1}"
TAKE_TAILSCALE="${TAKE_TAILSCALE:-1}"
DEV_SESSION="${DEV_SESSION:-oce}"

SECRET_FILE="/root/.machine-secrets"
SUPERVISOR_DIR="/etc/supervisor/conf.d"
SUPERVISOR_RUN="/var/run/supervisor.sock"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
TUNNEL_URL_FILE="/root/cloudflared-url.txt"
KASIR_URL_FILE="/root/kasir-url.txt"
HANDOVER_LOG="/root/setup-takeover.log"

TS_AUTHKEY="${TS_AUTHKEY:-}"
GH_TOKEN="${GH_TOKEN:-}"
SITE_REPO="${SITE_REPO:-AgungAG/toko-roti}"
INSTALL_CHROME="${INSTALL_CHROME:-1}"
INSTALL_BRAVE="${INSTALL_BRAVE:-1}"
UPTERM_BIN="/usr/local/bin/upterm"

# Bot Telegram — rahasia dibaca dari env atau $SECRET_FILE (bukan dari repo)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_IDS="${TG_CHAT_IDS:-}"
TG_BOT_DIR="/root/tg-opencode-bot"
# Tempat bot.py di repo ini (script biasanya dijalankan lewat symlink
# /root/setup.sh → resolve dulu biar ketemu repo-nya)
TG_BOT_SRC="$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")/bot-telegram"
TG_BOT_RAW="https://raw.githubusercontent.com/AgungAG/mesin-setup/main/bot-telegram/bot.py"

# Hasil yang dicetak di ringkasan akhir
SERVE_URL=""
TUNNEL_URL=""
KASIR_URL=""

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# Ambil isi URL ke stdout. curl dulu (sudah dipakai di seluruh script),
# wget sebagai cadangan kalau curl belum terpasang.
fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - "$1"
    else
        return 1
    fi
}

# apt update yang tidak mematikan script: repo pihak ketiga yang bermasalah
# (mis. keyring hilang setelah reset) sebaiknya tidak ikut membatalkan setup.
apt_update() {
    if ! $SUDO apt-get update -qq; then
        warn "apt update ada error → tetap dilanjut (cek baris error di atas)"
    fi
}

# Script ini biasanya jalan sebagai root. `sudo` hanya dipakai kalau bukan root
# DAN sudo tersedia — biar tidak gagal di container minimal yang tanpa sudo.
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# =========================================================
# 0. SECRET
# =========================================================
# Supaya reset tidak bikin lupa token: simpan sekali, baca lagi.
#
# PENTING: nilai dari ENV harus MENANG atas isi file. File bisa berisi key lama
# yang sudah expired/revoke, sementara user mungkin baru pass key BARU lewat
# env (TS_AUTHKEY=... GH_TOKEN=... bash setup.sh). Tanpa penyimpanan ini,
# `. "$SECRET_FILE"` menimpa env secara diam-diam → key baru tidak pernah
# dipakai, dan malah tersimpan kembali sebagai key lama oleh save_secrets.
load_secrets() {
    local env_ts="${TS_AUTHKEY:-}" env_gh="${GH_TOKEN:-}"
    local env_tg="${TG_BOT_TOKEN:-}" env_tgc="${TG_CHAT_IDS:-}"
    if [ -r "$SECRET_FILE" ]; then
        set +u
        # shellcheck source=/dev/null
        . "$SECRET_FILE"
        set -u
        log "Secret dibaca dari $SECRET_FILE"
    fi
    # kembalikan nilai env (lebih baru) kalau tadi tertimpa file
    if [ -n "$env_ts" ]; then TS_AUTHKEY="$env_ts"; fi
    if [ -n "$env_gh" ]; then GH_TOKEN="$env_gh"; fi
    if [ -n "$env_tg" ]; then TG_BOT_TOKEN="$env_tg"; fi
    if [ -n "$env_tgc" ]; then TG_CHAT_IDS="$env_tgc"; fi
}

save_secrets() {
    local tmp="${SECRET_FILE}.tmp" var val
    : > "$tmp"
    for var in TS_AUTHKEY GH_TOKEN TG_BOT_TOKEN TG_CHAT_IDS; do
        val="${!var:-}"
        [ -n "$val" ] || continue
        printf '%s=%q\n' "$var" "$val" >> "$tmp"
    done
    if [ -s "$tmp" ]; then
        chmod 600 "$tmp" && mv "$tmp" "$SECRET_FILE"
        log "Secret disimpan di $SECRET_FILE (chmod 600)"
    else
        rm -f "$tmp"
    fi
}

# =========================================================
# 0. BUANG SISA REPO GOOGLE CHROME LAMA — jalan PALING AWAL
# =========================================================
# Dilakukan SEBELUM ensure_google_chrome_repo. Keyring/list Chrome yang korup,
# KUNCI LAWAS (Google pernah rotasi signing key → NO_PUBKEY), atau sisa dari
# image bawaan dibuang dulu, lalu dipasang ulang segar oleh langkah berikutnya.
# Ini pengganti dua command manual yang dulu diketik tiap kali bermasalah:
#   sudo rm -f /etc/apt/sources.list.d/google-chrome.list
#   sudo rm -f /usr/share/keyrings/google-chrome.gpg
#
# Idempoten: kalau keduanya sudah tidak ada, tidak ada yang dihapus.
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
reset_google_chrome_repo() {
    local keyring="/usr/share/keyrings/google-chrome.gpg"
    local list="/etc/apt/sources.list.d/google-chrome.list"

    if [ ! -e "$keyring" ] && [ ! -e "$list" ]; then
        return 0
    fi
    log "Buang repo/keyring Chrome lama → dipasang ulang segar..."
    $SUDO rm -f "$list" "$keyring"
}

# =========================================================
# 0. REPO GOOGLE CHROME — jalan PALING AWAL, sebelum apt update
# =========================================================
# Kenapa duluan? Image ini membawa /etc/apt/sources.list.d/google-chrome.list,
# tapi keyring-nya (/usr/share/keyrings/google-chrome.gpg) ikut hilang tiap
# reset → `apt update` langsung berhenti dengan NO_PUBKEY, dan karena script
# ini pakai `set -e` semua langkah setelahnya ikut mati.
# Jadi: perbaiki keyring dulu, baru apt-get update yang lain.
#
# Ini pengganti dua command manual yang dulu harus diketik tiap reset:
#   wget -q -O - https://dl.google.com/linux/linux_signing_key.pub \
#     | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
#   echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] \
#     http://dl.google.com/linux/chrome/deb/ stable main" \
#     | sudo tee /etc/apt/sources.list.d/google-chrome.list
#
# Idempoten: kalau list + keyring sudah ada, dilewati.
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
ensure_google_chrome_repo() {
    local keyring="/usr/share/keyrings/google-chrome.gpg"
    local list="/etc/apt/sources.list.d/google-chrome.list"
    local key_url="https://dl.google.com/linux/linux_signing_key.pub"

    if [ -s "$keyring" ] && [ -f "$list" ]; then
        log "Repo Google Chrome sudah siap ($list)"
        return 0
    fi

    log "Siapkan repo Google Chrome (biar apt update tidak NO_PUBKEY)..."
    $SUDO mkdir -p /usr/share/keyrings /etc/apt/sources.list.d

    if [ ! -s "$keyring" ]; then
        if ! command -v gpg >/dev/null 2>&1; then
            warn "gpg tidak ada → keyring Google Chrome tidak bisa dibuat"
            warn "  install dulu: apt-get install -y gnupg"
        else
            local tmp
            tmp=$(mktemp)
            if fetch_url "$key_url" > "$tmp.pub" && [ -s "$tmp.pub" ] \
                && gpg --dearmor < "$tmp.pub" > "$tmp.gpg" 2>/dev/null \
                && [ -s "$tmp.gpg" ]; then
                $SUDO install -m 644 "$tmp.gpg" "$keyring"
                log "Keyring Google Chrome → $keyring"
            else
                warn "Ambil key Google Chrome gagal → apt update bisa error NO_PUBKEY"
                warn "  manual: curl -fsSL $key_url | gpg --dearmor -o $keyring"
            fi
            rm -f "$tmp.pub" "$tmp.gpg"
        fi
    fi

    # Source-nya ditulis juga kalau belum ada (mesin benar-benar fresh).
    # arch=amd64 sengaja: repo Chrome memang cuma untuk amd64.
    if [ ! -f "$list" ]; then
        echo "deb [arch=amd64 signed-by=$keyring] http://dl.google.com/linux/chrome/deb/ stable main" \
            | $SUDO tee "$list" >/dev/null
        log "Source Google Chrome → $list"
    fi
}

# =========================================================
# 1. PAKET DASAR
# =========================================================
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
install_packages() {
    local need=() p
    # xclip: buat fitur copy-ke-clipboard di menu.sh opsi 3 (aktif kalau ada
    # DISPLAY — desktop VNC bawaan image; tanpa X tetap terpasang tapi diam).
    # xdotool: tangan "manusia" palsu buat session-keepalive (gerak pointer
    # bolak-balik → timer idle X/aplikasi tidak pernah sampai logout/blank).
    # x11-xserver-utils: xset → matikan screensaver/DPMS X.
    for p in git tmux jq curl ca-certificates xclip xdotool x11-xserver-utils; do
        dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
    done
    if [ "${#need[@]}" -eq 0 ]; then
        log "Paket dasar sudah lengkap (git tmux jq curl ca-certificates xclip xdotool xset)"
        return
    fi
    log "Install paket: ${need[*]}"
    apt_update
    # $SUDO WAJIB: script ini sering dijalankan sebagai user biasa (menu.sh dari
    # home user) → tanpa sudo apt langsung "Permission denied" pada lock file.
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${need[@]}"
}

# gh dipasang dari repo resmi GitHub CLI (cli.github.com), bukan paket Debian
# bawaan → versinya selalu fresh dan di-update oleh GitHub.
# Idempoten: kalau gh + keyring + source-nya sudah ada, dilewati.
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
install_gh() {
    local keyring="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
    local list="/etc/apt/sources.list.d/github-cli.list"

    if command -v gh >/dev/null 2>&1 && [ -s "$keyring" ] && [ -f "$list" ]; then
        log "GitHub CLI sudah terinstall ($(gh --version 2>/dev/null | head -1))"
        return
    fi

    log "Install GitHub CLI dari repo resmi (cli.github.com)..."
    $SUDO mkdir -p -m 755 /etc/apt/keyrings

    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | $SUDO tee "$keyring" >/dev/null

    $SUDO chmod go+r "$keyring"
    $SUDO mkdir -p /etc/apt/sources.list.d

    echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
        | $SUDO tee "$list" >/dev/null

    apt_update
    DEBIAN_FRONTEND=noninteractive $SUDO apt install -y gh
    command -v gh >/dev/null 2>&1 || warn "install gh gagal → cek koneksi ke cli.github.com"
}

# =========================================================
# 2. GOOGLE CHROME
# =========================================================
# Chrome dari repo resmi Google (sudah dipasang di langkah 0), bukan file .deb
# manual. Idempoten: kalau sudah terinstall, dilewati.
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
install_chrome() {
    if [ "$INSTALL_CHROME" != "1" ]; then
        log "Install Chrome dimatikan (INSTALL_CHROME=0)"
        return
    fi
    if dpkg -s google-chrome-stable >/dev/null 2>&1; then
        log "Google Chrome sudah terinstall ($(dpkg-query -W -f='${Version}' google-chrome-stable 2>/dev/null))"
        return
    fi
    log "Install google-chrome-stable..."
    apt_update
    if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y google-chrome-stable; then
        log "Google Chrome terpasang ($(command -v google-chrome-stable || echo '/usr/bin/google-chrome'))"
    else
        warn "Install Chrome gagal → cek koneksi ke dl.google.com, lalu jalankan ulang:"
        warn "    INSTALL_CHROME=1 bash $0"
    fi
}

# =========================================================
# 2b. BRAVE — repo resmi Brave + wrapper --no-sandbox
# =========================================================
# Container ini jalan sebagai root, dan sandbox Chromium (juga dipakai Brave)
# MENOLAK start sebagai root tanpa --no-sandbox. Jadi dua bagian di sini:
#   1. Repo resmi Brave (keyring + deb822 .sources) → `apt install brave-browser`
#      — sama polanya dengan repo Google Chrome di atas.
#   2. Wrapper /usr/local/bin/brave yang selalu menambah --no-sandbox, plus
#      patch baris Exec di .desktop-nya biar ikut jalan dari ikon desktop.
#      Alasan dipisah: flag-nya nempel di wrapper, bukan di binary — jadi
#      upgrade paket tidak menghapusnya.
#
# Idempoten: repo dilewati kalau sudah ada; wrapper ditulis ulang tiap run.
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
ensure_brave_repo() {
    local keyring="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
    local sources="/etc/apt/sources.list.d/brave-browser-release.sources"
    local key_url="https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg"
    local src_url="https://brave-browser-apt-release.s3.brave.com/brave-browser.sources"
    local tmp

    if [ -s "$keyring" ] && [ -f "$sources" ]; then
        log "Repo Brave sudah siap ($sources)"
        return 0
    fi

    log "Siapkan repo Brave..."
    $SUDO mkdir -p /usr/share/keyrings /etc/apt/sources.list.d

    # Dibuat SEKALI di sini, dipakai oleh dua blok download (key + sources).
    # Kalau `tmp` dibiarkan kosong, redirect `> "$tmp"` gagal "ambiguous
    # redirect" dan source Brave tidak pernah terpasang.
    tmp=$(mktemp)

    if [ ! -s "$keyring" ]; then
        if fetch_url "$key_url" > "$tmp" && [ -s "$tmp" ]; then
            $SUDO install -m 644 "$tmp" "$keyring"
            log "Keyring Brave → $keyring"
        else
            warn "Ambil key Brave gagal → install brave-browser akan dilewati"
            warn "  manual: curl -fsSLo $keyring $key_url"
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi

    # Format deb822 (.sources), bukan baris `deb` lama — mengikuti petunjuk
    # resmi https://brave.com/linux/ sekarang.
    if [ ! -f "$sources" ]; then
        if fetch_url "$src_url" > "$tmp" && [ -s "$tmp" ]; then
            $SUDO install -m 644 "$tmp" "$sources"
            log "Source Brave → $sources"
        else
            warn "Ambil source Brave gagal → install brave-browser akan dilewati"
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi
}

# Wrapper `brave`: titik masuk yang AMAN dijalankan sebagai root.
# (Kalau dipanggil langsung /usr/bin/brave-browser sebagai root, Brave
# langsung exit — lihat pesannya: "Running as root without --no-sandbox ...")
brave_no_sandbox_wrapper() {
    [ -x /usr/bin/brave-browser ] || return 0
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# Dibuat otomatis oleh setup.sh — jangan diedit manual (ditimpa ulang tiap run).
# Container ini root → sandbox Chromium menolak start tanpa flag ini.
exec /usr/bin/brave-browser --no-sandbox "$@"
EOF
    $SUDO install -m 755 "$tmp" /usr/local/bin/brave
    rm -f "$tmp"

    # Ikon desktop juga perlu diarahkan ke wrapper — jalur peluncurnya bisa
    # bermacam2 (/usr/bin/brave-browser, /usr/local/bin/brave-stable yang
    # kadang tidak ada, dst), jadi semua baris Exec yang menunjuk binary
    # ber-"brave" diganti ke wrapper. Idempoten: hasilnya (/usr/local/bin/brave)
    # tetap sama walau dijalankan berulang.
    local desk="/usr/share/applications/brave-browser.desktop"
    if [ -f "$desk" ] && grep -qE '^Exec=/[^ ]*brave' "$desk" 2>/dev/null; then
        if grep -qE '^Exec=/usr/local/bin/brave( |$)' "$desk"; then
            log "Ikon desktop Brave sudah menunjuk wrapper"
        elif $SUDO sed -i -E 's|^Exec=/[^ ]*brave[^ ]*|Exec=/usr/local/bin/brave|' "$desk"; then
            log "Ikon desktop Brave diarahkan ke wrapper → $desk"
        else
            warn "patch $desk gagal → buka Brave lewat: brave"
        fi
    fi
    log "Wrapper Brave (--no-sandbox) → /usr/local/bin/brave"
}

# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
install_brave() {
    if [ "$INSTALL_BRAVE" = "1" ]; then
        if dpkg -s brave-browser >/dev/null 2>&1; then
            log "Brave sudah terinstall ($(dpkg-query -W -f='${Version}' brave-browser 2>/dev/null))"
        elif ensure_brave_repo; then
            log "Install brave-browser..."
            apt_update
            # $SUDO wajib — tanpa ini, kalau menu.sh dijalankan sebagai user
            # biasa, apt berhenti di "Could not open lock file ... Permission
            # denied" dan Brave tidak pernah terpasang (lihat install_gh/upterm
            # yang sudah benar memakai $SUDO).
            if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y brave-browser; then
                log "Brave terpasang ($(command -v brave-browser || echo '/usr/bin/brave-browser'))"
            else
                warn "Install Brave gagal → cek pesan apt di atas"
                warn "  (umumnya koneksi ke brave-browser-apt-release.s3.brave.com,"
                warn "   atau lock apt → cek: sudo lsof /var/lib/dpkg/lock-frontend)"
                warn "  ulangi: sudo apt-get update && sudo apt-get install -y brave-browser"
            fi
        fi
    else
        log "Install Brave dimatikan (INSTALL_BRAVE=0)"
    fi
    # wrapper tetap dipastikan ada selama binary-nya ada — walau install dimatikan
    brave_no_sandbox_wrapper
}

# =========================================================
# 2c. UPTERM — SSH temporer ke shell yang sedang berjalan
# =========================================================
# `upterm host --accept --skip-host-key-check -- bash` mencetak command SSH sementara (mis.
# ssh xxx@uptermd.upterm.dev:2222) — siapa pun yang command-nya dipegang bisa
# ikut di shell yang sama, tanpa perlu setup sshd/key sama sekali. Sesi mati
# sendiri kalau host-nya keluar. Dipakai dari menu.sh (opsi 2).
#
# Dipasang sebagai paket .deb resmi dari rilis GitHub → `apt` ikut mengatur
# upgrade/hapusnya. Idempoten: kalau sudah terinstall, dilewati.
install_upterm() {
    if dpkg -s upterm >/dev/null 2>&1 || command -v upterm >/dev/null 2>&1; then
        log "upterm sudah terinstall ($(upterm version 2>/dev/null | head -1))"
        return
    fi
    local arch
    case "$(dpkg --print-architecture)" in
        amd64)  arch="amd64" ;;
        arm64)  arch="arm64" ;;
        armhf)  arch="armv6" ;;
        i386)   arch="386" ;;
        *)      warn "arsitektur $(dpkg --print-architecture) tidak dirilis upterm → dilewati"
                return 0 ;;
    esac
    log "Install upterm ($arch) dari rilis GitHub..."
    local url tmp
    url="https://github.com/owenthereal/upterm/releases/latest/download/upterm_linux_${arch}.deb"
    tmp=$(mktemp --suffix=.deb)
    if curl -fsSL -o "$tmp" "$url"; then
        if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$tmp"; then
            log "upterm terpasang ($("$UPTERM_BIN" version 2>/dev/null | head -1))"
        else
            warn "Install .deb upterm gagal → cek: apt-get install -f"
        fi
    else
        warn "Download upterm gagal → cek koneksi ke github.com, lalu jalankan ulang: bash $0"
    fi
    rm -f "$tmp"
}

# =========================================================
# 2d. TERABOX — jendela aplikasi ANTI BLANK
# =========================================================
# TeraBox tidak punya klien Linux resmi → dibuka sebagai "app window" lewat
# flag --app Chrome/Brave (tanpa address bar), bukan tab biasa.
#
# Kenapa bisa blank / layar kosong saat dibuka, dan solusinya di wrapper bawah:
#   1. --no-sandbox              container ini jalan sebagai ROOT → sandbox
#                                Chromium menolak start = jendela kosong
#                                (penyebab yang sama dengan wrapper Brave).
#   2. --user-data-dir terpisah  profil khusus TeraBox → jendela MANDIRI dan
#                                tidak berebut sesi Chrome yang sudah jalan
#                                (app yang nebeng profil lama sering tidak
#                                muncul / membuka tab kosong).
#   3. --disable-dev-shm-usage   /dev/shm container kecil → renderer bisa
#                                crash di tengah jalan (layar putih/hang).
#   4. --disable-gpu             container tanpa GPU → pakai rendering
#                                software supaya kompositornya jalan.
# Browser dicari saat RUNTIME (bukan saat install) → wrapper tetap bisa
# dibuat walau Chrome/Brave belum terpasang; kalau nol semua, wrapper
# menolak dengan pesan jelas, bukan jendela blank.
#
# Idempoten: wrapper + ikon desktop ditulis ulang tiap run (isinya sama).
# Profil korup (pernah blank) → reset lalu buka lagi:
#   rm -rf /root/.config/terabox-app && terabox
install_terabox() {
    local wrapper="/usr/local/bin/terabox"
    local desk="/usr/share/applications/terabox.desktop"
    local tmp
    tmp=$(mktemp)

    # Wrapper: quoted heredoc → semua $VAR dibaca saat runtime, bukan di sini.
    cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# Dibuat otomatis oleh setup.sh — jangan diedit manual (ditimpa ulang tiap run).
# Buka TeraBox sebagai jendela aplikasi (tanpa address bar) — ANTI BLANK.
URL="${TERABOX_URL:-https://www.terabox.com}"
PROFILE="${TERABOX_PROFILE:-/root/.config/terabox-app}"
BROWSER=""
for b in google-chrome-stable google-chrome chromium-browser chromium brave-browser brave; do
    if command -v "$b" >/dev/null 2>&1; then BROWSER="$b"; break; fi
done
if [ -z "$BROWSER" ]; then
    echo "TeraBox: belum ada browser (Chrome/Brave) → jalankan dulu: bash /root/setup.sh tools" >&2
    exit 1
fi
mkdir -p "$PROFILE"
# Empat flag wajib biar tidak blank: no-sandbox (root), profil terpisah,
# anti-crash /dev/shm, render software tanpa GPU.
exec "$BROWSER" \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --user-data-dir="$PROFILE" \
    --app="$URL" \
    "$@"
EOF
    $SUDO install -m 755 "$tmp" "$wrapper"
    rm -f "$tmp"

    # Ikon desktop → buka dari menu aplikasi VNC tanpa perlu ketik terminal.
    $SUDO mkdir -p /usr/share/applications
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=TeraBox
GenericName=Cloud Storage
Comment=TeraBox di jendela aplikasi (anti-blank, tanpa address bar)
Exec=/usr/local/bin/terabox
Terminal=false
Categories=Network;FileTransfer;
Icon=folder-remote
StartupNotify=true
EOF
    $SUDO install -m 644 "$tmp" "$desk"
    rm -f "$tmp"

    # Safety net: pastikan flag anti-blank benar-benar ada di wrapper.
    if grep -q -- '--no-sandbox' "$wrapper" && grep -q -- '--user-data-dir=' "$wrapper"; then
        log "TeraBox → $wrapper + $desk (buka: terabox atau ikon TeraBox)"
    else
        warn "wrapper TeraBox tidak lengkap → cek $wrapper"
    fi
    if ! command -v google-chrome-stable >/dev/null 2>&1 \
        && ! command -v google-chrome >/dev/null 2>&1 \
        && ! command -v brave-browser >/dev/null 2>&1 \
        && ! command -v brave >/dev/null 2>&1; then
        warn "belum ada Chrome/Brave → TeraBox baru bisa dibuka setelah browser terpasang"
    fi
}

# =========================================================
# 3. TAILSCALE
# =========================================================
install_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then
        log "Tailscale sudah terinstall ($(tailscale version | head -1))"
        return
    fi
    log "Install Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    command -v tailscale >/dev/null 2>&1 || { echo "install tailscale gagal"; exit 1; }
}

login_tailscale() {
    # tailscaled dijalankan supervisor → tunggu socketnya siap dulu.
    # Pakai `debug prefs`, BUKAN `tailscale status`: saat masih logged-out,
    # `status` bisa dihitung gagal (kelihatan "belum siap") ATAU teksnya
    # tidak persis "Logged out" (ubah antar versi) → akibatnya blok authkey
    # DILEWATI dan login otomatis tidak jalan. `debug prefs` tetap dibalaskan
    # (exit 0) walau belum login, dan field JSON "LoggedOut"-nya pasti.
    local i prefs
    prefs=""
    for i in $(seq 1 20); do
        prefs=$(tailscale debug prefs 2>/dev/null) && break
        sleep 1
    done
    if [ -z "$prefs" ]; then
        warn "tailscaled belum siap → cek: supervisorctl status tailscaled dan /var/log/tailscaled.log"
        warn "  (langkah berikutnya tetap dijalankan: GitHub/web tidak ikut berhenti)"
        return 0
    fi

    # Sudah login atau belum dibaca dari prefs JSON — bukan dari teks
    # human-readable yang bisa berganti kalimat antar versi.
    local logged_out=false
    printf '%s\n' "$prefs" | grep -q '"LoggedOut": *true' && logged_out=true

    if [ "$logged_out" = true ]; then
        if [ -n "$TS_AUTHKEY" ]; then
            log "Login Tailscale pakai auth key (otomatis)..."
            # --ssh supaya bisa masuk dari Termius; auth key noncesih node lama boleh hilang
            #
            # Kegagalan di sini TIDAK boleh mematikan script (set -e): `tailscale up`
            # bisa menolak kalau prefs lama berbeda ("requires mentioning all
            # non-default flags") atau key sudah expired. Karena fungsi ini jalan
            # SEBELUM setup_gh, satu failure = login GitHub/clone/push ikut batal.
            # Jadi: coba dulu biasa, kalau ditolak karena prefs → ulangi dengan --reset.
            if ! tailscale up --auth-key="$TS_AUTHKEY" --ssh --accept-dns=false; then
                warn "tailscale up ditolak → coba ulang dengan --reset (prefs lama berbeda)"
                if ! tailscale up --auth-key="$TS_AUTHKEY" --ssh --accept-dns=false --reset; then
                    warn "Login Tailscale GAGAL → cek TS_AUTHKEY (expired/revoke?) dan /var/log/tailscaled.log"
                    warn "  key baru: TS_AUTHKEY=tskey-auth-xxx bash $0"
                    return 0
                fi
            fi
            sleep 2
        else
            log "Login Tailscale — buka link ini di browser:"
            echo
            tailscale up --ssh || true
            echo
            warn "Setelah login di browser, jalankan lagi: bash $0"
            warn "(atau set TS_AUTHKEY agar otomatis)"
            return 0
        fi
    else
        log "Tailscale sudah login: $(tailscale ip -4 2>/dev/null || true)"
    fi

    # pastikan Tailscale SSH tetap nyala (tersimpan di prefs, dicek ulang tiap run)
    if ! tailscale debug prefs 2>/dev/null | grep -q '"RunSSH": true'; then
        warn "Tailscale SSH belum aktif → nyalakan lagi"
        tailscale up --ssh --accept-dns=false || true
    fi
    log "IP Tailscale: $(tailscale ip -4 2>/dev/null || echo 'belum dapat')"
    return 0
}

# URL tetap di tailnet — tidak berganti walau mesin di-restart.
# (Beda dengan cloudflared quick tunnel yang URL-nya baru tiap start.)
setup_serve() {
    local out url
    out=$(tailscale serve --bg "$SITE_PORT" 2>&1) || true
    url=$(printf '%s\n' "$out" | grep -oE 'https?://[^[:space:]]+' | head -1 || true)
    if [ -n "$url" ]; then
        SERVE_URL="$url"
        log "Akses tetap lewat tailnet: $url"
    else
        warn "tailscale serve belum aktif: $(printf '%s' "$out" | tail -1)"
    fi
}

# =========================================================
# 4. OPENCODE
# =========================================================
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
install_opencode() {
    local oc_bin="$OPENCODE_DIR/opencode"
    # Dir sebagai root → /root/.opencode/bin; dijalankan sebagai user lain,
    # instalernya pakai $HOME. Cek dua-duanya biar tidak unduh ulang tiap run.
    [ -x "$oc_bin" ] || oc_bin="${HOME:-/root}/.opencode/bin/opencode"
    if [ -x "$oc_bin" ]; then
        log "OpenCode sudah terinstall ($("$oc_bin" --version 2>/dev/null))"
    else
        log "Install OpenCode..."
        curl -fsSL https://opencode.ai/v2/install | bash
    fi
    # Pastikan ada di PATH lewat .bashrc (aman kalau .bashrc ikut hilang kena reset).
    # $SUDO wajib: /root/.bashrc tidak bisa ditulis user biasa → tanpa ini
    # `set -e` mematikan SELURUH script di sini (Only Tools tidak pernah selesai).
    if ! $SUDO grep -q '.opencode/bin' /root/.bashrc 2>/dev/null; then
        printf '\n# opencode\nexport PATH=/root/.opencode/bin:$PATH\n' \
            | $SUDO tee -a /root/.bashrc >/dev/null
    fi
    export PATH="$OPENCODE_DIR:$PATH"
    log "OpenCode: $(command -v opencode || echo "$OPENCODE_DIR/opencode")"
}

# =========================================================
# 4a. ALIAS SINGKAT — oce & age
# =========================================================
# Satu step idempoten untuk dua alias harian di /root/.bashrc:
#   oce → opencode             (CLI agent)
#   age → bash /root/menu.sh   (menu interaktif)
# Ditulis ulang hanya kalau belum ada → aman dijalankan berkali-kali, dan
# alias yang sudah diedit user tidak ditimpa.
# $SUDO wajib: /root/.bashrc tidak bisa ditulis user biasa (sama seperti
# install_opencode) — tanpa ini `set -e` mematikan seluruh script.
ensure_aliases() {
    if ! $SUDO grep -q "alias oce=" /root/.bashrc 2>/dev/null; then
        printf "\n# alias opencode\nalias oce='opencode'\n" \
            | $SUDO tee -a /root/.bashrc >/dev/null
    fi
    if ! $SUDO grep -q "alias age=" /root/.bashrc 2>/dev/null; then
        printf "\n# alias menu.sh\nalias age='bash /root/menu.sh'\n" \
            | $SUDO tee -a /root/.bashrc >/dev/null
    fi
    log "Alias siap: oce → opencode, age → bash /root/menu.sh (berlaku di shell baru)"
}

# =========================================================
# 5. SSH — TIDAK DIPASANG (sshd memang tidak berguna di sini)
# =========================================================
# Akses harian lewat Tailscale SSH: `tailscale ssh root@<ip>` dari Termius.
# Diautentikasi oleh identitas Tailscale, dan protokol SSH-nya ditangani
# langsung oleh tailscaled (lihat log: "access granted ... as ssh-user root",
# child-nya /usr/bin/login -f) — BUKAN oleh /usr/sbin/sshd.
# Jadi openssh-server tidak perlu sama sekali: tidak dipakai, tidak ada yang
# login lewat port 22, dan nginx/web image ini juga tidak meneruskan port 22.
# openssh-client TETAP ada (dipakai git ssh dan `tailscale ssh`).
#
# Kalau suatu saat butuh sshd (misal Tailscale mati total):
#   apt-get install -y openssh-server
# ($SUDO sengaja tidak di-quote: nilainya "" atau "sudo")
# shellcheck disable=SC2086
remove_sshd() {
    if dpkg -s openssh-server >/dev/null 2>&1 || command -v sshd >/dev/null 2>&1; then
        log "Hapus openssh-server (sshd tidak dipakai: akses lewat Tailscale SSH)..."
        supervisorctl stop sshd >/dev/null 2>&1 || true
        pkill -x sshd 2>/dev/null || true
        wait_gone -x sshd
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get purge -y openssh-server >/dev/null 2>&1 \
            || warn "purge openssh-server gagal → cek: apt-get install -f"
    fi

    # sisa yang dulu dibuat script ini, dibersihkan walau paketnya sudah tidak ada
    rm -f /etc/ssh/sshd_config.d/50-no-password.conf /etc/ssh/sshd_config.d/root-login.conf /var/log/sshd.log
    rmdir /etc/ssh/sshd_config.d /run/sshd 2>/dev/null || true

    log "sshd tidak dipasang (akses lewat Tailscale SSH; openssh-client tetap ada untuk git)"
}

# =========================================================
# 6. SUPERVISOR — semua daemon di sini
# =========================================================
# Kenapa supervisor? Container ini tanpa systemd, tapi supervisord sudah jalan
# dari awal container hidup + auto-restart. Service yang dipasang di sini ikut
# bangun sendiri tiap mesin hidup — tanpa `bash setup.sh` lagi.
resolve_binaries() {
    TSD_BIN="$(command -v tailscaled || echo /usr/sbin/tailscaled)"
    PY_BIN="$(command -v python3 || echo /usr/bin/python3)"
    # opencode: PATH dulu (install_opencode menambahkannya), kalau tidak ada
    # jatuh ke lokasi instalasi root — binary inilah yang dijaga supervisor
    # sebagai service OpenCode (dibutuhkan bot Telegram buat menjawab).
    OC_BIN="$(command -v opencode || true)"
    if [ -z "$OC_BIN" ]; then
        OC_BIN="$OPENCODE_DIR/opencode"
        [ -x "$OC_BIN" ] || OC_BIN="${HOME:-/root}/.opencode/bin/opencode"
    fi
    # tailscaled yang masih dijalankan manual (belum diawasi supervisor)
    TAILSCALE_STRAY=0
    if ! supervisor_has tailscaled && pgrep -x tailscaled >/dev/null 2>&1; then
        TAILSCALE_STRAY=1
    fi
}

supervisor_has() {
    [ -S "$SUPERVISOR_RUN" ] || return 1
    supervisorctl status "$1" 2>/dev/null | grep -q ' RUNNING'
}

pid_on_port() {
    ss -tlnp "sport = :$1" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true
}

# Tunggu proses lama benar-benar hilang sebelum supervisor mengstart yang baru.
# Kalau belum, proses baru berebut port/state file → supervisor jadi FATAL.
wait_gone() {
    local i
    for i in $(seq 15); do
        pgrep "$@" >/dev/null 2>&1 || return 0
        sleep 1
    done
    warn "proses lama (pgrep $*) belum hilang juga setelah 15 detik"
}

# Proses yang dulu dijalankan manual → diserahkan ke supervisor supaya ikut
# bangun otomatis. Dilakukan SEBELUM reread/update.
take_over_strays() {
    if ! supervisor_has tailscaled && pgrep -x tailscaled >/dev/null 2>&1; then
        if [ "$TAKE_TAILSCALE" = "1" ]; then
            warn "Hentikan tailscaled manual → pindah ke supervisor (Tailscale putus ~5 detik)"
            pkill -x tailscaled || true
            wait_gone -x tailscaled
        else
            warn "tailscaled MASIH MANUAL (TAKE_TAILSCALE=0) — sesi Tailscale SSH tidak diputus"
            warn "Ambil-alih nanti: TAKE_TAILSCALE=1 bash $0 (jalankan pas nggak ada sesi remote)"
        fi
    fi

    if ! supervisor_has site-server; then
        local p
        for p in $(pid_on_port "$SITE_PORT"); do
            warn "Hentikan web server manual (pid $p) → pindah ke supervisor"
            kill "$p" 2>/dev/null || true
        done
        wait_gone -f "http.server $SITE_PORT"
    fi

    if [ "$USE_CLOUDFLARED" = 1 ] && ! supervisor_has cloudflared \
        && pgrep -f 'cloudflared tunnel --url' >/dev/null 2>&1; then
        warn "Hentikan tunnel manual → pindah ke supervisor (URL tunnel publik akan BERUBAH)"
        pkill -f 'cloudflared tunnel --url' || true
        wait_gone -f 'cloudflared tunnel --url'
    fi

    # opencode serve yang nyala manual (hasil `opencode service start`, lazily
    # dari bot) → serahkan ke supervisor supaya ikut bangun tiap boot. Kalau
    # dibiarkan, proses barunya bentrok port dengan yang lama → FATAL.
    if [ -f "$SUPERVISOR_DIR/25-opencode.conf" ] && ! supervisor_has opencode-serve \
        && pgrep -f 'opencode serve' >/dev/null 2>&1; then
        warn "Hentikan opencode serve manual → pindah ke supervisor (balasan bot bisa gagal 1x)"
        [ -x "${OC_BIN:-}" ] && "$OC_BIN" service stop >/dev/null 2>&1 || true
        pkill -f 'opencode serve' || true
        wait_gone -f 'opencode serve'
    fi
}

write_supervisor_confs() {
    mkdir -p "$SUPERVISOR_DIR" /var/log /var/lib/tailscale
    resolve_binaries

    # autostart tailscaled: hanya false kalau ada proses manual yang sengaja
    # tidak dipindah (TAKE_TAILSCALE=0). Di boot bersih otomatis true lagi.
    local ts_autostart=true
    if [ "$TAKE_TAILSCALE" = "0" ] && [ "$TAILSCALE_STRAY" = "1" ]; then
        ts_autostart=false
    fi

    log "Tulis konfigurasi supervisor..."
    cat > "$SUPERVISOR_DIR/10-mesin.conf" <<EOF
; Dibuat otomatis oleh setup.sh (di-regenerate tiap setup dijalankan).
; Jangan diedit manual — perubahan ditimpa.
;
; Semua daemon di file ini ikut bangun sendiri tiap container hidup, karena
; supervisord sudah jalan dari awal dan auto-restart.

[program:tailscaled]
priority=5
autostart=${ts_autostart}
autorestart=true
command=${TSD_BIN} --tun=userspace-networking --socks5-server=localhost:1055 --state=/var/lib/tailscale/tailscaled.state
startsecs=3
stopsignal=TERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/tailscaled.log
stdout_logfile_maxbytes=10485760
stdout_logfile_backups=3
environment=HOME="/root",USER="root"

[program:site-server]
priority=20
autostart=true
autorestart=true
directory=${SITE_DIR}
command=${PY_BIN} -m http.server ${SITE_PORT} --bind 0.0.0.0
startsecs=3
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/site-server.log
stdout_logfile_maxbytes=10485760
stdout_logfile_backups=3
environment=HOME="/root",USER="root"
EOF

    # Service OpenCode (opencode serve --service) — "otak" yang dipanggil bot
    # Telegram lewat API lokal (port + password dibaca bot.py dari
    # ~/.local/state/opencode/service.json, ditulis binary ini saat start).
    # Tanpa ini bot jalan tapi TIDAK BISA menjawab: dia baru menyalakan
    # service saat pesan pertama — lambat, dan kalau service.json belum
    # pernah ada bot bahkan belum bisa start (lihat oc_conn di bot.py).
    # priority 38 < 40 (bot) → service sudah nyala dulu sebelum bot polling.
    if [ -x "${OC_BIN:-}" ]; then
        cat > "$SUPERVISOR_DIR/25-opencode.conf" <<EOF
[program:opencode-serve]
priority=38
autostart=true
autorestart=true
command=${OC_BIN} serve --service
startsecs=5
stopsignal=TERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/opencode-serve.log
stdout_logfile_maxbytes=10485760
stdout_logfile_backups=3
environment=HOME="/root",USER="root"
EOF
        log "Service OpenCode (opencode serve) ikut dipantau supervisor"
    else
        rm -f "$SUPERVISOR_DIR/25-opencode.conf"
        warn "binary opencode tidak ditemukan → service OpenCode tidak dipasang ke supervisor"
    fi

    if [ "$USE_CLOUDFLARED" = "1" ]; then
        cat > "$SUPERVISOR_DIR/20-cloudflared.conf" <<EOF
[program:cloudflared]
priority=30
autostart=true
autorestart=true
command=${CLOUDFLARED_BIN} tunnel --url http://localhost:${SITE_PORT}
startsecs=5
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/cloudflared.log
stdout_logfile_maxbytes=10485760
stdout_logfile_backups=3
EOF
        log "Tunnel publik cloudflared ikut dipantau supervisor"

        # kasir-roti (web kasir, port 8080) — opsional: hanya kalau binarinya ada.
        # Kalau belum terpasang tapi ada hasil build di /root/kasir-roti, pasangkan dulu.
        local kasir_bin="/usr/local/bin/kasir-roti"
        if [ ! -x "$kasir_bin" ] && [ -x /root/kasir-roti/target/release/kasir-roti ]; then
            install -m755 /root/kasir-roti/target/release/kasir-roti "$kasir_bin"
        fi
        if [ -x "$kasir_bin" ]; then
            cat > "$SUPERVISOR_DIR/30-kasir.conf" <<EOF
[program:kasir-roti]
priority=25
autostart=true
autorestart=true
command=${kasir_bin} --serve --port 8080
startsecs=2
stopsignal=TERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/kasir-roti.log
stdout_logfile_maxbytes=1048576
stdout_logfile_backups=1
environment=HOME="/root",USER="root"
EOF
            cat > "$SUPERVISOR_DIR/35-kasir-cloudflared.conf" <<EOF
[program:kasir-cloudflared]
priority=35
autostart=true
autorestart=true
command=${CLOUDFLARED_BIN} tunnel --url http://localhost:8080
startsecs=5
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/kasir-cloudflared.log
stdout_logfile_maxbytes=1048576
stdout_logfile_backups=1
EOF
            log "Kasir web (port 8080) + tunnel kasir ikut dipantau supervisor"
        else
            rm -f "$SUPERVISOR_DIR/30-kasir.conf" "$SUPERVISOR_DIR/35-kasir-cloudflared.conf"
        fi
    else
        rm -f "$SUPERVISOR_DIR/20-cloudflared.conf" "$SUPERVISOR_DIR/30-kasir.conf" "$SUPERVISOR_DIR/35-kasir-cloudflared.conf"
        log "Tunnel cloudflared dimatikan (USE_CLOUDFLARED=0)"
    fi
}

reload_supervisor() {
    if [ ! -S "$SUPERVISOR_RUN" ]; then
        warn "supervisord tidak jalan ($SUPERVISOR_RUN tidak ada) — service tidak bisa dimanajer!"
        return 0
    fi
    log "Terapkan konfigurasi supervisor..."
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update >/dev/null 2>&1 || true
}

# Tunggu program RUNNING di supervisor; kalau tetap gagal → jalankan manual.
start_service() {
    local prog="$1" fallback="${2:-}" i
    for i in $(seq 30); do
        if supervisor_has "$prog"; then
            log "$prog: jalan via supervisor"
            return 0
        fi
        supervisorctl start "$prog" >/dev/null 2>&1 || true
        sleep 1
    done
    if [ -n "$fallback" ]; then
        warn "$prog GAGAL di supervisor → jalankan manual sebagai cadangan"
        warn "    cek: supervisorctl status $prog   log: /var/log/${prog}.log"
        bash -c "$fallback" || true
    else
        warn "$prog belum jalan → cek: supervisorctl status $prog (log: /var/log/${prog}.log)"
    fi
    return 0
}

# =========================================================
# 7. WEB TOKO ROTI + TUNNEL
# =========================================================
ensure_site() {
    # Dipanggil SEBELUM supervisor → direktori harus sudah ada, nanti clone-nya
    # menyusul setelah gh login (repo toko-roti privat).
    if [ ! -d "$SITE_DIR" ]; then
        mkdir -p "$SITE_DIR"
        warn "$SITE_DIR hilang kena reset → dicoba di-clone setelah gh login"
    fi
}

restore_site() {
    # Repo privat → butuh gh login dulu, jadi dipisah dari ensure_site.
    [ -n "$SITE_REPO" ] || return 0
    [ ! -f "$SITE_DIR/index.html" ] || return 0
    log "Clone github.com/${SITE_REPO%.git} → $SITE_DIR ..."
    if git clone --quiet "https://github.com/${SITE_REPO%.git}.git" "$SITE_DIR"; then
        log "toko-roti pulih dari GitHub: $(ls "$SITE_DIR" | tr '\n' ' ')"
    else
        warn "Clone toko-roti gagal (cek GH_TOKEN / repo-nya sudah ada?)."
        warn "Manual: rm -rf $SITE_DIR && git clone https://github.com/${SITE_REPO%.git}.git $SITE_DIR"
    fi
}

install_cloudflared() {
    if [ "$USE_CLOUDFLARED" != "1" ]; then
        log "Tunnel cloudflared dimatikan (USE_CLOUDFLARED=0)"
        return
    fi
    if [ -x "$CLOUDFLARED_BIN" ]; then
        log "cloudflared sudah ada ($("$CLOUDFLARED_BIN" --version 2>/dev/null))"
        return
    fi
    if [ -x /tmp/opencode/cloudflared ]; then
        log "Pakai binari cloudflared yang sudah ada di /tmp/opencode"
        install -m755 /tmp/opencode/cloudflared "$CLOUDFLARED_BIN"
        return
    fi
    log "Download cloudflared..."
    curl -fsSL -o "$CLOUDFLARED_BIN" \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x "$CLOUDFLARED_BIN"
}

# Quick tunnel cloudflared = URL baru tiap start → tangkap dan simpan ke file.
capture_tunnel_url() {
    [ "$USE_CLOUDFLARED" = "1" ] || return 0
    local i url=""
    for i in $(seq 30); do
        url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/cloudflared.log 2>/dev/null | tail -1 || true)
        [ -n "$url" ] && break
        sleep 1
    done
    if [ -n "$url" ]; then
        TUNNEL_URL="$url"
        printf '%s\n' "$url" > "$TUNNEL_URL_FILE"
        log "Tunnel publik: $url (juga disimpan di $TUNNEL_URL_FILE)"
    else
        warn "URL tunnel belum muncul → cek /var/log/cloudflared.log"
    fi
}

# Tunnel kasir (port 8080): URL quick tunnel-nya beda dari site → file terpisah.
capture_kasir_url() {
    [ "$USE_CLOUDFLARED" = "1" ] || return 0
    [ -f "$SUPERVISOR_DIR/30-kasir.conf" ] || return 0
    local i url=""
    for i in $(seq 30); do
        url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/kasir-cloudflared.log 2>/dev/null | tail -1 || true)
        [ -n "$url" ] && break
        sleep 1
    done
    if [ -n "$url" ]; then
        KASIR_URL="$url"
        printf '%s\n' "$url" > "$KASIR_URL_FILE"
        log "Kasir online: $url (juga disimpan di $KASIR_URL_FILE)"
    else
        warn "URL kasir belum muncul → cek /var/log/kasir-cloudflared.log"
    fi
}

# =========================================================
# 8. GITHUB + BACKUP TOKO ROTI
# =========================================================
# Cek login gh yang SEBENARNYA (credential tersimpan di hosts.yml), bukan yang
# ditipu env. Selama script ini jalan, GH_TOKEN ada di env proses → `gh auth
# status` otomatis pakai env token dan selalu bilang "sukses", padahal token
# belum pernah disimpan ke /root/.config/gh/hosts.yml. Akibatnya blok
# `gh auth login --with-token` DILEWATI, dan di shell berikutnya (tanpa env)
# gh balik bilang "not logged in" — persis gejala yang dialami.
# Jadi env token dibersihkan dulu saat menilai status.
gh_auth_persisted() {
    env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
        gh auth status >/dev/null 2>&1
}

setup_gh() {
    command -v gh >/dev/null 2>&1 || return 0
    if ! gh_auth_persisted; then
        if [ -n "$GH_TOKEN" ]; then
            log "GitHub login pakai GH_TOKEN..."
            # printf (bukan echo) supaya token tidak dapat tambahan newline
            if printf '%s' "$GH_TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token; then
                if gh_auth_persisted; then
                    log "GitHub token TERSIMPAN persisten (tetap login walau env dilepas)"
                else
                    warn "gh menerima token tapi tidak tersimpan → GH_TOKEN mungkin tidak valid"
                fi
            else
                warn "gh auth login GAGAL → cek GH_TOKEN (expired / scope kurang?)"
                warn "  cek manual: GH_TOKEN=xxx gh auth status"
            fi
        else
            warn "GitHub belum login → set GH_TOKEN lalu jalankan ulang: $0"
            return 0
        fi
    fi
    gh auth setup-git >/dev/null 2>&1 || true
    gh alias set co "pr checkout" >/dev/null 2>&1 || true
    log "GitHub login: $(gh api user -q .login 2>/dev/null || echo OK)"
    return 0
}

configure_git_identity() {
    command -v git >/dev/null 2>&1 || return 0
    if ! git config --global user.email >/dev/null 2>&1; then
        local name email
        name=$(gh api user -q .login 2>/dev/null || true)
        if [ -n "$name" ]; then
            email="${name}@users.noreply.github.com"
        else
            name="root"
            email="root@$(hostname)"
        fi
        git config --global user.name "$name"
        git config --global user.email "$email"
        log "Identitas git: $name <$email>"
    fi
    git config --global init.defaultBranch >/dev/null 2>&1 || git config --global init.defaultBranch main
}

backup_site() {
    command -v git >/dev/null 2>&1 || return 0
    [ -d "$SITE_DIR" ] || return 0
    # folder masih kosong → jangan bikin repo, supaya auto-clone berikutnya jalan
    if [ -z "$(ls -A "$SITE_DIR" 2>/dev/null)" ]; then
        log "Backup toko-roti: dilewati (folder masih kosong)"
        return 0
    fi
    if [ ! -d "$SITE_DIR/.git" ]; then
        git -C "$SITE_DIR" init -q
        log "git init: $SITE_DIR"
    fi
    git -C "$SITE_DIR" add -A
    if git -C "$SITE_DIR" diff --cached --quiet 2>/dev/null; then
        log "Backup toko-roti: tidak ada perubahan"
    else
        git -C "$SITE_DIR" commit -qm "backup otomatis $(date '+%F %T')"
        log "Backup toko-roti: $(git -C "$SITE_DIR" log -1 --oneline)"
    fi
    # push tiap run: remote sudah ada (dibuat sekarang) atau ditambahkan dari SITE_REPO
    if [ -n "$SITE_REPO" ]; then
        git -C "$SITE_DIR" remote get-url origin >/dev/null 2>&1 \
            || git -C "$SITE_DIR" remote add origin "https://github.com/${SITE_REPO%.git}.git"
    fi
    if git -C "$SITE_DIR" remote get-url origin >/dev/null 2>&1; then
        if git -C "$SITE_DIR" push -u origin HEAD --quiet; then
            log "Push toko-roti ke GitHub OK"
        else
            warn "Push toko-roti gagal → cek GH_TOKEN / koneksi"
        fi
    else
        log "Backup toko-roti: belum ada remote → set SITE_REPO=owner/nama-repo"
    fi
}

# =========================================================
# 8a. KASIR ROTI — restore sumber dari GitHub + build
# =========================================================
# Sumber kasir-roti disimpan sebagai BRANCH `kasir-roti` di repo privat
# AgungAG/toko-roti (bukan repo izin: fine-grained PAT mesin ini tidak
# diizinkan membuat repo baru, jadi dipigarkan ke repo yang sudah ada).
# Urutan: dipanggil SETELAH setup_gh (butuh login gh untuk repo privat)
# dan SEBELUM write_supervisor_confs (butuh binary siap untuk conf kasir).
restore_kasir() {
    command -v git >/dev/null 2>&1 || return 0
    local kasir_bin="/usr/local/bin/kasir-roti" src="/root/kasir-roti"
    if [ -x "$kasir_bin" ]; then
        log "kasir-roti sudah terpasang ($kasir_bin)"
        return 0
    fi
    if [ ! -d "$src/.git" ]; then
        [ -n "$SITE_REPO" ] || return 0
        log "Clone branch kasir-roti dari github.com/${SITE_REPO%.git} → $src ..."
        if ! gh repo clone "${SITE_REPO%.git}" "$src" -- --branch kasir-roti --single-branch --quiet; then
            warn "Clone kasir-roti gagal (butuh GH_TOKEN / koneksi) → kasir web dilewati"
            return 0
        fi
        log "kasir-roti pulih dari GitHub"
    fi
    # build bila toolchain Rust tersedia; kalau belum, coba pasang lewat apt
    if ! command -v cargo >/dev/null 2>&1; then
        log "Install rustc + cargo (untuk build kasir-roti)..."
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq rustc cargo >/dev/null 2>&1 \
            || warn "Install rustc/cargo gagal → kasir-roti tidak bisa di-build kali ini"
    fi
    if command -v cargo >/dev/null 2>&1; then
        log "Build kasir-roti (cargo build --release)..."
        if (cd "$src" && cargo build --release --quiet); then
            $SUDO install -m755 "$src/target/release/kasir-roti" "$kasir_bin"
            log "Kasir web terpasang → $kasir_bin"
        else
            warn "cargo build kasir-roti gagal → web kasir tidak jadi dipasang"
        fi
    fi
    return 0
}

# Backup source kasir-roti: commit + push ke branch kasir-roti (repo privat).
backup_kasir() {
    local src="/root/kasir-roti"
    command -v git >/dev/null 2>&1 || return 0
    [ -d "$src/.git" ] || return 0
    git -C "$src" add -A
    if git -C "$src" diff --cached --quiet 2>/dev/null; then
        log "Backup kasir-roti: tidak ada perubahan"
        return 0
    fi
    git -C "$src" commit -qm "backup otomatis $(date '+%F %T')"
    log "Backup kasir-roti: $(git -C "$src" log -1 --oneline)"
    if git -C "$src" push -q origin HEAD:kasir-roti 2>/dev/null; then
        log "Push kasir-roti ke GitHub OK"
    else
        warn "Push kasir-roti gagal → cek gh login"
    fi
}

# =========================================================
# 8b. BOT TELEGRAM → OPENCODE (MODEL GRATIS)
# =========================================================
# Nyalakan service OpenCode (opencode serve) supaya bot Telegram langsung
# bisa menjawab — bukan nunggu start malas dari pesan pertama yang lambat
# dan butuh service.json yang belum tentu ada. Kalau service-nya sudah dijaga
# supervisor (conf 25-opencode.conf), dilewati: sudah nyala sejak boot.
warm_opencode_service() {
    local oc_bin="${OC_BIN:-}"
    [ -n "$oc_bin" ] || oc_bin="$OPENCODE_DIR/opencode"
    [ -x "$oc_bin" ] || return 0
    if supervisor_has opencode-serve; then
        log "Service OpenCode sudah jalan via supervisor"
        return 0
    fi
    log "Nyalakan service OpenCode (biar bot Telegram langsung bisa menjawab)..."
    if ! "$oc_bin" service start >/dev/null 2>&1; then
        warn "opencode service start gagal → bot akan coba nyalakan sendiri saat pesan pertama"
    fi
}

# Pisahkan kode dan rahasia:
#   - bot.py → kode BERSIH, disimpan di repo publik ini (restore: git clone).
#   - token + chat id → RAHASIA, dibuat lokal oleh fungsi ini dari env /
#     $SECRET_FILE. config.json dihasilkan ulang tiap run (chmod 600),
#     jadi isi rahasia selalu mengikuti .machine-secrets.
# Idempoten: dijalankan berkali-kali hasilnya sama; kalau token kosong,
# conf supervisor bot dibuang supaya tidak crash-loop.
setup_telegram_bot() {
    local conf="$TG_BOT_DIR/config.json"
    local py="${PY_BIN:-$(command -v python3 || echo /usr/bin/python3)}"

    if [ -z "$TG_BOT_TOKEN" ]; then
        warn "TG_BOT_TOKEN kosong → bot Telegram dilewati"
        warn "  isi dulu (env atau $SECRET_FILE):"
        warn "      TG_BOT_TOKEN=12345:AA... TG_CHAT_IDS=<chatid> bash $0"
        rm -f "$SUPERVISOR_DIR/30-tgbot.conf"
        return 0
    fi
    [ -n "$TG_CHAT_IDS" ] \
        || warn "TG_CHAT_IDS kosong → bot menolak SEMUA chat (aman, belum ada yang bisa pakai)"

    mkdir -p "$TG_BOT_DIR"

    # bot.py: ambil dari repo; kalau script dijalankan dari file curl tanpa
    # repo, unduh dari raw.githubusercontent (tetap tanpa rahasia di dalamnya).
    if [ -f "$TG_BOT_SRC/bot.py" ]; then
        install -m 644 "$TG_BOT_SRC/bot.py" "$TG_BOT_DIR/bot.py"
    elif [ ! -f "$TG_BOT_DIR/bot.py" ]; then
        if fetch_url "$TG_BOT_RAW" > "$TG_BOT_DIR/bot.py" 2>/dev/null \
            && [ -s "$TG_BOT_DIR/bot.py" ]; then
            log "bot.py diunduh dari GitHub"
        else
            rm -f "$TG_BOT_DIR/bot.py" "$SUPERVISOR_DIR/30-tgbot.conf"
            warn "bot.py tidak tersedia (offline / belum ada di repo) → bot Telegram dilewati"
            return 0
        fi
    fi

    # config.json = RAHASIA → ditulis lokal dari env/.machine-secrets, chmod 600.
    TG_BOT_TOKEN="$TG_BOT_TOKEN" TG_CHAT_IDS="$TG_CHAT_IDS" "$py" - "$conf" <<'PYEOF'
import json, os, sys
secrets = os.environ.get("TG_CHAT_IDS", "")
chats = [int(x) for x in secrets.replace(",", " ").split() if x.isdigit()]
cfg = {
    "token": os.environ["TG_BOT_TOKEN"],
    "opencode_url": "http://127.0.0.1:49374",
    "model": {"providerID": "opencode", "id": "mimo-v2.6-flash-free"},
    "workdir": "/root",
    "allowed_chat_ids": chats,
    "prompt_timeout": 600,
    "poll_timeout": 50,
}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
    chmod 600 "$conf"
    log "config bot Telegram ditulis ulang → $conf (chmod 600, dari .machine-secrets)"

    # Permission OpenCode: tanpa ini sesi bot bisa macet nunggu konfirmasi
    # tool (edit/bash). Tool `question` juga dimatikan: dia tool interaktif
    # (muncul pilihan tombol di UI) yang lewat bot Telegram tak pernah bisa
    # dijawab → sesi tak pernah idle → /wait menggantung sampai timeout.
    # Hanya dibuat kalau belum ada — config user tidak ditimpa.
    local oc_cfg="/root/.config/opencode/opencode.json"
    if [ ! -f "$oc_cfg" ]; then
        mkdir -p "$(dirname "$oc_cfg")"
        cat > "$oc_cfg" <<'OCEOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": { "edit": "allow", "bash": "allow", "webfetch": "allow" },
  "tools": { "question": false }
}
OCEOF
        log "permission OpenCode → allow + question dimatikan (biar bot tidak nunggu konfirmasi tool / timeout)"
    fi

    # Supervisor: bot ikut bangun sendiri tiap container hidup.
    cat > "$SUPERVISOR_DIR/30-tgbot.conf" <<EOF
; Dibuat otomatis oleh setup.sh (di-regenerate tiap setup dijalankan).
[program:tg-opencode-bot]
priority=40
autostart=true
autorestart=true
directory=${TG_BOT_DIR}
command=${py} -u ${TG_BOT_DIR}/bot.py
startsecs=3
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/tg-opencode-bot.log
stdout_logfile_maxbytes=2097152
stdout_logfile_backups=2
environment=HOME="/root",USER="root"
EOF
    log "Bot Telegram dijaga supervisor (30-tgbot.conf) → log: /var/log/tg-opencode-bot.log"
    return 0
}

# =========================================================
# 8c. SESSION KEEP-ALIVE — sesi tidak pernah keluar otomatis
# =========================================================
# Daemon /usr/local/bin/session-keepalive yang dijaga supervisor
# (40-keepalive.conf) → jalan sejak boot, auto-restart, ikut pulih tiap
# reset (file ini juga dibuat ulang tiap setup dijalankan). Tugasnya bikin
# mesin SELALU terlihat seperti sedang dipakai manusia supaya tidak ada
# yang keluar sendiri:
#   1. X screensaver + DPMS dimatikan (bawaan image: layar blank tiap
#      600 detik → x11vnc/noVNC kelihatan "mati"). Hasil uji langsung di
#      mesin ini: `xset q` menunjukkan Screen Saver timeout 600 — di sinilah
#      dihentikan, plus xset s noblank/-dpms.
#   2. Auto-lock desktop umum (GNOME/Cinnamon/MATE) dimatikan — best-effort,
#      yang tidak terpasang dilewati diam. xscreensaver (kalau ada) dihentikan.
#   3. Pointer digeser 2px bolak-balik tiap siklus via xdotool → timer idle
#      X/aplikasi selalu reset, "ada interaksi" terus. Tanpa xdotool fitur ini
#      dilewati; poin 1 tetap membuat layar tidak blank.
#   4. tmux session dev ($DEV_SESSION) dibuat ulang kalau hilang.
#   5. Tailscale login ulang OTOMATIS kalau keluar sendiri (key expiry /
#      logout) — pakai TS_AUTHKEY dari $SECRET_FILE, tanpa campur tangan.
# Semua langkah BEST-EFFORT: tool/X yang tidak ada → dilewati diam, daemon
# tidak pernah mati sendiri. Interval: KEEPALIVE_INTERVAL (detik, default 60).
# Idempoten: script + conf ditulis ulang tiap run (isinya sama).
KEEPALIVE_BIN="/usr/local/bin/session-keepalive"
KEEPALIVE_CONF="$SUPERVISOR_DIR/40-keepalive.conf"

setup_keepalive() {
    local disp tmp

    # xdotool = "tangan" simulasi pointer. Dipasang kalau belum ada; gagal
    # (offline) bukan masalah → fitur gerak pointer dilewati, yang lain jalan.
    if ! command -v xdotool >/dev/null 2>&1; then
        if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq xdotool >/dev/null 2>&1; then
            log "xdotool terpasang (simulasi gerakan pointer anti-idle)"
        else
            warn "xdotool gagal dipasang → simulasi pointer dilewati (layar tetap tidak blank via xset)"
        fi
    fi

    # DISPLAY untuk service: yang sekarang dulu, lalu tebak dari socket X.
    # (Kalau salah tebak, daemon tetap mencoba :1.0/:0.0 tiap siklus.)
    disp="${DISPLAY:-}"
    if [ -z "$disp" ] && [ -e /tmp/.X11-unix/X1 ]; then disp=":1.0"; fi
    if [ -z "$disp" ] && [ -e /tmp/.X11-unix/X0 ]; then disp=":0.0"; fi
    disp="${disp:-:1.0}"

    tmp=$(mktemp)
    # Quoted heredoc → $VAR di bawah dibaca saat RUNTIME oleh daemon.
    cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# Dibuat otomatis oleh setup.sh — jangan diedit manual (ditimpa ulang tiap run).
# Session keep-alive: mesin SELALU terlihat dipakai → sesi tidak pernah
# keluar/blank/lock otomatis. Dijaga supervisord (40-keepalive.conf).
INTERVAL="${KEEPALIVE_INTERVAL:-30}"
SECRET_FILE="/root/.machine-secrets"
DEV_SESSION="${DEV_SESSION:-oce}"
TS_WARN_EVERY=20

log() { printf '%s [keepalive] %s\n' "$(date '+%F %T')" "$*"; }

# (1)+(2)+(3) — cari DISPLAY yang hidup; kalau tidak ada X, lanjut tugas lain
x_refresh() {
    local d dx dy
    for d in "${DISPLAY:-}" ":1.0" ":0.0"; do
        [ -n "$d" ] || continue
        DISPLAY="$d" xset q >/dev/null 2>&1 || continue
        # screensaver: matikan total (timeout → 0) dan jangan pernah blank
        DISPLAY="$d" xset s off 2>/dev/null || true
        DISPLAY="$d" xset s noblank 2>/dev/null || true
        DISPLAY="$d" xset -dpms 2>/dev/null || true
        # auto-lock desktop umum — hanya DE terpasang yang ikut, lainnya diam
        if command -v gsettings >/dev/null 2>&1; then
            gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
            gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
            gsettings set org.cinnamon.desktop.screensaver lock-enabled false 2>/dev/null || true
            gsettings set org.mate.screensaver lock-enabled false 2>/dev/null || true
        fi
        if command -v xscreensaver-command >/dev/null 2>&1; then
            xscreensaver-command -exit 2>/dev/null || true
        fi
        # "interaksi manusia": pointer digeser acak 2-11px lalu dikembalikan,
        # ditutup ketukan Shift_L (modifier saja → tidak mengetik karakter
        # apa pun). xdotool memakai XTEST → event-nya sama dengan input
        # asli, jadi timer idle yang menghitung mouse MAUPUN keyboard selalu
        # reset. Arah/jarak diganti tiap siklus supaya tidak pola identik.
        if command -v xdotool >/dev/null 2>&1; then
            dx=$(( (RANDOM % 10) + 2 )); dy=$(( (RANDOM % 10) + 2 ))
            [ $(( RANDOM % 2 )) -eq 0 ] && dx=$((-dx))
            [ $(( RANDOM % 2 )) -eq 0 ] && dy=$((-dy))
            DISPLAY="$d" xdotool mousemove_relative -- "$dx" "$dy" 2>/dev/null || true
            sleep 1
            DISPLAY="$d" xdotool mousemove_relative -- "$((-dx))" "$((-dy))" 2>/dev/null || true
            DISPLAY="$d" xdotool key --clearmodifiers Shift_L 2>/dev/null || true
        fi
        if [ -z "${X_OK_LOGGED:-}" ]; then
            log "X aktif (DISPLAY=$d): screensaver/DPMS dimatikan + gerakan simulasi jalan"
            X_OK_LOGGED=1
        fi
        X_DOWN_LOGGED=""
        return 0
    done
    if [ -z "${X_DOWN_LOGGED:-}" ]; then
        log "PERINGATAN: tidak ada DISPLAY hidup → gerak pointer dilewati (xset dicoba lagi tiap siklus)"
        X_DOWN_LOGGED=1
    fi
    return 0
}

# (4) sesi tmux dev: hilang kena boot/reset → dibuat lagi
tmux_refresh() {
    command -v tmux >/dev/null 2>&1 || return 0
    if tmux has-session -t "$DEV_SESSION" 2>/dev/null; then return 0; fi
    tmux new-session -d -s "$DEV_SESSION" 2>/dev/null || true
    return 0
}

# peringatan Tailscale: maximal 1 baris tiap TS_WARN_EVERY siklus (anti log penuh)
_ts_warn_n=0
ts_warn() {
    _ts_warn_n=$((_ts_warn_n + 1))
    [ $((_ts_warn_n % TS_WARN_EVERY)) -eq 1 ] || return 0
    log "PERINGATAN: $*"
    return 0
}

# (5) Tailscale: keluar otomatis (key expiry/logout) → login ulang sendiri.
# Kalau TS_AUTHKEY belum ada, JANGAN diam — laporkan biar jelas kenapa mesin
# terlihat "keluar". timeout: `tailscale up` bisa hang nunggu login interaktif.
tailscale_refresh() {
    command -v tailscale >/dev/null 2>&1 || return 0
    local st key
    # PENTING (bug lama): `tailscale debug prefs` selalu melaporkan
    # "LoggedOut": false walau mesin sudah "Logged out" → deteksi keluar
    # harus dari BackendState status (NeedsLogin), bukan dari prefs.
    st=$(timeout 15 tailscale status --json 2>/dev/null) || st=""
    if [ -n "$st" ]; then
        printf '%s' "$st" | grep -q '"BackendState": *"NeedsLogin"' || return 0
    else
        timeout 15 tailscale status 2>/dev/null | grep -q '^Logged out' || return 0
    fi
    if [ ! -r "$SECRET_FILE" ]; then
        ts_warn "Tailscale logged out dan $SECRET_FILE tidak ada → auto-login mustahil"
        return 0
    fi
    key=$(. "$SECRET_FILE" 2>/dev/null; printf '%s' "${TS_AUTHKEY:-}")
    if [ -z "$key" ]; then
        ts_warn "Tailscale logged out, TS_AUTHKEY kosong di $SECRET_FILE → isi dulu: TS_AUTHKEY=tskey-auth-... (dari https://login.tailscale.com/admin/settings/keys)"
        return 0
    fi
    if timeout 45 tailscale up --auth-key="$key" --ssh --accept-dns=false 2>/dev/null \
        || timeout 45 tailscale up --auth-key="$key" --ssh --accept-dns=false --reset 2>/dev/null; then
        log "Tailscale login ulang OTOMATIS berhasil"
    else
        ts_warn "login Tailscale gagal (key expired/revoke?) → ganti TS_AUTHKEY di $SECRET_FILE"
    fi
    return 0
}

# Daemon: tanpa set -e → SATU langkah gagal tidak mematikan keep-alive.
while true; do
    x_refresh
    tmux_refresh
    tailscale_refresh
    sleep "$INTERVAL"
done
EOF
    $SUDO install -m 755 "$tmp" "$KEEPALIVE_BIN"
    rm -f "$tmp"

    # Shell login baru: pastikan TMOUT (auto-logout idle) tidak aktif —
    # pelengkap gerak pointer di atas, untuk jaga-jaga image bikin TMOUT.
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
# Dibuat otomatis oleh setup.sh — anti auto-logout shell karena idle.
# TMOUT (detik tanpa ketikan sebelum bash keluar sendiri) dipastikan mati.
unset TMOUT
EOF
    $SUDO install -m 644 "$tmp" /etc/profile.d/00-no-idle-logout.sh
    rm -f "$tmp"

    tmp=$(mktemp)
    cat > "$tmp" <<EOF
; Dibuat otomatis oleh setup.sh (di-regenerate tiap setup dijalankan).
; Keep-alive sesi: anti blank/lock/logout otomatis (lihat script-nya).
[program:session-keepalive]
priority=45
autostart=true
autorestart=true
command=${KEEPALIVE_BIN}
startsecs=3
stopsignal=TERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/session-keepalive.log
stdout_logfile_maxbytes=5242880
stdout_logfile_backups=2
environment=HOME="/root",USER="root",DISPLAY="${disp}"
EOF
    $SUDO install -m 644 "$tmp" "$KEEPALIVE_CONF"
    rm -f "$tmp"
    log "Keep-alive sesi → ${KEEPALIVE_BIN} + $(basename "$KEEPALIVE_CONF") (interval ${KEEPALIVE_INTERVAL:-30}s)"
}

# =========================================================
# 9. BACKUP SCRIPT INI SENDIRI
# =========================================================
# /root/setup.sh = symlink ke /root/mesin-setup/setup.sh (repo GitHub), dan
# begitu juga /root/menu.sh. Repo-nya PUBLIK supaya bisa di-clone tanpa token
# — jadi restore-nya tetap jalan walau GH_TOKEN belum ada sama sekali.
#
# Pindahkan script hasil curl ke dalam repo + pasang symlink /root/<nama>.
# Dipakai untuk setup.sh dan menu.sh. Idempoten: tidak ada yang dipindah
# kalau sudah rapi.
adopt_script() {
    local dir="/root/mesin-setup" name="$1"
    # masih berupa file biasa (hasil curl) → pindahkan ke dalam repo
    if [ -f "/root/$name" ] && [ ! -L "/root/$name" ]; then
        mv -f "/root/$name" "$dir/$name"
        log "$name dirapikan → $dir/$name (jalur /root/$name tetap jalan)"
    fi
    # belum ada di /root → pasang symlink biar jalurnya tetap pendek
    if [ -f "$dir/$name" ] && [ ! -e "/root/$name" ]; then
        ln -sfn "mesin-setup/$name" "/root/$name"
    fi
}

ensure_setup_repo() {
    local dir="/root/mesin-setup" url="https://github.com/AgungAG/mesin-setup.git"
    command -v git >/dev/null 2>&1 || return 0
    if [ -e "$dir/.git" ]; then
        adopt_script setup.sh
        adopt_script menu.sh
        return 0
    fi
    [ -f /root/setup.sh ] || return 0
    [ ! -L /root/setup.sh ] || return 0

    log "Ambil repo setup.sh dari GitHub (publik, tanpa token)..."
    [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ] && rmdir "$dir"
    if ! git clone --quiet "$url" "$dir"; then
        warn "Clone repo setup gagal (offline?) → script tetap jalan dari /root/setup.sh"
        return 0
    fi
    adopt_script setup.sh
    adopt_script menu.sh
    log "setup.sh ada di $dir/setup.sh (jalur /root/setup.sh tetap jalan)"
}

backup_setup() {
    local dir="/root/mesin-setup"
    command -v git >/dev/null 2>&1 || return 0
    [ -e "$dir/.git" ] || return 0
    git -C "$dir" add setup.sh menu.sh README.md
    [ ! -d "$dir/bot-telegram" ] || git -C "$dir" add bot-telegram .gitignore
    if git -C "$dir" diff --cached --quiet 2>/dev/null; then
        log "Backup setup.sh: tidak ada perubahan"
    else
        git -C "$dir" commit -qm "backup otomatis $(date '+%F %T')"
        log "Backup setup.sh: $(git -C "$dir" log -1 --oneline)"
        if git -C "$dir" push --quiet 2>/dev/null; then
            log "Push setup.sh ke GitHub OK"
        else
            warn "Push setup.sh gagal → login gh dulu biar perubahan tersimpan di luar mesin"
        fi
    fi
}

# Kebiasaan kerja: selalu ada tmux session untuk opencode.
start_dev_session() {
    command -v tmux >/dev/null 2>&1 || return 0
    if tmux has-session -t "$DEV_SESSION" 2>/dev/null; then
        log "tmux session '$DEV_SESSION' sudah ada"
    else
        tmux new-session -d -s "$DEV_SESSION"
        log "tmux session '$DEV_SESSION' dibuat → tmux attach -t $DEV_SESSION"
    fi
}

# =========================================================
# MAIN
# =========================================================
main() {
    load_secrets

    # Mode ringan `tools` (menu.sh opsi 2 — Only Tools): cukup apt update +
    # gh + opencode + Brave + upterm + TeraBox + alias oce/age + setup bot
    # Telegram. Sengaja berhenti DI SINI — tidak menyentuh service/supervisor
    # LAIN (kecuali conf+start bot Telegram), jadi aman dijalankan kapan saja
    # tanpa memutus sesi yang sedang jalan.
    if [ "${1:-}" = "tools" ]; then
        log "Only Tools: apt update + gh + opencode + Brave + upterm + TeraBox + alias oce/age + bot Telegram (tanpa setup penuh)"
        reset_google_chrome_repo
        ensure_google_chrome_repo
        apt_update
        install_gh
        install_brave
        install_upterm
        install_opencode
        install_terabox
        ensure_aliases
        # Bot Telegram: tulis conf + terapkan LEWAT supervisor (reread/update
        # hanya menyentuh conf yang berubah) + start bot-nya saja.
        resolve_binaries
        setup_telegram_bot
        setup_keepalive
        # Terapkan LEWAT supervisor (reread/update hanya menyentuh conf yang
        # berubah) + start bot-nya dan keep-alive saja.
        if [ -S "$SUPERVISOR_RUN" ]; then
            supervisorctl reread >/dev/null 2>&1 || true
            supervisorctl update >/dev/null 2>&1 || true
            if [ -f "$SUPERVISOR_DIR/30-tgbot.conf" ]; then
                start_service tg-opencode-bot
            fi
            if [ -f "$SUPERVISOR_DIR/40-keepalive.conf" ]; then
                start_service session-keepalive
            fi
        fi
        # service OpenCode dinyalakan belakangan (best-effort, non-fatal):
        # bot-nya sudah jalan duluan di atas, tapi tanpa service ini dia belum
        # bisa menjawab — jadi dipanaskan setelah conf bot beres.
        warm_opencode_service
        log "Only Tools selesai"
        return 0
    fi

    # PALING AWAL — buang sisa Chrome lama dulu, baru dipasang ulang.
    # Kalau dilewat, apt update pertama bisa gagal NO_PUBKEY.
    reset_google_chrome_repo
    ensure_google_chrome_repo
    install_packages
    install_gh
    ensure_setup_repo
    install_tailscale
    install_opencode
    install_cloudflared
    install_chrome
    install_brave
    install_upterm
    install_terabox
    ensure_aliases
    ensure_site

    # GitHub login di SINI (bukan di bawah): agar klone repo privat (kasir-roti)
    # bisa jalan SEBELUM supervisor conf-nya dibuat → satu run langsung onlen.
    setup_gh
    restore_kasir
    setup_telegram_bot
    setup_keepalive

    resolve_binaries
    write_supervisor_confs

    # Ambil-alih tailscaled = proses induk sesi Tailscale SSH dihentikan, jadi
    # sesi Termius bisa ikut mati di tengah jalan. Supaya migrasi tetap selesai:
    # abaikan SIGHUP, dan kalau bukan dari dalam tmux pindahkan keluaran ke file
    # biar tidak hilang bersama layarnya.
    if [ "$TAKE_TAILSCALE" = "1" ] && [ "$TAILSCALE_STRAY" = "1" ]; then
        trap '' HUP
        if [ -z "${TMUX:-}" ]; then
            printf '\n=== %s ambil-alih tailscaled; log lanjutan di %s ===\n' \
                "$(date '+%F %T')" "$HANDOVER_LOG" >> "$HANDOVER_LOG"
            warn "Ambil-alih tailscaled → sesi SSH akan putus. Log pindah ke $HANDOVER_LOG"
            exec >>"$HANDOVER_LOG" 2>&1
        else
            warn "Ambil-alih tailscaled → sesi SSH akan putus (tmux tetap hidup)"
        fi
    fi

    take_over_strays
    reload_supervisor
    remove_sshd

    # tailscaled: dilewati kalau sengaja ditunda (masih manual & berjalan)
    if [ "$TAKE_TAILSCALE" = "0" ] && [ "$TAILSCALE_STRAY" = "1" ]; then
        warn "tailscaled masih dijalankan manual (defer)"
    else
        start_service tailscaled "cd / && nohup ${TSD_BIN} --tun=userspace-networking --socks5-server=localhost:1055 --state=/var/lib/tailscale/tailscaled.state >/var/log/tailscaled.log 2>&1 &"
    fi

    start_service site-server "cd ${SITE_DIR} && nohup ${PY_BIN} -m http.server ${SITE_PORT} --bind 0.0.0.0 >/var/log/site-server.log 2>&1 &"
    # service OpenCode dulu (conf 25-opencode.conf) — bot butuh ini buat menjawab
    if [ -f "$SUPERVISOR_DIR/25-opencode.conf" ]; then
        start_service opencode-serve
    fi
    warm_opencode_service
    # bot Telegram: hanya kalau conf-nya ada (token kosong → conf dibuang di atas)
    if [ -f "$SUPERVISOR_DIR/30-tgbot.conf" ]; then
        start_service tg-opencode-bot
    fi
    # keep-alive: sesi tidak boleh keluar/blank/lock otomatis — service ini
    # yang menjaga layar tetap hidup + pointer "bergerak" sejak boot
    if [ -f "$SUPERVISOR_DIR/40-keepalive.conf" ]; then
        start_service session-keepalive
    fi
    if [ "$USE_CLOUDFLARED" = "1" ]; then
        start_service cloudflared "${CLOUDFLARED_BIN} tunnel --url http://localhost:${SITE_PORT}"
        # kasir web: hanya kalau binarinya terpasang (conf 30-kasir.conf dibuat di atas)
        if [ -x /usr/local/bin/kasir-roti ] && [ -f "$SUPERVISOR_DIR/30-kasir.conf" ]; then
            start_service kasir-roti "/usr/local/bin/kasir-roti --serve --port 8080"
            start_service kasir-cloudflared "${CLOUDFLARED_BIN} tunnel --url http://localhost:8080"
        fi
    fi

    login_tailscale
    setup_serve
    capture_tunnel_url
    capture_kasir_url

    restore_site
    configure_git_identity
    backup_site
    backup_kasir
    backup_setup
    start_dev_session

    save_secrets
    summary
}

summary() {
    local ts_ip ts_host
    ts_ip=$(tailscale ip -4 2>/dev/null | head -1 || echo 'belum login')
    ts_host=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)
    [ -n "$SERVE_URL" ] || SERVE_URL="http://${ts_host:-<mesin>}:${SITE_PORT} (aktif setelah tailscale serve jalan)"

    log "SELESAI ✅"
    echo
    echo "Ringkasan:"
    echo "  Tailscale IP  : $ts_ip"
    echo "  Akses web     : $SERVE_URL"
    if [ -n "$TUNNEL_URL" ]; then
        echo "  Tunnel publik : $TUNNEL_URL"
    elif [ "$USE_CLOUDFLARED" = "1" ]; then
        echo "  Tunnel publik : $(cat "$TUNNEL_URL_FILE" 2>/dev/null || echo 'belum ada')"
    fi
    if [ -n "$KASIR_URL" ]; then
        echo "  Kasir online  : $KASIR_URL"
    elif [ -f "$KASIR_URL_FILE" ] && [ "$USE_CLOUDFLARED" = "1" ]; then
        echo "  Kasir online  : $(cat "$KASIR_URL_FILE" 2>/dev/null || echo 'belum ada')"
    fi
    echo "  Web lokal     : http://localhost:${SITE_PORT}   (dir: ${SITE_DIR})"
    echo "  OpenCode      : $(command -v opencode 2>/dev/null || echo "$OPENCODE_DIR/opencode")"
    if [ -f "$SUPERVISOR_DIR/25-opencode.conf" ]; then
        echo "  OpenCode svc  : opencode serve (dijaga supervisor → bot langsung bisa jawab)"
    fi
    if [ -f "$SUPERVISOR_DIR/30-tgbot.conf" ] && [ -n "$TG_BOT_TOKEN" ]; then
        echo "  Bot Telegram  : $(grep -o 'directory=.*' "$SUPERVISOR_DIR/30-tgbot.conf" | cut -d= -f2)  (chat id: ${TG_CHAT_IDS:-belum ada})"
    fi
    echo "  Brave         : brave  (wrapper otomatis --no-sandbox; asli: /usr/bin/brave-browser)"
    echo "  Upterm        : $(command -v upterm 2>/dev/null || echo "$UPTERM_BIN")  → menu: bash /root/menu.sh (opsi 2)"
    echo "  TeraBox       : terabox  (jendela app anti-blank; kalau blank: rm -rf /root/.config/terabox-app)"
    echo "  Alias         : oce → opencode   age → bash /root/menu.sh  (di /root/.bashrc)"
    if [ -f "$KEEPALIVE_CONF" ]; then
        echo "  Keep-alive    : session-keepalive (layar tidak blank/lock, pointer jalan; log: /var/log/session-keepalive.log)"
    fi
    echo "  SSH           : tailscale ssh root@${ts_ip}  (tanpa password; dari Termius/HP)"
    echo "  tmux          : tmux attach -t ${DEV_SESSION}"
    echo "  Secret        : $SECRET_FILE (chmod 600)"
    echo
    echo "Status service (supervisor):"
    # catatan: supervisorctl status exit-nya 3 kalau ada program tidak RUNNING,
    # jadi jangan dipakai sebagai penanda "supervisor mati"
    if [ -S "$SUPERVISOR_RUN" ]; then
        supervisorctl status 2>/dev/null | sed 's/^/  /' || true
    else
        echo "  (supervisor tidak jalan)"
    fi
    echo
    echo "Catatan:"
    echo "  • Sesi ANTI keluar-otomatis: session-keepalive mematikan screensaver X,"
    echo "    menggerakkan pointer tiap ${KEEPALIVE_INTERVAL:-60} detik, menghidupkan lagi tmux"
    echo "    session, dan re-login Tailscale kalau key-nya kedaluwarsa."
    echo "  • tailscaled/web/tunnel/service OpenCode/bot Telegram dijaga supervisord"
    echo "    → ikut bangun sendiri tiap container hidup. Cek: supervisorctl status"
    echo "  • Menu interaktif: age (bash /root/menu.sh) → 1) Full Install"
    echo "    2) Only Tools: gh+opencode+Brave+upterm+TeraBox  3) Generate SSH (Upterm)"
    echo "    4) list sesi  5) stop sesi  6) tambah ID Telegram  7) keluar."
    echo "  • URL https://...ts.net hanya bisa dibuka dari device yang sudah masuk"
    echo "    tailnet (HP/laptop yang login Tailscale). Luar tailnet → pakai tunnel"
    echo "    cloudflared di atas."
    echo "  • Desktop/VNC/nginx dari image bawaan, tidak perlu di-setup."
    if [ "$TAKE_TAILSCALE" = "0" ] && [ "${TAILSCALE_STRAY:-0}" = "1" ]; then
        echo "  • tailscaled MASIH MANUAL. Pindahkan nanti dengan:"
        echo "      TAKE_TAILSCALE=1 bash $0   (dari dalam tmux; pas tidak ada sesi remote)"
    fi
    echo "  • Script ini sudah ada di GitHub (publik) → restore dari nol:"
    echo "      curl -fsSL -o setup.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/setup.sh"
    echo "      bash setup.sh"
    echo
}

main "$@"
