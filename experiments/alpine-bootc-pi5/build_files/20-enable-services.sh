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
rc-update add syslog boot
rc-update add wpa_supplicant boot

rc-update add chronyd default
rc-update add sshd default
rc-update add tailscale default
rc-update add bluetooth default
rc-update add ufw default
rc-update add k3s default
rc-update add cloudflared default || true

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

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'EOF'
write-kubeconfig-mode: "0644"
disable:
  - traefik
  - servicelb
node-label:
  - "homelab.bupd.xyz/role=pi"
EOF

cat > /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors: {}
configs: {}
EOF

cat > /etc/conf.d/tailscale <<'EOF'
no_logs_no_support=yes
EOF
