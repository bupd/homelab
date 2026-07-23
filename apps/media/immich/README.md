# Immich

This folder owns the whole Immich deployment:

- `database/`: namespace, dedicated CloudNativePG database, and backup job;
- `app/`: official pinned Immich Helm chart, full `values.yaml`, and storage;
- PostgreSQL, Valkey, and machine-learning cache use K3s `local-path`; and
- Immich-managed writable storage uses the media HDD; and
- all external-library trees are mounted read-write.

Immich's writable paths are separated from the personal-media tree:

```text
/home/bupd/hdd/data/immich/library  -> /data
/home/bupd/hdd/data/immich/backups -> database backup jobs
```

The Immich server sees the complete personal media tree at:

```text
Host: /home/bupd/hdd/data/BUPD_Personal -> /mnt/photos (read-write)
Host: /home/bupd/hdd/data/mobile-booky  -> /mnt/mobile-booky (read-write)
Host: /home/bupd/hdd/data/Prasanth      -> /mnt/prasanth (read-write)
```

This is intentionally destructive access: emptying Immich's trash can delete
original external-library files. Immich's hash-based duplicate check applies to
upload libraries and is scoped per library; it is not a global deduplicator for
the external `BUPD_Personal` tree. Keep an independent backup before deleting
duplicates.

Immich is hard-pinned to `media-worker`. The live PostgreSQL data directory is
on the worker's Linux filesystem, not the NTFS media disk.

## NVIDIA GPU acceleration

The platform deploys NVIDIA's GPU Operator and HAMi on `media-worker`. The GPU
Operator retains physical GPU discovery and DCGM metrics, but its device plugin
is disabled. HAMi is the only plugin advertising `nvidia.com/gpu`, and it
enforces CUDA allocation limits through `nvidia.com/gpumem`.

Immich receives a combined 5 GiB VRAM budget: 3072 MiB for CUDA machine
learning and 2048 MiB for NVENC transcoding. Both Pods use K3s's `nvidia`
RuntimeClass. HAMi isolation is software-enforced at the CUDA API layer rather
than hardware isolation like MIG; an allocation beyond the declared budget
returns CUDA out-of-memory.

Verify Kubernetes and the containers:

```bash
kubectl get node media-worker \
  -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{" HAMi vGPU slots\n"}'
kubectl -n gpu-operator get pods
kubectl -n kube-system get pods -l app.kubernetes.io/name=hami
kubectl -n immich get pods \
  -o custom-columns=NAME:.metadata.name,RUNTIME:.spec.runtimeClassName,GPU:.spec.containers[0].resources.limits.nvidia\.com/gpu,VRAM:.spec.containers[0].resources.limits.nvidia\.com/gpumem
kubectl -n immich exec deployment/immich-machine-learning -- nvidia-smi
kubectl -n immich exec deployment/immich-server -- nvidia-smi
```

Machine-learning logs should report `CUDAExecutionProvider` after a Smart
Search or Face Detection job begins. NVENC is selected in the Flux-managed
Immich configuration file with hardware decoding enabled.

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
Database dumps: /home/bupd/hdd/data/immich/backups
Managed assets: /home/bupd/hdd/data/immich/library (`immich-managed-library-hdd`)
External media: /home/bupd/hdd/data/BUPD_Personal (read-write at /mnt/photos)
External media: /home/bupd/hdd/data/mobile-booky (read-write at /mnt/mobile-booky)
External media: /home/bupd/hdd/data/Prasanth (read-write at /mnt/prasanth)
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

### Add the external photo and video libraries

Finish fresh onboarding and create the administrator account first. Then, in
the Immich web UI:

1. Open **Administration -> External Libraries**.
2. Click **Create Library** and select its owner.
3. Name the library for the mounted tree.
4. Add one of `/mnt/photos`, `/mnt/mobile-booky`, or `/mnt/prasanth` as the
   import path. Create separate libraries if they have different owners.
5. Click **Scan New Library Files**.
6. Watch **Administration -> Jobs** for library, metadata, thumbnail, and
   machine-learning progress.

The scan is recursive. Immich imports supported photos and videos and ignores
unsupported files such as documents and audio. The mount is read-write, so
emptying the trash for an external asset can delete the source file.

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
sudo ls -lh /home/bupd/hdd/data/immich/backups/*.sql.gz
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
  /home/bupd/hdd/data/immich/backups/ \
  '<off-host-backup>/immich/database-backups/'
```

For the strongest consistency, stop writes to Immich while copying. Never
modify asset files inside `library`, `upload`, or `profile` by hand.

Official reference: [Immich Backup and Restore](https://docs.immich.app/administration/backup-and-restore/).
