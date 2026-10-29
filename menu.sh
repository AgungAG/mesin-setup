#!/usr/bin/env bash
#
# menu.sh — menu interaktif mesin-setup
#
# Opsi:
#   1) Full Install         → jalankan setup.sh penuh (restore mesin dari nol:
#                              paket dasar, Google Chrome, Brave wrapper
#                              --no-sandbox, Tailscale, OpenCode, upterm,
#                              TeraBox (jendela app anti-blank), alias
#                              oce/age, web toko roti, tunnel, GitHub). Kalau
#                              setup.sh belum ada — misal habis reset, yang
#                              di-download cuma menu.sh — filenya diambil
#                              otomatis dari GitHub dulu. SELESAI → otomatis
#                              lanjut ke langkah opsi 3.
#   2) Only Tools           → `bash setup.sh tools` (mode ringan): refresh
#                              repo lalu pasang gh, opencode, Brave, upterm,
#                              TeraBox, alias oce/age + setup bot Telegram
#                              (config + supervisor). Tidak menyentuh
#                              service/supervisor lain → aman kapan saja.
#                              SELESAI → otomatis lanjut ke langkah opsi 3.
#   3) Generate SSH (Upterm)
#                           → upterm host --accept -- bash. Begitu command
#                              SSH tercetak, OTOMATIS disalin ke clipboard
#                              (OSC 52 ke terminal + xclip di desktop VNC)
#                              dan disimpan ke /root/upterm-ssh.txt → tinggal
#                              paste di mesin lain. Sesi mati kalau host-nya
#                              keluar.
#   4) List sesi upterm     → tampilkan sesi upterm yang sedang berjalan
#                              (nama, status, ID, jumlah tamu).
#   5) Stop semua sesi      → hentikan SEMUA sesi upterm yang aktif (ada
#         upterm              konfirmasi dulu; sesi terminal ini sendiri bisa
#                              ikut terputus kalau terminalnya join via upterm).
#   6) Tambah ID Telegram   → daftarkan ID chat Telegram baru ke bot, BOLEH
#                              LEBIH DARI SATU sekaligus (pisah spasi/koma).
#                              ID disimpan ke /root/.machine-secrets +
#                              config.json bot, lalu bot di-restart → ID baru
#                              langsung bisa chat. (ID Anda: kirim pesan ke
#                              bot — balasan "Chat tidak terdaftar" memuat
#                              "ID Anda: <angka>".)
#   7) Keluar
#
# Pemakaian:
#   bash /root/menu.sh        (jalur pendek; symlink ke mesin-setup/menu.sh)
#   bash menu.sh              (dari dalam repo)
#   age                       (alias di .bashrc → = bash /root/menu.sh;
#                              alias oce = opencode — keduanya dibuat otomatis
#                              oleh setup.sh, opsi 1 & 2)
#
# TeraBox: langkah install-nya ada di setup.sh (opsi 1 & 2) — dibuka sebagai
#   jendela app anti-blank lewat `terabox` atau ikon desktop.
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
# Dipakai opsi 6 (tambah ID Telegram): tempat secret setup.sh + config bot
# (keduanya harus ikut diperbarui supaya ID tidak hilang kena reset).
SECRET_FILE="/root/.machine-secrets"
TG_BOT_DIR="/root/tg-opencode-bot"

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

# --- Opsi 1: Full Install ----------------------------------------------
install_all() {
    ensure_setup_sh || return 0
    log "Full Install: bash $SETUP_SH"
    laporkan_status bash "$SETUP_SH"
    # Setelah setup penuh selesai, otomatis lanjut ke langkah opsi 3 —
    # begitu upterm terpasang, sesi SSH langsung dibuat + auto-copy.
    lanjut_generate_ssh
}

# --- Opsi 2: Only Tools -------------------------------------------------
# Mode ringan setup.sh: apt update + Brave + upterm + TeraBox + alias
# oce/age + bot Telegram. Tanpa setup penuh.
install_tools() {
    ensure_setup_sh || return 0
    log "Only Tools: bash $SETUP_SH tools"
    laporkan_status bash "$SETUP_SH" tools
    # Sama seperti opsi 1: otomatis lanjut ke langkah opsi 3 (upterm sudah
    # dipasang mode tools → sesi SSH langsung bisa dibuat).
    lanjut_generate_ssh
}

# Otomatis jalankan langkah opsi 3 setelah opsi 1/2 selesai.
# Kalau upterm belum terpasang (install gagal/offline), host_session sendiri
# yang memberi peringatan — opsi lain tetap bisa dipakai.
lanjut_generate_ssh() {
    log "Lanjut otomatis ke opsi 3: Generate SSH (Upterm) + copy clipboard..."
    host_session
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

# --- Opsi 4 & 5: sesi upterm -------------------------------------------
# Ambil baris "nama<TAB>session-id" untuk tiap sesi upterm yang berjalan.
# JSON-nya di-parse python3 (selalu ada di image ini) dengan cadangan jq —
# parsing tabel teks rawan pecah kalau format CLI upterm berubah.
upterm_session_pairs() {
    local json
    json=$(upterm session list -o json 2>/dev/null) || return 1
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c 'import json,sys
for s in json.load(sys.stdin):
    print("%s\t%s" % (s.get("name","?"), s.get("sessionId","?")))'
    elif command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.[] | "\(.name)\t\(.sessionId)"'
    else
        return 1
    fi
}

# --- Opsi 4 ------------------------------------------------------------
list_sessions() {
    if ! command -v upterm >/dev/null 2>&1; then
        warn "upterm belum terinstall → jalankan opsi 1 atau 2 dulu"
        return 0
    fi
    local out rc=0 n=0
    out=$(upterm session list 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "upterm session list gagal: $out"
        return 0
    fi
    printf '%s\n' "$out"
    n=$(upterm_session_pairs 2>/dev/null | grep -c . || true)
    if [ "${n:-0}" -eq 0 ]; then
        log "Tidak ada sesi upterm yang berjalan"
    else
        log "$n sesi berjalan — detail: upterm session info <nama>   (stop: opsi 5)"
    fi
    return 0
}

# --- Opsi 5 ------------------------------------------------------------
# Hentikan semua sesi upterm. Sengaja minta konfirmasi: kalau terminal INI
# sendiri join lewat upterm (opsi 3), sesi sendiri ikut mati → koneksi putus.
stop_sessions() {
    if ! command -v upterm >/dev/null 2>&1; then
        warn "upterm belum terinstall → jalankan opsi 1 atau 2 dulu"
        return 0
    fi
    local pairs n=0 name id stopped=0 failed=0 cur="" jawab=""
    if ! pairs=$(upterm_session_pairs 2>/dev/null); then
        warn "daftar sesi tidak bisa dibaca (butuh python3/jq) → tidak ada yang dihentikan"
        return 0
    fi
    n=$(printf '%s\n' "$pairs" | grep -c . || true)
    if [ "${n:-0}" -eq 0 ]; then
        log "Tidak ada sesi upterm yang berjalan"
        return 0
    fi

    echo "Sesi yang akan dihentikan:"
    printf '%s\n' "$pairs" | awk -F'\t' '{printf "  • %s  (%s)\n", $1, $2}'

    # 'upterm session current' sukses kalau terminal ini sendiri ada di dalam
    # sesi upterm → peringatan sebelum user menjawab y.
    cur=$(upterm session current 2>/dev/null | awk '/^Session:/{print $2; exit}' || true)
    if [ -n "$cur" ] && printf '%s\n' "$pairs" | grep -Fq "$cur"; then
        warn "Terminal INI sendiri ada di sesi di atas → koneksi bisa TERPUTUS"
    fi

    read -r -p "  Hentikan semua sesi di atas? [y/N] " jawab || jawab=""
    case "$jawab" in
        y|Y|ya|Ya|YA) ;;
        *) log "Dibatalkan — tidak ada sesi yang dihentikan"; return 0 ;;
    esac

    while IFS=$'\t' read -r name id; do
        [ -n "$id" ] || continue
        if upterm session stop "$id" >/dev/null 2>&1; then
            log "Dihentikan: $name ($id)"
            stopped=$((stopped + 1))
        else
            warn "Gagal menghentikan: $name ($id)"
            failed=$((failed + 1))
        fi
    done <<EOF
$pairs
EOF
    log "Selesai: $stopped dihentikan, $failed gagal"
    return 0
}

# --- Opsi 6 ------------------------------------------------------------
# Tambah ID chat Telegram secara manual — BOLEH LEBIH DARI SATU sekaligus
# (pisah spasi/koma). Kenapa dua tempat penyimpanan?
#   1. $SECRET_FILE (TG_CHAT_IDS=...) → dibaca load_secrets di setup.sh tiap
#      restore → ID tidak hilang kena reset mesin.
#   2. $TG_BOT_DIR/config.json (allowed_chat_ids) → yang benar-benar dibaca
#      bot.py untuk memilih chat yang diizinkan masuk.
# Setelah config ditulis, bot di-restart: bot.py membaca config saat START →
# tanpa restart ID baru belum aktif.
add_chat_ids() {
    local py conf jawab cur="" all rc=0
    py="$(command -v python3 || echo /usr/bin/python3)"
    conf="$TG_BOT_DIR/config.json"

    if [ ! -f "$conf" ] && [ ! -f "$SECRET_FILE" ]; then
        warn "bot Telegram belum pernah di-setup → jalankan opsi 2 dulu"
        return 0
    fi

    # ID yang sudah terdaftar (dari config bot bila ada)
    if [ -f "$conf" ]; then
        cur=$("$py" -c 'import json,sys
try:
    ids = json.load(open(sys.argv[1])).get("allowed_chat_ids") or []
    print(" ".join(str(x) for x in ids))
except Exception:
    pass' "$conf" 2>/dev/null) || cur=""
    fi
    if [ -n "$cur" ]; then
        log "ID sudah terdaftar: $cur"
    else
        log "Belum ada ID terdaftar (kirim pesan ke bot untuk melihat ID Anda)"
    fi

    while true; do
        read -r -p "  ID baru (pisah spasi/koma, boleh lebih dari satu; kosong = batal): " jawab || jawab=""
        jawab="${jawab//,/ }"
        if [ -z "${jawab// }" ]; then
            log "Dibatalkan — tidak ada ID ditambahkan"
            return 0
        fi
        # semua token wajib angka; minus di depan dibolehkan untuk ID grup
        if printf '%s\n' $jawab | grep -qEv '^-?[0-9]+$'; then
            warn "Input harus ANGKA saja (ID grup boleh minus, mis. -1001234567) — ulangi"
            continue
        fi
        break
    done

    # gabung ID lama + baru, buang duplikat (ID baru di belakang)
    all=$(printf '%s\n' $cur $jawab | awk 'NF && !seen[$0]++ {printf "%s%s", sep, $0; sep=","}')

    # 1) simpan permanen ke .machine-secrets (format NAME=value, chmod 600)
    if [ -f "$SECRET_FILE" ]; then
        rc=0
        grep -v '^TG_CHAT_IDS=' "$SECRET_FILE" > "$SECRET_FILE.tmp" 2>/dev/null || rc=$?
        if [ "$rc" -le 1 ]; then
            chmod 600 "$SECRET_FILE.tmp" 2>/dev/null || true
            mv -f "$SECRET_FILE.tmp" "$SECRET_FILE"
        else
            rm -f "$SECRET_FILE.tmp"
            warn "$SECRET_FILE gagal dibaca → ID belum tersimpan permanen"
        fi
    fi
    if printf 'TG_CHAT_IDS=%s\n' "$all" >> "$SECRET_FILE" 2>/dev/null; then
        chmod 600 "$SECRET_FILE"
        log "TG_CHAT_IDS disimpan di $SECRET_FILE (ikut pulih tiap reset)"
    else
        warn "menulis $SECRET_FILE gagal (permission?) → ID hanya aktif sampai restore berikutnya"
    fi

    # 2) tulis ke config.json bot (RAHASIA → chmod 600, tulis atomik)
    if [ -f "$conf" ]; then
        if "$py" - "$conf" "$all" <<'PYEOF'
import json, os, sys
path, raw = sys.argv[1], sys.argv[2]
ids = [int(x) for x in raw.split(",") if x.strip()]
with open(path) as f:
    cfg = json.load(f)
cfg["allowed_chat_ids"] = ids
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PYEOF
        then
            log "allowed_chat_ids diperbarui → $conf"
        else
            warn "menulis $conf gagal → jalankan opsi 2 untuk memperbarui config bot"
            return 0
        fi
    else
        warn "$conf tidak ada → jalankan opsi 2; ID tetap tersimpan di $SECRET_FILE"
        return 0
    fi

    # 3) restart bot → config baru terbaca (dibaca bot.py saat start)
    if [ -S /var/run/supervisor.sock ]; then
        if supervisorctl restart tg-opencode-bot >/dev/null 2>&1 \
            || supervisorctl start tg-opencode-bot >/dev/null 2>&1; then
            log "Bot Telegram di-restart → ID baru langsung bisa chat: $all"
        else
            warn "restart bot gagal → cek: supervisorctl status tg-opencode-bot"
        fi
    else
        warn "supervisor tidak jalan → ID aktif setelah bot dinyalakan lagi (opsi 2)"
        log "ID tersimpan: $all"
    fi
    return 0
}

# --- Menu --------------------------------------------------------------
while true; do
    cat <<'EOF'

  +-- mesin-setup ----------------------------------+
  |  1) Full Install (lalu otomatis ke 3)           |
  |  2) Only Tools (+ bot Telegram, lalu ke 3)      |
  |     (mode ringan: gh, opencode, Brave, upterm)  |
  |  3) Generate SSH (Upterm) + copy clipboard      |
  |  4) List sesi upterm yang aktif                  |
  |  5) Stop semua sesi upterm aktif                 |
  |  6) Tambah ID Telegram (boleh lebih dari satu)   |
  |  7) Keluar                                      |
  +-------------------------------------------------+
EOF
    read -r -p "  Pilih [1-7]: " pilih || { echo; pilih=7; }
    case "$pilih" in
        1)      install_all ;;
        2)      install_tools ;;
        3)      host_session ;;
        4)      list_sessions ;;
        5)      stop_sessions ;;
        6)      add_chat_ids ;;
        7|q|Q)  log "Keluar."; exit 0 ;;
        *)      warn "Pilihan tidak dikenal: '$pilih' (pakai 1/2/3/4/5/6/7)" ;;
    esac
done
