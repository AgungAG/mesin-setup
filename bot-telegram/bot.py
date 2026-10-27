#!/usr/bin/env python3
"""Bot Telegram yang ditenagai model gratis OpenCode.

Cara kerja:
- Long-polling getUpdates (tanpa webhook, tanpa dependensi eksternal).
- Tiap chat Telegram punya sesi OpenCode sendiri (percakapan berkelanjutan).
- Perintah: /new /model /models /id /help
"""
import base64
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
CONFIG = json.load(open(os.path.join(BASE, "config.json")))
STATE_PATH = os.path.join(BASE, "state.json")

TG = "https://api.telegram.org/bot" + CONFIG["token"] + "/%s"
# fallback saja — URL sebenarnya dibaca dari file registrasi service (oc_conn)
OC_URL = CONFIG.get("opencode_url", "http://127.0.0.1:49374").rstrip("/")
MAX_MSG = 3900  # batas aman pesan Telegram (limit resmi 4096)

FREE_MODELS = [
    ("mimo-v2.6-flash-free", "MiMo V2.6 Flash"),
    ("deepseek-v4.1-flash-free", "DeepSeek V4.1 Flash"),
    ("glm-5.3-flash-free", "GLM 5.3 Flash"),
    ("flint-40b-free", "Flint 40B"),
    ("beam-free", "Beam"),
    ("nemotron-3.5-super-vl-free", "Nemotron 3.5 Super VL"),
]

HELP_TEXT = (
    "Bot AI (model gratis OpenCode).\n\n"
    "Kirim pesan apa saja, bot akan menjawab. "
    "Percakapan diingat per chat.\n\n"
    "Perintah:\n"
    "/new - mulai sesi baru (lupa konteks lama)\n"
    "/models - lihat model gratis yang tersedia\n"
    "/model <nomor atau id> - ganti model\n"
    "/id - tampilkan ID chat Anda\n"
    "/help - bantuan ini"
)

# ---------------------------------------------------------------- state ----
_state_lock = threading.Lock()


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"offset": 0, "chats": {}}


def save_state(state):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, STATE_PATH)


STATE = load_state()

# ------------------------------------------------------------- helpers ----


def http_json(url, method="GET", body=None, headers=None, timeout=60):
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return json.loads(raw)
        except ValueError:
            raise RuntimeError("HTTP %s: %s" % (e.code, raw[:300]))
    try:
        return json.loads(raw)
    except ValueError:
        return {"raw": raw}


# URL + password service OpenCode dibaca dari file registrasi milik OpenCode.
# Port-nya DINAMIS (bisa beda tiap reset/boot) → jangan andalkan hardcode.
OC_STATE = os.path.expanduser("~/.local/state/opencode/service.json")
OC_CONFIG_PW = os.path.expanduser("~/.config/opencode/service.json")


def oc_conn():
    """Kembalikan (base_url, password) untuk service OpenCode.

    Service-nya dijaga supervisor (setup.sh: 25-opencode.conf) dan biasanya
    sudah nyala sejak boot. Tapi kalau service.json belum pernah ada (mesin
    baru, service belum sempat start), nyalakan dulu service-nya dan baca
    ulang file registrasinya — tanpa ini bot selalu menjawab "konfigurasi
    OpenCode tidak ditemukan" karena start_service tidak pernah keburu
    dipanggil (oc_conn gagal duluan di luar blok retry oc()).
    """
    for attempt in (0, 1):
        try:
            with open(OC_STATE) as f:
                d = json.load(f)
            if d.get("url") and d.get("password"):
                return d["url"].rstrip("/"), d["password"]
        except (OSError, ValueError):
            pass
        try:
            with open(OC_CONFIG_PW) as f:
                pw = json.load(f)["password"]
            return OC_URL, pw
        except (OSError, ValueError):
            pass
        if attempt == 0:
            start_service()  # service.json baru ditulis opencode saat start
            time.sleep(3)
    raise RuntimeError(
        "service OpenCode belum terdaftar — jalankan: opencode service start"
    )


def start_service():
    """Nyalakan service OpenCode (mis. baru boot, bot nyala duluan)."""
    import shutil
    import subprocess

    # jangan hardcode /root — HOME-nya bisa beda (mis. diuji / dijalankan user
    # lain); jalur instalasi resmi opencode ada di ~/.opencode/bin
    cands = [os.path.expanduser("~/.opencode/bin/opencode")]
    which = shutil.which("opencode")
    if which:
        cands.append(which)

    for cand in cands:
        if not (os.path.isfile(cand) and os.access(cand, os.X_OK)):
            continue
        try:
            r = subprocess.run(
                [cand, "service", "start"],
                timeout=90,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if r.returncode == 0:
                return True
        except (OSError, subprocess.SubprocessError):
            continue
    return False


def oc(method, path, body=None, timeout=60, _retried=False):
    base, pw = oc_conn()
    auth = "Basic " + base64.b64encode(("opencode:" + pw).encode()).decode()
    try:
        res = http_json(
            base + path,
            method=method,
            body=body,
            headers={"Authorization": auth},
            timeout=timeout,
        )
    except urllib.error.URLError as e:
        # service belum jalan / port berubah → coba nyalakan, lalu ulangi sekali
        if not _retried and start_service():
            time.sleep(3)
            return oc(method, path, body, timeout, _retried=True)
        raise RuntimeError("service OpenCode tidak bisa dihubungi: %s" % e)
    if isinstance(res, dict) and res.get("kind"):
        raise RuntimeError(res.get("message", json.dumps(res))[:300])
    return res


def tg(method, api_timeout=60, **params):
    """Panggil Telegram API. `api_timeout` = timeout HTTP lokal;
    `params['timeout']` (jika ada) = timeout long-polling Telegram."""
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(TG % method, data=data)
    try:
        with urllib.request.urlopen(req, timeout=api_timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        print("[tg error] %s %s" % (method, body[:200]), file=sys.stderr)
        return {"ok": False, "description": body[:200]}


def send_text(chat_id, text):
    text = text or "(kosong)"
    chunks = [text[i:i + MAX_MSG] for i in range(0, len(text), MAX_MSG)] or ["(kosong)"]
    for chunk in chunks:
        r = tg("sendMessage", chat_id=chat_id, text=chunk)
        if not r.get("ok") and "too long" in str(r).lower():
            tg("sendMessage", chat_id=chat_id, text=chunk[:MAX_MSG])
        time.sleep(0.3)


class Typing(threading.Thread):
    """Jaga-jaga indikator 'mengetik' selama menunggu jawaban model."""

    def __init__(self, chat_id):
        super().__init__(daemon=True)
        self.chat_id = chat_id
        self.stop_event = threading.Event()

    def run(self):
        while not self.stop_event.wait(4.5):
            tg("sendChatAction", chat_id=self.chat_id, action="typing", timeout=20)


# -------------------------------------------------------------- OpenCode ----


def current_model(chat_id):
    with _state_lock:
        m = STATE["chats"].get(str(chat_id), {}).get("model")
    if m:
        return m
    return dict(CONFIG["model"])


def set_model(chat_id, model_id):
    with _state_lock:
        chat = STATE["chats"].setdefault(str(chat_id), {})
        chat["model"] = {"providerID": "opencode", "id": model_id}
        chat.pop("session", None)  # sesi baru dengan model baru
        save_state(STATE)


def ensure_session(chat_id):
    with _state_lock:
        chat = STATE["chats"].setdefault(str(chat_id), {})
        sid = chat.get("session")
        if sid:
            return sid
    res = oc(
        "POST",
        "/api/session",
        {
            "model": current_model(chat_id),
            "title": "Telegram %s" % chat_id,
            "location": {"directory": CONFIG.get("workdir", "/root")},
        },
    )
    sid = res["data"]["id"]
    with _state_lock:
        chat = STATE["chats"].setdefault(str(chat_id), {})
        if chat.get("session"):  # balapan: pakai yang sudah ada
            return chat["session"]
        chat["session"] = sid
        save_state(STATE)
    return sid


def reset_session(chat_id):
    with _state_lock:
        chat = STATE["chats"].setdefault(str(chat_id), {})
        old = chat.pop("session", None)
        save_state(STATE)
    if old:
        try:
            oc("DELETE", "/api/session/" + old)
        except RuntimeError:
            pass


def ask_model(sid, text, timeout):
    """Kirim prompt, tunggu selesai, kembalikan teks balasan."""
    oc("POST", "/api/session/%s/prompt" % sid, {"text": text}, timeout=120)
    oc("POST", "/api/experimental/session/%s/wait" % sid, None, timeout=timeout)
    msgs = oc(
        "GET",
        "/api/session/%s/message?order=desc&limit=100" % sid,
        timeout=60,
    )["data"]
    parts = []
    failed = False
    for m in msgs:
        t = m.get("type")
        if t == "assistant":
            for c in m.get("content", []):
                if c.get("type") == "text" and c.get("text"):
                    parts.append(c["text"])
        elif t == "idle":
            # jangan break: dengan urutan desc, idle selalu di atas.
            # cukup catat hasilnya; berhenti saat menemui pesan user
            failed = m.get("outcome") != "succeeded"
        elif t == "user":
            break
    parts.reverse()
    return "\n\n".join(parts).strip(), failed


# -------------------------------------------------------------- commands ----


def is_whitelisted(chat_id):
    allow = CONFIG.get("allowed_chat_ids") or []
    return chat_id in allow


def cmd_models(chat_id):
    model = current_model(chat_id)
    lines = ["Model gratis OpenCode (aktif: *%s*):" % model["id"], ""]
    for i, (mid, name) in enumerate(FREE_MODELS, 1):
        mark = " ✔" if mid == model["id"] else ""
        lines.append("%d. %s (%s)%s" % (i, name, mid, mark))
    lines.append("")
    lines.append("Ganti: /model <nomor atau id>")
    send_text(chat_id, "\n".join(lines))


def cmd_model(chat_id, arg):
    arg = (arg or "").strip()
    if not arg:
        return cmd_models(chat_id)
    chosen = None
    if arg.isdigit() and 1 <= int(arg) <= len(FREE_MODELS):
        chosen = FREE_MODELS[int(arg) - 1][0]
    else:
        for mid, _ in FREE_MODELS:
            if arg.lower() == mid:
                chosen = mid
                break
    if not chosen:
        send_text(chat_id, "Model tidak dikenal. Lihat /models.")
        return
    set_model(chat_id, chosen)
    send_text(chat_id, "Model diganti ke %s. Sesi baru dimulai, kirim pesan." % chosen)


def handle_message(msg):
    chat_id = msg["chat"]["id"]
    text = (msg.get("text") or msg.get("caption") or "").strip()
    if not text:
        return

    if not is_whitelisted(chat_id):
        print("[blocked] chat_id=%s text=%r" % (chat_id, text[:80]), file=sys.stderr)
        send_text(
            chat_id,
            "Chat tidak terdaftar. ID Anda: %s\nMinta pemilik server mendaftarkannya."
            % chat_id,
        )
        return

    cmd = text.split()[0].split("@")[0].lower()
    arg = text[len(text.split()[0]):].strip()

    if cmd in ("/start", "/help"):
        send_text(chat_id, HELP_TEXT)
    elif cmd == "/id":
        send_text(chat_id, "Chat ID: %s" % chat_id)
    elif cmd == "/new":
        reset_session(chat_id)
        send_text(chat_id, "Sesi baru dimulai. Konteks lama dilupakan.")
    elif cmd == "/models":
        cmd_models(chat_id)
    elif cmd == "/model":
        cmd_model(chat_id, arg)
    else:
        sid = ensure_session(chat_id)
        typing = Typing(chat_id)
        typing.start()
        try:
            reply, failed = ask_model(
                sid, text, CONFIG.get("prompt_timeout", 600)
            )
        except Exception as e:  # noqa: BLE001 - laporkan semua error ke chat
            reply, failed = "Terjadi error: %s" % e, True
        finally:
            typing.stop_event.set()
        if failed and not reply:
            reply = "Model gagal menyelesaikan permintaan. Coba lagi atau /new."
        send_text(chat_id, reply)


def main():
    print("[bot] started, model default:", CONFIG["model"]["id"])
    while True:
        try:
            poll = CONFIG.get("poll_timeout", 50)
            res = tg(
                "getUpdates",
                api_timeout=poll + 15,
                timeout=poll,
                offset=STATE.get("offset", 0),
            )
            if not res.get("ok"):
                time.sleep(3)
                continue
            for upd in res["result"]:
                STATE["offset"] = upd["update_id"] + 1
                with _state_lock:
                    save_state(STATE)
                msg = upd.get("message") or upd.get("channel_post")
                if not msg:
                    continue
                threading.Thread(
                    target=handle_message, args=(msg,), daemon=True
                ).start()
        except KeyboardInterrupt:
            print("[bot] stopped")
            return
        except Exception as e:  # noqa: BLE001
            print("[bot error] %s" % e, file=sys.stderr)
            traceback_print()
            time.sleep(5)


def traceback_print():
    import traceback

    traceback.print_exc(file=sys.stderr)


if __name__ == "__main__":
    main()
