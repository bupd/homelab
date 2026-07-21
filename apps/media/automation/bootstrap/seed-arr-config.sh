#!/bin/sh
set -eu

config=/config/config.xml
if [ -s "$config" ]; then
  chown "${CONFIG_UID:-1000}:${CONFIG_GID:-1000}" /config "$config"
  chmod 600 "$config"
  exit 0
fi

umask 077
cat >"$config" <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>${APP_PORT}</Port>
  <SslPort>0</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>${API_KEY}</ApiKey>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>Enabled</AuthenticationRequired>
  <Username>admin</Username>
  <Password>${ADMIN_PASSWORD}</Password>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <UpdateMechanism>Docker</UpdateMechanism>
</Config>
EOF
chown "${CONFIG_UID:-1000}:${CONFIG_GID:-1000}" /config "$config"
chmod 600 "$config"
