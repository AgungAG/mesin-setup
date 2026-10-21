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

Selesai — sisanya jalan sendiri.

Dua command manual Google Chrome (keyring + `sources.list`) yang dulu harus
dijalankan dulu biar `sudo apt update` jalan **sudah masuk di dalam script**
sebagai langkah paling awal — jadi tidak perlu diketik lagi tiap reset.

Chrome sendiri (`google-chrome-stable`) juga ikut terinstall otomatis, dan
**password root tidak dibuat lagi** — akses masuk lewat Tailscale SSH
(`tailscale ssh root@<ip>` dari Termius/HP), yang diautentikasi oleh identitas
Tailscale. sshd tetap jalan sebagai cadangan, tapi cuma menerima kunci publik.

## Opsi (environment variable)

Semua opsional. Bisa juga dititipkan ke `/root/.machine-secrets` (format
`NAMA=nilai`, `chmod 600`) supaya tidak perlu diketik ulang tiap restore.

| Variabel | Fungsi |
|---|---|
| `TS_AUTHKEY` | Login Tailscale otomatis tanpa klik link. Ambil dari <https://login.tailscale.com/admin/settings/keys> |
| `GH_TOKEN` | Token GitHub → `gh login` otomatis + push backup |
| `INSTALL_CHROME` | `0` = lewati install `google-chrome-stable` (default `1`; repo Chrome tetap dipasang) |
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
3. Tailscale (install + login `--ssh`) + `tailscale serve` → `https://<mesin>.ts.net`
4. OpenCode (install + PATH)
5. OpenSSH **tanpa password** (pubkey saja) — akses harian lewat Tailscale SSH
6. Web toko roti: `python3 -m http.server` di `/root/toko-roti`
7. Tunnel publik cloudflared (URL disimpan di `/root/cloudflared-url.txt`)
8. GitHub: `gh login`, identitas git, auto-commit + push `toko-roti` dan script ini

## Catatan penting

- **Masuk mesin: `tailscale ssh root@<tailscale-ip>`** (dari Termius di HP).
  Tidak ada password root — login dibuka oleh identitas Tailscale di tailscaled,
  bukan oleh sshd. Kalau butuh sshd, cuma kunci publik di
  `/root/.ssh/authorized_keys` yang diterima.
- **Semua daemon (tailscaled, sshd, web, tunnel) dijaga supervisord**, bukan
  `nohup &` manual — jadi ikut bangun sendiri tiap container hidup.
  Cek: `supervisorctl status`.
- Desktop/VNC/nginx itu urusan image bawaan, tidak disentuh script ini.
- Secret disimpan di `/root/.machine-secrets` (`chmod 600`) — **jangan pernah
  di-commit ke git**.
- Repo web toko roti: [`AgungAG/toko-roti`](https://github.com/AgungAG/toko-roti) (privat).
- Ambil-alih tailscaled (sekali saja, biar ikut auto-start):
  `TAKE_TAILSCALE=1 bash setup.sh` — jalankan dari dalam tmux.
