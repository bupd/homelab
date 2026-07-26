# Sure

Sure is deployed as a private, tailnet-only personal finance application at:

```text
https://sure.tail6c5ea9.ts.net
```

Flux installs the Rails web process, Sidekiq worker, Redis, and the database
migration Job through the pinned `bjw-s` application chart. CloudNativePG owns
the PostgreSQL cluster.

## First login

Create the owner account while onboarding is open. After confirming that login
and background jobs work, go to **Settings → Self-Hosting → Onboarding** and
change the instance to **Closed**.

## Backups

Both backup processes are Kubernetes CronJobs:

- `sure-database-backup` runs at 03:00 Asia/Kolkata;
- `sure-storage-backup` runs at 03:30 Asia/Kolkata.

They write directly to the media-worker host at:

```text
/home/bupd/hdd/data/backups/sure
```

The target is a `hostPath`, not a backup PVC. Each backup keeps seven daily
archives and four weekly archives.

Trigger and inspect an immediate backup:

```bash
kubectl -n sure create job --from=cronjob/sure-database-backup sure-database-backup-manual
kubectl -n sure create job --from=cronjob/sure-storage-backup sure-storage-backup-manual
kubectl -n sure logs -l job-name=sure-database-backup-manual
kubectl -n sure logs -l job-name=sure-storage-backup-manual
```

## Restore

Suspend the `sure` HelmRelease, then scale the `sure-web` and `sure-worker`
Deployments to zero so they cannot write during recovery. Restore the newest
PostgreSQL dump into `sure-database-rw` with `psql`, extract the matching
storage archive into the `sure-storage` PVC, then resume the HelmRelease and
let Flux restore the workload replicas. Keep `sure-app` unchanged: changing
the Rails or Active Record encryption keys makes encrypted data unreadable.
