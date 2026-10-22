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
#   3. Tailscale      : install + tailscaled jalan + login (--ssh)
#   4. OpenCode       : install + PATH di .bashrc
#   5. SSH            : TIDAK dipasang — akses masuk lewat Tailscale SSH
#   6. Web toko roti  : http.server :8000 di /root/toko-roti
#   7. Akses online   : tailscale serve (URL tetap) + tunnel cloudflared (opsional)
#   8. GitHub         : gh login dari GH_TOKEN, identitas git, auto-commit toko-roti
#
# CARA KERJA PENTING:
#   tailscaled, web server, dan tunnel dijaga SUPERVISORD — yang memang
#   sudah jalan sejak container hidup dan auto-restart. Bukan `nohup &` manual.
#   Jadi service ikut bangun sendiri tiap mesin hidup, tanpa diapa-apain.
#   Desktop/VNC/nginx itu urusan image bawaan — script ini tidak menyentuhnya.
#
# SSH:
#   TIDAK ada openssh-server/sshd — percuma, karena akses masuk lewat Tailscale
#   SSH yang ditangani langsung oleh tailscaled, bukan oleh sshd. openssh-client
#   tetap ada (buat git ssh dan `tailscale ssh`). Alasan lengkap: remove_sshd.
#
# Pemakaian:
#   bash setup.sh
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
#   SITE_REPO=AgungAG/toko-roti Repo tujuan push backup toko-roti.
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
}

save_secrets() {
    local tmp="${SECRET_FILE}.tmp" var val
    : > "$tmp"
    for var in TS_AUTHKEY GH_TOKEN; do
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
install_packages() {
    local need=() p
    for p in git tmux jq curl ca-certificates; do
        dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
    done
    if [ "${#need[@]}" -eq 0 ]; then
        log "Paket dasar sudah lengkap (git tmux jq curl ca-certificates)"
        return
    fi
    log "Install paket: ${need[*]}"
    apt_update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
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
    if DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable; then
        log "Google Chrome terpasang ($(command -v google-chrome-stable || echo '/usr/bin/google-chrome'))"
    else
        warn "Install Chrome gagal → cek koneksi ke dl.google.com, lalu jalankan ulang:"
        warn "    INSTALL_CHROME=1 bash $0"
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
    # tailscaled dijalankan supervisor → tunggu socketnya siap dulu
    local i
    for i in $(seq 1 20); do
        tailscale status >/dev/null 2>&1 && break
        sleep 1
    done
    if ! tailscale status >/dev/null 2>&1; then
        warn "tailscaled belum siap → cek: supervisorctl status tailscaled dan /var/log/tailscaled.log"
        warn "  (langkah berikutnya tetap dijalankan: GitHub/web tidak ikut berhenti)"
        return 0
    fi

    if tailscale status 2>/dev/null | grep -q 'Logged out'; then
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
install_opencode() {
    if [ -x "$OPENCODE_DIR/opencode" ]; then
        log "OpenCode sudah terinstall ($("$OPENCODE_DIR/opencode" --version 2>/dev/null))"
    else
        log "Install OpenCode..."
        curl -fsSL https://opencode.ai/v2/install | bash
    fi
    # Pastikan ada di PATH lewat .bashrc (aman kalau .bashrc ikut hilang kena reset)
    if ! grep -q '.opencode/bin' /root/.bashrc 2>/dev/null; then
        printf '\n# opencode\nexport PATH=/root/.opencode/bin:$PATH\n' >> /root/.bashrc
    fi
    # Alias singkat: oce = opencode. Ditulis sekali, dicek ulang tiap run.
    if ! grep -q "alias oce=" /root/.bashrc 2>/dev/null; then
        printf "\n# alias opencode\nalias oce='opencode'\n" >> /root/.bashrc
    fi
    export PATH="$OPENCODE_DIR:$PATH"
    log "OpenCode: $(command -v opencode || echo "$OPENCODE_DIR/opencode")"
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
remove_sshd() {
    if dpkg -s openssh-server >/dev/null 2>&1 || command -v sshd >/dev/null 2>&1; then
        log "Hapus openssh-server (sshd tidak dipakai: akses lewat Tailscale SSH)..."
        supervisorctl stop sshd >/dev/null 2>&1 || true
        pkill -x sshd 2>/dev/null || true
        wait_gone -x sshd
        DEBIAN_FRONTEND=noninteractive apt-get purge -y openssh-server >/dev/null 2>&1 \
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
# 9. BACKUP SCRIPT INI SENDIRI
# =========================================================
# /root/setup.sh = symlink ke /root/mesin-setup/setup.sh (repo GitHub).
# Repo-nya PUBLIK supaya bisa di-clone tanpa token — jadi restore-nya tetap
# jalan walau GH_TOKEN belum ada sama sekali.
ensure_setup_repo() {
    local dir="/root/mesin-setup" url="https://github.com/AgungAG/mesin-setup.git"
    command -v git >/dev/null 2>&1 || return 0
    if [ -e "$dir/.git" ]; then
        # script masih berupa file biasa (hasil curl) → pindahkan ke dalam repo
        if [ -f /root/setup.sh ] && [ ! -L /root/setup.sh ]; then
            mv -f /root/setup.sh "$dir/setup.sh"
            ln -sfn "mesin-setup/setup.sh" /root/setup.sh
            log "setup.sh dirapikan → $dir/setup.sh (jalur /root/setup.sh tetap jalan)"
        fi
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
    if [ -f "$dir/setup.sh" ]; then
        mv -f /root/setup.sh "$dir/setup.sh"
    fi
    ln -sfn "mesin-setup/setup.sh" /root/setup.sh
    log "setup.sh ada di $dir/setup.sh (jalur /root/setup.sh tetap jalan)"
}

backup_setup() {
    local dir="/root/mesin-setup"
    command -v git >/dev/null 2>&1 || return 0
    [ -e "$dir/.git" ] || return 0
    git -C "$dir" add setup.sh
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
    ensure_site

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

    setup_gh
    restore_site
    configure_git_identity
    backup_site
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
    echo "  • tailscaled/web/tunnel dijaga supervisord → ikut bangun sendiri"
    echo "    tiap container hidup. Cek: supervisorctl status"
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
