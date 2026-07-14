#!/bin/sh
set -eux

cat > /etc/apk/repositories <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.23/main
https://dl-cdn.alpinelinux.org/alpine/v3.23/community
EOF

apk update
apk add --no-cache \
    alpine-base \
    bash \
    busybox-mdev-openrc \
    curl \
    dosfstools \
    e2fsprogs \
    fuse-overlayfs \
    iptables \
    libarchive \
    libgcc \
    linux-firmware-brcm \
    linux-rpi \
    mkinitfs \
    netavark \
    openssh \
    openssl \
    ostree \
    podman \
    raspberrypi-bootloader \
    skopeo \
    slirp4netns \
    sudo \
    util-linux \
    util-linux-misc \
    wireless-regdb \
    wpa_supplicant

adduser -D -s /bin/ash bupd
addgroup bupd wheel
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

echo node01 > /etc/hostname
echo uninitialized > /etc/machine-id

ssh-keygen -A
