# NixOS bootc Raspberry Pi 5

This is the target path for the Pi: bootc manages the host deployment, and the
payload it boots is NixOS.

The Raspberry Pi boot method is preserved. The Pi EEPROM firmware reads the FAT
`BOOT` partition, `config.txt`, and `cmdline.txt`. bootc owns the deployment
and BLS entries under `/boot`. `rpi-bootc-sync` adapts the selected bootc BLS
entry into Raspberry Pi firmware files under `/boot/firmware`.

## Flow

```text
NixOS flake
  -> NixOS aarch64 system closure + Pi 5 kernel/initramfs/firmware
  -> bootc-compatible OCI image
  -> bootc install to ext4 root partition
  -> rpi-bootc-sync generates FAT BOOT config.txt/cmdline.txt
  -> Raspberry Pi firmware boots the bootc-selected NixOS deployment
```

The image includes `bootc`, `rpi-bootc-sync`, SSH, and a reverse SSH tunnel
service for headless bring-up.

## Reverse SSH

The reverse SSH service is enabled by default in this experiment. It waits for
configuration and keeps retrying. The FAT boot partition can contain:

```sh
# bootsy-debug.env
BOOTSY_REVERSE_SSH_ENABLE=1
BOOTSY_REVERSE_SSH_HOST=192.168.1.10
BOOTSY_REVERSE_SSH_USER=bupd
BOOTSY_REVERSE_SSH_PORT=22
BOOTSY_REVERSE_SSH_REMOTE_BIND=127.0.0.1
BOOTSY_REVERSE_SSH_REMOTE_PORT=2222
```

and:

```text
bootsy-reverse-ssh.key
authorized_keys
```

From the host, after the Pi connects back:

```sh
ssh -p 2222 bupd@127.0.0.1
```

This gives an interactive shell over the reverse tunnel without needing a
display or inbound network access to the Pi.

## Build on GitHub ARM64 runners

The local workstation is x86_64, so the real build path is GitHub Actions on
`ubuntu-24.04-arm`.

Use the `Build NixOS bootc Raspberry Pi 5` workflow. For a debug SD image,
provide the workflow inputs and repository secrets:

- `BOOTSY_REVERSE_SSH_PRIVATE_KEY`: private key the Pi uses to SSH to the host.
- `BOOTSY_PI_AUTHORIZED_KEYS`: public key allowed to SSH into the Pi through
  the tunnel.

The workflow publishes the bootc image to GHCR and uploads a compressed SD card
image artifact.

## Local commands

These require an aarch64 Linux builder with Nix and Podman:

```sh
scripts/build-rootfs-tar.sh
podman build --platform linux/arm64 -t ghcr.io/bupd/homelab/nixos-bootc-rpi5:latest .
sudo IMAGE=ghcr.io/bupd/homelab/nixos-bootc-rpi5 TAG=latest scripts/build-bootc-sdcard-image.sh
```

QEMU is not a complete Pi 5 firmware emulator. It can smoke-test generic ARM64
Linux pieces, but real validation of `config.txt`, `cmdline.txt`, DTBs, and the
Pi 5 EEPROM path still requires Raspberry Pi 5 hardware.
