#!/bin/sh
set -eux

mkdir -p /usr/lib/rpi-boot
cp -a /boot/. /usr/lib/rpi-boot/

kernel="$(find /lib/modules -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -V | tail -n 1)"
mkinitfs -o /usr/lib/rpi-boot/initramfs-rpi "$kernel"

mkdir -p /usr/lib
cp -a /lib/modules /usr/lib/modules
install -Dm0644 /usr/lib/rpi-boot/vmlinuz-rpi "/usr/lib/modules/$kernel/vmlinuz"
install -Dm0644 /usr/lib/rpi-boot/initramfs-rpi "/usr/lib/modules/$kernel/initramfs.img"

rm -rf /boot /home /root /srv /opt /mnt /var/cache/apk/*

mkdir -p /sysroot /boot /usr/lib/ostree /var /var/home/bupd /var/roothome /var/srv /var/opt /var/mnt
chown 1000:1000 /var/home/bupd

ln -sT sysroot/ostree /ostree
ln -sT var/home /home
ln -sT var/roothome /root
ln -sT var/srv /srv
ln -sT var/opt /opt
ln -sT var/mnt /mnt

cat > /usr/lib/ostree/prepare-root.conf <<'EOF'
[composefs]
enabled = yes

[sysroot]
readonly = true
EOF

mkdir -p /usr/lib/tmpfiles.d
cat > /usr/lib/tmpfiles.d/alpine-bootc-base.conf <<'EOF'
d /var/home 0755 root root -
d /var/roothome 0700 root root -
d /var/srv 0755 root root -
d /var/opt 0755 root root -
d /var/mnt 0755 root root -
d /var/lib/containers 0711 root root -
d /run/media 0755 root root -
EOF

cat > /etc/fstab <<'EOF'
tmpfs /tmp tmpfs nosuid,nodev 0 0
EOF

cat > /etc/motd <<'EOF'
Experimental Alpine bootc Raspberry Pi 5 node.
EOF
