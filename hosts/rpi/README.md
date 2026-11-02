# Raspberry Pis

Two Raspberry Pi 5 (2 GB) boards on the bootc image
`ghcr.io/oci-native/archlinux-bootc-rpi:bootstrap`. Every service is a Podman quadlet.
This folder is the only source of truth: change a file here, then deploy it.

| Host | LAN | Tailnet | Runs |
| --- | --- | --- | --- |
| `rpia` | 192.168.0.3 (wifi) | 100.121.232.98 | Sure, its Postgres and Redis, backups |
| `rpib` | 192.168.0.4 (ethernet) | 100.112.19.92 | Gatus status page |

Both LAN addresses are DHCP reservations on the router. `rpib` has a faulty wifi
radio and once corrupted XFS on its SD card, so it only runs things that can be
rebuilt from this repository.

## Deploy

From the repository root on the workstation:

```bash
hosts/rpi/deploy.sh rpia          # one host
hosts/rpi/deploy.sh all           # both
hosts/rpi/deploy.sh rpib --shell  # also zsh and nvim for the alarm user
```

`deploy.sh` copies `common/` and the host folder into a temporary directory,
decrypts the host's secrets with `sops`, streams it to the Pi over ssh, and runs
`reconcile.sh` there as root. `reconcile.sh` installs only the files that differ,
reloads systemd, and restarts the units those files affect. Running it again with
no changes does nothing.

It needs `sops` with the age key in `~/.config/sops/age/keys.txt`, and ssh access as
`alarm` (key auth, passwordless sudo).

## Layout

| Path | What it is |
| --- | --- |
| `hosts` | Host names and addresses that `deploy.sh` reads |
| `common/root/` | Files for both Pis, laid out as their paths on the host |
| `<host>/root/` | Files for one Pi, same layout |
| `<host>/secrets/*.sops.env` | Encrypted env files, see `secrets.map` for where each goes |
| `<host>/retired` | Paths to stop and remove; `.volume` entries also delete the volume |
| `common/shell/` | zsh config and the brew setup run by `--shell` |

Files ending in `.env` are installed as `0600` and their directory as `0700`. Files
ending in `.sh` are installed as `0755`.

## Services

Tailscale runs `tailscaled` directly in a container on both Pis. The first login is
manual: `sudo podman exec tailscale tailscale up`, then open the link it prints.
`reconcile.sh` keeps the tailnet name equal to the OS hostname.

Sure (`rpia`) follows upstream `compose.example.yml`: web, sidekiq worker,
`postgres:16` and `redis:7-alpine` on the `sure` network. Telemetry is turned off in
`sure.sops.env`, including `POSTHOG_FEEDBACK_ENABLED=false`, which is otherwise on
by default and sends feedback events to PostHog.

Backups (`rpia`):

- `sure-backup` runs upstream `bin/sure-backup` daily at 20:30 UTC into
  `/var/lib/sure-backups` and keeps 7 days.
- `sure-backup-offsite.timer` runs at 21:00 UTC. It encrypts each new bundle with
  the SOPS age recipient and copies it to R2 (`R2_DEST` in `r2.sops.env`). R2 keeps
  30 days.
- The Pi only has the public key. To restore on the workstation:

  ```bash
  age -d -i ~/.config/sops/age/keys.txt <stamp>.tar.age | tar -x
  sha256sum -c <stamp>/SHA256SUMS
  ```

Gatus (`rpib`) reads `rpib/root/etc/gatus/config.yaml`. Checks run from rpib's host
network, so they reach other machines over Tailscale. Alerts go to ntfy. The topic
lives in `gatus.sops.env` because anyone who knows an ntfy.sh topic can read it.
The status page is at http://100.112.19.92:8080.
