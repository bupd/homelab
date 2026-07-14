#!/bin/sh
set -eux

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit

rc-update add bootmisc boot
rc-update add hostname boot
rc-update add modules boot
rc-update add networking boot
rc-update add sysctl boot
rc-update add wpa_supplicant boot

rc-update add sshd default

rc-update add killprocs shutdown
rc-update add mount-ro shutdown

mkdir -p /etc/containers
cat > /etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
EOF
