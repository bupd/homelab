# Immich

This folder owns the whole Immich deployment:

- `database/`: namespace, dedicated CloudNativePG database, and backup job;
- `app/`: official pinned Immich Helm chart, full `values.yaml`, and storage;
- PostgreSQL, Valkey, and machine-learning cache use K3s `local-path`; and
- Immich-managed photos and database dumps use the existing HDD directory below; and
- the complete `BUPD_Personal` tree is mounted read-only as an external library.

```text
/home/bupd/hdd/data/BUPD_Personal/immich
```

The Immich server sees the complete personal media tree at:

```text
Host:      /home/bupd/hdd/data/BUPD_Personal
Container: /mnt/photos (read-only)
```

Immich is hard-pinned to `media-worker`. The live PostgreSQL data directory is
on the worker's Linux filesystem, not the NTFS media disk.

## First deployment

Flux deploys the pieces in this order:

```text
CloudNativePG operator -> Immich database -> Immich Helm release
```

Check them:

```bash
just flux-status
kubectl -n immich get pods,pvc
kubectl -n immich get clusters.postgresql.cnpg.io,databases.postgresql.cnpg.io
kubectl -n immich rollout status deployment/immich-server --timeout=15m
```

The Tailscale Operator exposes Immich privately with a valid HTTPS certificate
at <https://immich.tail6c5ea9.ts.net>. For recovery or troubleshooting, open a
temporary tunnel:

```bash
kubectl -n immich port-forward service/immich-server 2283:2283
```

Then open <http://127.0.0.1:2283>.

## Backup and restore

### What must be backed up

An Immich recovery needs both parts:

1. The PostgreSQL dump. It contains users, albums, metadata, and file paths.
2. The complete asset directory. It contains the actual photos and videos.

The database does not rebuild itself by scanning the asset directory. Having
only the photos is not a complete Immich backup.

Current locations:

```text
Database data:  K3s local-path PVC on media-worker's Linux filesystem
Database dumps: /home/bupd/hdd/data/BUPD_Personal/immich/backups
Assets:         /home/bupd/hdd/data/BUPD_Personal/immich
```

The HDD copy protects against a broken database, but it does not protect
against loss of the HDD. Copy the whole Immich directory to another physical
machine or disk for disaster recovery.

### How automatic database backups work

`database/backup.yaml` declares `CronJob/immich-database-backup`.

- It runs every day at `02:00` in `Asia/Kolkata`.
- It runs `pg_dump` against the dedicated `immich` database.
- It writes a compressed `.sql.gz` file into `backups/`.
- It keeps today's dump, yesterday's dump, and the newest Sunday checkpoint.
- It removes older managed dumps only after a new dump succeeds.
- It never selects photos, videos, or the `.immich` marker for deletion.

The CronJob is initially suspended. This prevents the old known-good backup
from being pruned before the first restore is complete.

Check its state:

```bash
kubectl -n immich get cronjob immich-database-backup
kubectl -n immich get cronjob immich-database-backup \
  -o jsonpath='{.spec.suspend}{"\n"}'
```

Expected before the first restore: `true`.

### Add all BUPD Personal photos and videos

Finish fresh onboarding and create the administrator account first. Then, in
the Immich web UI:

1. Open **Administration -> External Libraries**.
2. Click **Create Library** and select its owner.
3. Name it `BUPD Personal`.
4. Add `/mnt/photos` as the import path.
5. Add `**/immich/**` as an exclusion pattern. This is mandatory: without it,
   Immich will recursively index its own uploads, thumbnails, and encoded videos.
6. Click **Scan New Library Files**.
7. Watch **Administration -> Jobs** for library, metadata, thumbnail, and
   machine-learning progress.

The scan is recursive. Immich imports supported photos and videos and ignores
unsupported files such as documents and audio. The mount is read-only, so
deleting an external asset in Immich cannot delete the source file.

### Verify the restore

Check Kubernetes first:

```bash
kubectl -n immich get pods
kubectl -n immich logs deployment/immich-server --tail=200
kubectl -n immich get clusters.postgresql.cnpg.io immich-database
```

Then check Immich in the browser:

1. Log in with the restored administrator account.
2. Open several old photos and videos.
3. Check albums and user accounts.
4. Upload one disposable photo.
5. Restart the server and check the same photo again:

```bash
kubectl -n immich rollout restart deployment/immich-server
kubectl -n immich rollout status deployment/immich-server --timeout=15m
```

Delete the disposable photo through Immich, not from the filesystem.

### Enable scheduled backups after verification

Edit `database/backup.yaml`:

```yaml
spec:
  suspend: false
```

Then publish the declarative change:

```bash
just validate
git add apps/media/immich/database/backup.yaml
git commit -m 'enable Immich database backups'
git push origin main
```

Do not enable it with a permanent `kubectl patch`; Flux would treat that as
drift. After GitHub Actions publishes `latest`, Flux applies the change within
about two minutes.

Check it:

```bash
kubectl -n immich get cronjob immich-database-backup
```

### Run a database backup now

Do this only after the initial restore has been verified and scheduled backups
have been enabled:

```bash
backup_job="immich-database-backup-manual-$(date +%s)"
kubectl -n immich create job \
  --from=cronjob/immich-database-backup "$backup_job"
kubectl -n immich wait \
  --for=condition=complete "job/$backup_job" --timeout=1h
kubectl -n immich logs "job/$backup_job"
sudo ls -lh /home/bupd/hdd/data/BUPD_Personal/immich/backups/*.sql.gz
```

If the Job fails, inspect it before rerunning:

```bash
kubectl -n immich describe "job/$backup_job"
kubectl -n immich logs "job/$backup_job"
```

### Restore a backup after Immich is already configured

1. Confirm the matching asset directory is mounted and intact.
2. Open Immich as an administrator.
3. Go to **Administration -> Maintenance**.
4. Expand **Restore database backup**.
5. Select the required `.sql.gz` dump, or upload it from the `backups/`
   directory.
6. Confirm the destructive restore.
7. Wait for migrations and the health check.
8. Repeat the verification steps above.

Restoring replaces the current database. Immich creates a restore point before
starting and rolls back if its restore health check fails, but an independent
off-host copy is still required.

### Make an off-host backup

For a live backup, create the database dump first and copy the filesystem
second. Replace the destination below with a mounted disk or remote backup
target:

```bash
backup_job="immich-database-backup-manual-$(date +%s)"
kubectl -n immich create job \
  --from=cronjob/immich-database-backup "$backup_job"
kubectl -n immich wait \
  --for=condition=complete "job/$backup_job" --timeout=1h
sudo rsync -aH \
  /home/bupd/hdd/data/BUPD_Personal/immich/ \
  '<off-host-backup>/immich/'
```

For the strongest consistency, stop writes to Immich while copying. Never
modify asset files inside `library`, `upload`, or `profile` by hand.

Official reference: [Immich Backup and Restore](https://docs.immich.app/administration/backup-and-restore/).
