# NixOS bootc Raspberry Pi 5

This is the target path for the Pi: bootc manages the host deployment, and the
payload it boots is NixOS.

The Raspberry Pi boot method is preserved. The Pi EEPROM firmware reads the FAT
`BOOT` partition, `config.txt`, and `cmdline.txt`. bootc owns the deployment
and BLS entries under `/boot`. `rpi-bootc-sync` adapts the selected bootc BLS
entry into Raspberry Pi firmware files under `/boot/firmware`.

This follows the Pi 5 EEPROM boot flow: the first-stage ROM loads the EEPROM
second-stage bootloader, the EEPROM bootloader scans boot modes such as SD,
network, USB, and NVMe, and on Pi 5 the firmware loads the Linux kernel directly
instead of loading `start.elf` from the boot partition. The generated boot
partition therefore keeps `bootc-vmlinuz`, `bootc-initramfs.img`, DTBs,
overlays, `config.txt`, and `cmdline.txt` at firmware-visible paths.

## Flow

```text
NixOS flake
  -> NixOS aarch64 system closure + cached aarch64 kernel/initramfs + Pi firmware
  -> bootc-compatible OCI image
  -> bootc install to ext4 root partition
  -> rpi-bootc-sync generates FAT BOOT kernel/initramfs/config.txt/cmdline.txt
  -> Raspberry Pi firmware boots the bootc-selected NixOS deployment
```

The image includes `bootc`, `rpi-bootc-sync`, SSH, and a reverse SSH tunnel
service for headless bring-up.

## Headless Boot Partition

The SD image uses a Raspberry Pi-style FAT `BOOT` partition for headless
customisation. The workflow and image builder always create an empty `ssh`
marker because SSH is required for this headless Pi.

The first boot service also accepts these files on the FAT partition:

- `ssh` or `ssh.txt`: marker that SSH should be available. OpenSSH is already
  enabled in this image, so this is mainly a visible compatibility signal.
- `userconf.txt` or `userconf`: one line in the Raspberry Pi format
  `username:encrypted-password`. Generate the hash with `openssl passwd -6`.
- `authorized_keys` or `authorized_keys.txt`: public keys to install for the
  user from `userconf`.
- `bootsy-debug.env`: reverse SSH and beacon configuration.
- `bootsy-reverse-ssh.key`: private key used by the Pi to SSH back to the host.

This mirrors the useful part of Raspberry Pi OS headless setup while keeping
the OS payload as NixOS managed by bootc.

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

The flake intentionally avoids unlocked `github:` inputs for the main NixOS
channel because the GitHub commits API has been unreliable during these builds.
`nixpkgs` comes from the NixOS channel tarball, and the Raspberry Pi module is
fetched through Git. The lock file pins the Raspberry Pi firmware/kernel source
inputs. The image uses the Raspberry Pi kernel selected by `raspberry-pi-nix`
instead of a generic NixOS aarch64 kernel because Pi 5 Ethernet, SD, RP1, DTB,
and firmware behaviour must line up for headless reverse SSH bring-up.

Use the `Build NixOS bootc Raspberry Pi 5` workflow. For a debug SD image,
provide the workflow inputs and repository secrets:

- `BOOTSY_REVERSE_SSH_PRIVATE_KEY`: private key the Pi uses to SSH to the host.
- `BOOTSY_PI_AUTHORIZED_KEYS`: public key allowed to SSH into the Pi through
  the tunnel.
- `BOOTSY_PI_USERCONF`: optional `username:encrypted-password` line written to
  `userconf.txt`.

The workflow publishes the bootc image to GHCR and uploads a compressed SD card
image artifact.

## Local commands

The local workstation can use QEMU user-mode aarch64 through Podman. This is
slower than GitHub's native ARM64 runner, but it catches rootfs layout and image
assembly problems before writing an SD card.

```sh
scripts/local-build-rootfs-podman.sh
scripts/test-rootfs-layout.sh build/out/nixos-bootc-rpi5-rootfs.tar
sudo podman build --platform linux/arm64 \
  --build-arg ROOTFS_TAR=build/out/nixos-bootc-rpi5-rootfs.tar \
  -t localhost/nixos-bootc-rpi5:local .
sudo IMAGE=localhost/nixos-bootc-rpi5 TAG=local \
  OUT=build/out/nixos-bootc-rpi5.img SIZE=8G \
  scripts/build-bootc-sdcard-image.sh
```

QEMU is not a complete Pi 5 firmware emulator. It can smoke-test generic ARM64
Linux pieces, but real validation of `config.txt`, `cmdline.txt`, DTBs, and the
Pi 5 EEPROM path still requires Raspberry Pi 5 hardware.

## Flashing

Inspect the target before writing:

```sh
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS /dev/sdX
```

Then write the validated image:

```sh
sudo scripts/flash-sdcard.sh \
  --image build/out/nixos-bootc-rpi5.img \
  --device /dev/sdX \
  --yes-i-know-this-will-erase
```

For the current headless setup, the host needs an SSH server reachable from the
Pi over Ethernet. The SD image writes `bootsy-debug.env`, `authorized_keys`, and
`bootsy-reverse-ssh.key` to the FAT `BOOT` partition when the matching
environment variables are supplied to `build-bootc-sdcard-image.sh`.
