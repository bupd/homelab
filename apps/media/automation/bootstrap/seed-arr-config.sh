#!/bin/sh
set -eu

config=/config/config.xml
if [ -s "$config" ]; then
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
