#!/bin/sh
# Runs inside docker.io/rclone/rclone (alpine). Encrypt new bundles, copy, prune.
set -u
case "${RCLONE_CONFIG_R2_ACCESS_KEY_ID}${RCLONE_CONFIG_R2_ENDPOINT}" in
  *FILL_ME*) echo "r2.env not filled in"; exit 1 ;;
esac
command -v age >/dev/null || apk add --no-cache --quiet age || { echo "cannot install age"; exit 1; }

encrypt_new() {
  for d in /backups/*/*/; do
    [ -f "${d}manifest.json" ] || continue          # skip partial/.tmp bundles
    rel=${d#/backups/}; rel=${rel%/}
    out="/enc/${rel}.tar.age"
    [ -s "$out" ] && continue
    mkdir -p "$(dirname "$out")"
    if tar -C "/backups/$(dirname "$rel")" -cf - "$(basename "$rel")" \
        | age -r "$AGE_RECIPIENT" -o "${out}.part"; then
      mv "${out}.part" "$out"; echo "encrypted $rel"
    else
      rm -f "${out}.part"; echo "encrypt failed: $rel"; return 1
    fi
  done
}

{
  # Local plaintext bundles are pruned by sure-backup; mirror that for ciphertext.
  find /enc -name '*.tar.age' -mtime +"${BACKUP_KEEP_DAYS}" -delete 2>/dev/null
  if encrypt_new \
    && rclone copy /enc "$R2_DEST" --include "*.tar.age" \
    && rclone delete "$R2_DEST" --min-age "${BACKUP_KEEP_DAYS}d" --include "/*/*-scheduled.tar.age"; then
    echo "offsite ok $(date -u +%FT%TZ): $(rclone lsf -R --files-only "$R2_DEST" | wc -l) files in R2"
  else
    echo "offsite failed $(date -u +%FT%TZ)"; exit 1
  fi
}
