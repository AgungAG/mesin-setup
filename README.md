# mesin-setup

Script buat **restore mesin ini dari nol** — dipakai kalau container ke-reset /
`/root` bersih total, biar kondisinya balik seperti semula.

Repo ini **publik** dan tidak berisi secret apa pun (semua token/password lewat
environment variable), jadi script-nya bisa diambil tanpa login sama sekali.

## Restore dari nol

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/AgungAG/mesin-setup/main/setup.sh
bash setup.sh
```

Selesai — sisanya jalan sendiri.

## Opsi (environment variable)

Semua opsional. Bisa juga dititipkan ke `/root/.machine-secrets` (format
`NAMA=nilai`, `chmod 600`) supaya tidak perlu diketik ulang tiap restore.

| Variabel | Fungsi |
|---|---|
| `TS_AUTHKEY` | Login Tailscale otomatis tanpa klik link. Ambil dari <https://login.tailscale.com/admin/settings/keys> |
| `ROOT_PASSWORD` | Password root (kalau kosong dibuat random lalu disimpan) |
| `GH_TOKEN` | Token GitHub → `gh login` otomatis + push backup |
| `SITE_REPO` | Repo tujuan clone/push web toko roti (default `AgungAG/toko-roti`) |
| `SITE_PORT` | Port web toko roti (default `8000`) |
| `USE_CLOUDFLARED` | `0` = matikan tunnel publik (default `1`) |
| `TAKE_TAILSCALE` | `0` = tunda ambil-alih tailscaled ke supervisor (buat hindari mutus sesi Tailscale SSH). Default `1` |
| `DEV_SESSION` | Nama tmux session yang disiapkan (default `oce`) |

## Yang disetup

1. Paket dasar: `git tmux gh jq curl ca-certificates`
2. Tailscale (install + login `--ssh`) + `tailscale serve` → `https://<mesin>.ts.net`
3. OpenCode (install + PATH)
4. OpenSSH + login root via password
5. Web toko roti: `python3 -m http.server` di `/root/toko-roti`
6. Tunnel publik cloudflared (URL disimpan di `/root/cloudflared-url.txt`)
7. GitHub: `gh login`, identitas git, auto-commit + push `toko-roti` dan script ini

## Catatan penting

- **Semua daemon (tailscaled, sshd, web, tunnel) dijaga supervisord**, bukan
  `nohup &` manual — jadi ikut bangun sendiri tiap container hidup.
  Cek: `supervisorctl status`.
- Desktop/VNC/nginx itu urusan image bawaan, tidak disentuh script ini.
- Secret disimpan di `/root/.machine-secrets` (`chmod 600`) — **jangan pernah
  di-commit ke git**.
- Repo web toko roti: [`AgungAG/toko-roti`](https://github.com/AgungAG/toko-roti) (privat).
- Ambil-alih tailscaled (sekali saja, biar ikut auto-start):
  `TAKE_TAILSCALE=1 bash setup.sh` — jalankan dari dalam tmux.
