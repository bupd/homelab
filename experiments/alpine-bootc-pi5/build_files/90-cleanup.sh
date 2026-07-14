#!/bin/sh
set -eux

rm -rf /var/cache/apk/* /tmp/* /build_files
find /var/log -type f -delete || true
