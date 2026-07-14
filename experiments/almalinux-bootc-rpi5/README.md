# AlmaLinux Raspberry Pi 5 bootc bootstrap

This is the preferred first working bootc baseline for the Raspberry Pi 5.

Why this path:

- AlmaLinux publishes prebuilt Raspberry Pi bootc raw images.
- Their README says the images have been tested on Raspberry Pi 5 boards,
  including 2GB models.
- Their notes call out the same problem we hit: generic `bootc-image-builder`
  output is not enough by itself because Raspberry Pi firmware handling matters.
- Once this boots, we have a real bootc-managed host that can switch to our
  custom registry image later.

Default image:

```text
https://github.com/AlmaLinux/bootc-images-rpi/releases/download/2026-03-15-1/image-almalinux-bootc-rpi-gpt-10-20260316-arm64.raw.xz
```

Flash:

```sh
WIFI_SSID='BUPD' WIFI_PSK='...' \
  experiments/almalinux-bootc-rpi5/scripts/flash-almalinux-bootc-rpi.sh \
  --device /dev/sdX \
  --yes
```

After boot:

```sh
nmap -sn 192.168.0.0/24
nmap -p 22 --open 192.168.0.0/24
ssh bupd@<ip>
bootc status
```

References:

- https://github.com/AlmaLinux/bootc-images-rpi
- https://github.com/AlmaLinux/bootc-images-rpi/releases
- https://bootc.dev/bootc/man/bootc-install-to-disk.8.html
- https://osbuild.org/docs/bootc/
