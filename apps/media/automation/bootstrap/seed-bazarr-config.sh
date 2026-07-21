#!/bin/sh
set -eu

config=/config/config/config.yaml
if [ -s "$config" ]; then
  exit 0
fi

mkdir -p /config/config
password_hash=$(printf %s "$ADMIN_PASSWORD" | md5sum | cut -d' ' -f1)
umask 077
cat >"$config" <<EOF
auth:
  type: form
  apikey: "${BAZARR_API_KEY}"
  username: admin
  password: "${password_hash}"
general:
  port: 6767
  base_url: ""
  use_sonarr: true
  use_radarr: true
sonarr:
  ip: sonarr
  port: 8989
  base_url: /
  ssl: false
  apikey: "${SONARR_API_KEY}"
radarr:
  ip: radarr
  port: 7878
  base_url: /
  ssl: false
  apikey: "${RADARR_API_KEY}"
EOF
