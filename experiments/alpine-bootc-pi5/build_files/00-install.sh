#!/bin/sh
set -eux

cat > /etc/apk/repositories <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.23/main
https://dl-cdn.alpinelinux.org/alpine/v3.23/community
@edge-testing https://dl-cdn.alpinelinux.org/alpine/edge/testing
EOF

apk update
apk add --no-cache \
    alpine-base \
    bash \
    bluez \
    bluez-openrc \
    buildah \
    busybox-mdev-openrc \
    chrony \
    cloudflared@edge-testing \
    cni-plugins \
    curl \
    dosfstools \
    dracut \
    e2fsprogs \
    fuse-overlayfs \
    ip6tables \
    iptables \
    iwd \
    k3s \
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
    podman-compose \
    raspberrypi-bootloader \
    raspberrypi-utils \
    restic \
    skopeo \
    slirp4netns \
    sudo \
    tailscale \
    tmux \
    ufw \
    util-linux \
    util-linux-misc \
    wget \
    wireless-regdb \
    wireguard-tools \
    wpa_supplicant

adduser -D -s /bin/ash bupd
addgroup bupd wheel
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

echo node01 > /etc/hostname
echo uninitialized > /etc/machine-id

ssh-keygen -A
