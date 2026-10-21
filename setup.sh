#!/usr/bin/env bash
#
# setup.sh — Restore mesin ini dari nol (setelah reset)
#
# Semua langkah IDEMPOTEN: boleh dijalankan berkali-kali, hasilnya tetap sama.
#
# Yang disetup:
#   1. Paket dasar    : git, tmux, gh, jq, curl, ca-certificates
#   2. Tailscale      : install + tailscaled jalan + login (--ssh)
#   3. OpenCode       : install + PATH di .bashrc
#   4. SSH            : openssh-server + login root via password
#   5. Web toko roti  : http.server :8000 di /root/toko-roti
#   6. Akses online   : tailscale serve (URL tetap) + tunnel cloudflared (opsional)
#   7. GitHub         : gh login dari GH_TOKEN, identitas git, auto-commit toko-roti
#
# CARA KERJA PENTING:
#   tailscaled, sshd, web server, dan tunnel dijaga SUPERVISORD — yang memang
#   sudah jalan sejak container hidup dan auto-restart. Bukan `nohup &` manual.
#   Jadi service ikut bangun sendiri tiap mesin hidup, tanpa diapa-apain.
#   Desktop/VNC/nginx itu urusan image bawaan — script ini tidak menyentuhnya.
#
# Pemakaian:
#   bash setup.sh
#
# RESTORE DARI NOL (mesin baru / habis reset, /root sudah bersih):
#   curl -fsSL -o setup.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/setup.sh
#   bash setup.sh
#   Repo setup.sh ini PUBLIK supaya bisa diambil tanpa token sama sekali.
#   Yang dibutuhkan tinggal: TS_AUTHKEY / ROOT_PASSWORD / GH_TOKEN (isi via env
#   atau tulis ke /root/.machine-secrets dengan format NAME=value, chmod 600).
#   Repo toko-roti PRIVAT → butuh GH_TOKEN untuk clone/push.
#
# Environment variable (semua opsional; juga bisa dititip di /root/.machine-secrets
# supaya tidak perlu diketik ulang tiap restore):
#   TS_AUTHKEY=tskey-auth-xxxx  Login Tailscale otomatis tanpa klik link.
#                               Ambil dari: https://login.tailscale.com/admin/settings/keys
#   ROOT_PASSWORD=rahasia123    Password root. Kalau kosong dibuat random, lalu disimpan.
#   GH_TOKEN=ghp_xxxx           Token GitHub supaya gh login otomatis.
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
HANDOVER_LOG="/root/setup-takeover.log"

TS_AUTHKEY="${TS_AUTHKEY:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
GH_TOKEN="${GH_TOKEN:-}"
SITE_REPO="${SITE_REPO:-AgungAG/toko-roti}"

# Hasil yang dicetak di ringkasan akhir
SERVE_URL=""
TUNNEL_URL=""

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# =========================================================
# 0. SECRET
# =========================================================
# Supaya reset tidak bikin lupa password/token: simpan sekali, baca lagi.
load_secrets() {
    [ -r "$SECRET_FILE" ] || return 0
    set +u
    # shellcheck source=/dev/null
    . "$SECRET_FILE"
    set -u
    log "Secret dibaca dari $SECRET_FILE"
}

save_secrets() {
    local tmp="${SECRET_FILE}.tmp" var val
    : > "$tmp"
    for var in ROOT_PASSWORD TS_AUTHKEY GH_TOKEN; do
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
# 1. PAKET DASAR
# =========================================================
install_packages() {
    local need=() p
    for p in git tmux gh jq curl ca-certificates; do
        dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
    done
    if [ "${#need[@]}" -eq 0 ]; then
        log "Paket dasar sudah lengkap (git tmux gh jq curl ca-certificates)"
        return
    fi
    log "Install paket: ${need[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
}

# =========================================================
# 2. TAILSCALE
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
        return
    fi

    if ! tailscale status 2>/dev/null | grep -q 'Logged out'; then
        log "Tailscale sudah login: $(tailscale ip -4 2>/dev/null || true)"
    elif [ -n "$TS_AUTHKEY" ]; then
        log "Login Tailscale pakai auth key (otomatis)..."
        # --ssh supaya bisa masuk dari Termius; auth key noncesih node lama boleh hilang
        tailscale up --auth-key="$TS_AUTHKEY" --ssh --accept-dns=false
        sleep 2
    else
        log "Login Tailscale — buka link ini di browser:"
        echo
        tailscale up --ssh || true
        echo
        warn "Setelah login di browser, jalankan lagi: bash $0"
        warn "(atau set TS_AUTHKEY agar otomatis)"
        return
    fi

    # pastikan Tailscale SSH tetap nyala (tersimpan di prefs, dicek ulang tiap run)
    if ! tailscale debug prefs 2>/dev/null | grep -q '"RunSSH": true'; then
        warn "Tailscale SSH belum aktif → nyalakan lagi"
        tailscale up --ssh --accept-dns=false || true
    fi
    log "IP Tailscale: $(tailscale ip -4 2>/dev/null || echo 'belum dapat')"
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
# 3. OPENCODE
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
    export PATH="$OPENCODE_DIR:$PATH"
    log "OpenCode: $(command -v opencode || echo "$OPENCODE_DIR/opencode")"
}

# =========================================================
# 4. SSH
# =========================================================
install_ssh() {
    if ! command -v sshd >/dev/null 2>&1; then
        log "Install openssh-server..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    else
        log "OpenSSH sudah terinstall"
    fi
}

configure_ssh() {
    log "Konfigurasi login root via password..."
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/root-login.conf

    if [ -z "$ROOT_PASSWORD" ]; then
        ROOT_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=')
        warn "Password root BARU dibuat random: $ROOT_PASSWORD"
    fi
    echo "root:$ROOT_PASSWORD" | chpasswd
    log "Password root di-set (sshd-nya nanti dijalankan supervisor)"
}

# =========================================================
# 5. SUPERVISOR — semua daemon di sini
# =========================================================
# Kenapa supervisor? Container ini tanpa systemd, tapi supervisord sudah jalan
# dari awal container hidup + auto-restart. Service yang dipasang di sini ikut
# bangun sendiri tiap mesin hidup — tanpa `bash setup.sh` lagi.
resolve_binaries() {
    TSD_BIN="$(command -v tailscaled || echo /usr/sbin/tailscaled)"
    SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
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

    if ! supervisor_has sshd && pgrep -x sshd >/dev/null 2>&1; then
        warn "Hentikan sshd manual → pindah ke supervisor"
        pkill -x sshd || true
        wait_gone -x sshd
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

[program:sshd]
priority=10
autostart=true
autorestart=true
command=/bin/bash -c "mkdir -p /run/sshd && exec ${SSHD_BIN} -D -e"
startsecs=3
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/sshd.log
stdout_logfile_maxbytes=10485760
stdout_logfile_backups=3

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
    else
        rm -f "$SUPERVISOR_DIR/20-cloudflared.conf"
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
# 6. WEB TOKO ROTI + TUNNEL
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

# =========================================================
# 7. GITHUB + BACKUP TOKO ROTI
# =========================================================
setup_gh() {
    command -v gh >/dev/null 2>&1 || return 0
    if ! gh auth status >/dev/null 2>&1; then
        if [ -n "$GH_TOKEN" ]; then
            log "GitHub login pakai GH_TOKEN..."
            printf '%s' "$GH_TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token
        else
            warn "GitHub belum login → set GH_TOKEN lalu jalankan ulang: $0"
            return 0
        fi
    fi
    gh auth setup-git >/dev/null 2>&1 || true
    gh alias set co "pr checkout" >/dev/null 2>&1 || true
    log "GitHub login: $(gh api user -q .login 2>/dev/null || echo OK)"
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
# 8. BACKUP SCRIPT INI SENDIRI
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

    install_packages
    ensure_setup_repo
    install_tailscale
    install_ssh
    install_opencode
    install_cloudflared
    ensure_site
    configure_ssh

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

    # tailscaled: dilewati kalau sengaja ditunda (masih manual & berjalan)
    if [ "$TAKE_TAILSCALE" = "0" ] && [ "$TAILSCALE_STRAY" = "1" ]; then
        warn "tailscaled masih dijalankan manual (defer)"
    else
        start_service tailscaled "cd / && nohup ${TSD_BIN} --tun=userspace-networking --socks5-server=localhost:1055 --state=/var/lib/tailscale/tailscaled.state >/var/log/tailscaled.log 2>&1 &"
    fi

    start_service sshd "${SSHD_BIN}"
    start_service site-server "cd ${SITE_DIR} && nohup ${PY_BIN} -m http.server ${SITE_PORT} --bind 0.0.0.0 >/var/log/site-server.log 2>&1 &"
    if [ "$USE_CLOUDFLARED" = "1" ]; then
        start_service cloudflared "${CLOUDFLARED_BIN} tunnel --url http://localhost:${SITE_PORT}"
    fi

    login_tailscale
    setup_serve
    capture_tunnel_url

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
    echo "  Web lokal     : http://localhost:${SITE_PORT}   (dir: ${SITE_DIR})"
    echo "  OpenCode      : $(command -v opencode 2>/dev/null || echo "$OPENCODE_DIR/opencode")"
    echo "  SSH           : root@${ts_ip} port 22  (atau tailscale SSH dari Termius)"
    echo "  tmux          : tmux attach -t ${DEV_SESSION}"
    if [ -n "$ROOT_PASSWORD" ]; then
        echo "  Password root : $ROOT_PASSWORD"
    fi
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
    echo "  • tailscaled/sshd/web/tunnel dijaga supervisord → ikut bangun sendiri"
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
