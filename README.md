# mesin-setup

Script buat **restore mesin ini dari nol** — dipakai kalau container ke-reset /
`/root` bersih total, biar kondisinya balik seperti semula.

Repo ini **publik** dan tidak berisi secret apa pun (semua token lewat
environment variable — script ini **tidak memakai password root sama sekali**),
jadi script-nya bisa diambil tanpa login sama sekali.

## Restore dari nol

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/setup.sh
bash setup.sh
```

Selesai — sisanya jalan sendiri. (Alternatif: `menu.sh` — menu opsi
*install keseluruhan / generate SSH upterm / keluar*, lihat
[Menu interaktif](#menu-iteraktif).)

Dua command manual Google Chrome (keyring + `sources.list`) yang dulu harus
dijalankan dulu biar `sudo apt update` jalan **sudah masuk di dalam script**
sebagai langkah paling awal — jadi tidak perlu diketik lagi tiap reset.

Chrome sendiri (`google-chrome-stable`) juga ikut terinstall otomatis, dan
**password root tidak dipakai sama sekali** — akses masuk lewat Tailscale SSH
(`tailscale ssh root@<ip>` dari Termius/HP) yang diautentikasi oleh identitas
Tailscale. Karena itu `openssh-server`/**sshd tidak dipasang sama sekali**:
protokol SSH-nya ditangani tailscaled, jadi sshd hanya membuka port 22 yang
tidak dipakai siapa pun (`openssh-client` tetap ada untuk git ssh).

## Opsi (environment variable)

Semua opsional. Bisa juga dititipkan ke `/root/.machine-secrets` (format
`NAMA=nilai`, `chmod 600`) supaya tidak perlu diketik ulang tiap restore.

| Variabel | Fungsi |
|---|---|
| `TS_AUTHKEY` | Login Tailscale otomatis tanpa klik link. Ambil dari <https://login.tailscale.com/admin/settings/keys> |
| `GH_TOKEN` | Token GitHub → `gh login` otomatis + push backup |
| `INSTALL_CHROME` | `0` = lewati install `google-chrome-stable` (default `1`; repo Chrome tetap dipasang) |
| `INSTALL_BRAVE` | `0` = lewati install `brave-browser` (default `1`; wrapper `brave` dengan `--no-sandbox` tetap dibuat kalau binary sudah ada) |
| `SITE_REPO` | Repo tujuan clone/push web toko roti (default `AgungAG/toko-roti`) |
| `SITE_PORT` | Port web toko roti (default `8000`) |
| `USE_CLOUDFLARED` | `0` = matikan tunnel publik (default `1`) |
| `TAKE_TAILSCALE` | `0` = tunda ambil-alih tailscaled ke supervisor (buat hindari mutus sesi Tailscale SSH). Default `1` |
| `DEV_SESSION` | Nama tmux session yang disiapkan (default `oce`) |

## Yang disetup

0. Repo Google Chrome: keyring + `/etc/apt/sources.list.d/google-chrome.list`
   — jalan **paling awal**, sebelum `apt update` pertama, biar reset pertama
   tidak berhenti dengan error `NO_PUBKEY`
1. Paket dasar: `git tmux gh jq curl ca-certificates`
2. Google Chrome: `google-chrome-stable` dari repo resmi Google (`INSTALL_CHROME=0` untuk lewati)
2b. Brave: `brave-browser` dari repo resmi Brave + wrapper `brave` yang selalu
    menambah `--no-sandbox` (container jalan sebagai root → sandbox Chromium
    menolak start). Buka Brave dengan perintah `brave` (`INSTALL_BRAVE=0` untuk lewati)
2c. Upterm: `upterm` dari rilis resmi GitHub → `upterm host --accept -- bash`
    bikin sesi SSH temporer tanpa perlu sshd/key sama sekali (dipakai `menu.sh` opsi 2)
3. Tailscale (install + login `--ssh`) + `tailscale serve` → `https://<mesin>.ts.net`
4. OpenCode (install + PATH)
5. SSH: **tidak dipasang** — akses lewat Tailscale SSH (ditangani tailscaled);
   kalau `openssh-server` kepasang (misal dari image) script ini membersihkannya
6. Web toko roti: `python3 -m http.server` di `/root/toko-roti`
7. Tunnel publik cloudflared (URL disimpan di `/root/cloudflared-url.txt`)
8. GitHub: `gh login`, identitas git, auto-commit + push `toko-roti` dan script ini

## Menu interaktif

Selain `setup.sh`, repo ini berisi `menu.sh` — menu simpel dengan tiga opsi.
Sudah dipasang otomatis sebagai `/root/menu.sh` (symlink) tiap `setup.sh` jalan:

```bash
bash /root/menu.sh
```

| Opsi | Isi |
|---|---|
| 1 | **Install keseluruhan** → jalankan `setup.sh` (pulihkan mesin dari nol) |
| 2 | **Generate SSH** → `upterm host --accept -- bash` — cetak command SSH temporer, bagikan command-nya ke siapa pun yang mau ikut shell yang sama (sesi mati sendiri kalau host-nya keluar) |
| 3 | **Keluar** |

Ambil `menu.sh` saja tanpa ikut `setup.sh`:

```bash
curl -fsSL -o menu.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/menu.sh
bash menu.sh
```

## Catatan penting

- **Masuk mesin: `tailscale ssh root@<tailscale-ip>`** (dari Termius di HP).
  Tidak ada password root, dan tidak ada sshd — protokol SSH ditangani
  tailscaled dengan identitas Tailscale. Kalau suatu saat butuh sshd beneran:
  `apt-get install -y openssh-server` (jalankan `bash setup.sh` lagi untuk
  membuangnya lagi).
- **Semua daemon (tailscaled, web, tunnel) dijaga supervisord**, bukan
  `nohup &` manual — jadi ikut bangun sendiri tiap container hidup.
  Cek: `supervisorctl status`.
- Desktop/VNC/nginx itu urusan image bawaan, tidak disentuh script ini.
- Secret disimpan di `/root/.machine-secrets` (`chmod 600`) — **jangan pernah
  di-commit ke git**.
- Repo web toko roti: [`AgungAG/toko-roti`](https://github.com/AgungAG/toko-roti) (privat).
- Ambil-alih tailscaled (sekali saja, biar ikut auto-start):
  `TAKE_TAILSCALE=1 bash setup.sh` — jalankan dari dalam tmux.
