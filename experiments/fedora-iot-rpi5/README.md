# Fedora IoT Raspberry Pi 5 bootstrap

This is the recovery path for getting a known-good bootc-capable Raspberry Pi
system online before iterating on custom images.

The approach intentionally starts from the official Fedora IoT `aarch64`
`raw.xz` image instead of hand-building the Raspberry Pi boot partition:

- Fedora publishes an IoT ARM raw image.
- Fedora's Raspberry Pi docs and examples use `arm-image-installer` to flash
  the raw image, inject SSH keys, remove the root password, resize the root
  filesystem, and apply the Raspberry Pi target handling.
- Fedora IoT is already image-based and bootc-capable, so once the Pi is online
  we can use `bootc switch` to move to a custom image.

The script here runs Fedora's installer from a Fedora container. It does not
build ARM images locally.

```sh
WIFI_SSID='BUPD' WIFI_PSK='...' \
  experiments/fedora-iot-rpi5/scripts/flash-fedora-iot.sh \
  --device /dev/sdX \
  --yes
```

After first boot, find the DHCP address and SSH in:

```sh
ssh bupd@<ip>
```

Then verify the bootc baseline:

```sh
bootc status
rpm-ostree status
```

## References

- Fedora IoT download page: https://fedoraproject.org/iot/download/
- Fedora IoT Raspberry Pi install flow: https://www.redhat.com/en/blog/fedora-iot-raspberry-pi
- Fedora IoT bootc Raspberry Pi docs: https://docs.fedoraproject.org/en-US/iot/fedora-iot-bootc-raspberry-pi-example/
- Fedora bootc Raspberry Pi experiment: https://github.com/ondrejbudai/fedora-bootc-raspi
- Raspberry Pi firmware/bootloader context for bootc: https://github.com/coreos/bootupd/issues/651
