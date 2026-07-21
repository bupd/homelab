# Media automation

Flux deploys this directory after Jellyfin and networking are ready. All
applications run on `media-worker`, keep their configuration on retained
`local-path` PVCs, and use the existing `media/media-data` claim.

The canonical path in every downloader and library manager is `/data`:

| Purpose | Path |
| --- | --- |
| Movies | `/data/Movies` |
| TV | `/data/TV` |
| Anime | `/data/Anime` |
| Music | `/data/Music` |
| Adult | `/data/Adult` |
| Completed downloads | `/data/downloads/complete` |
| Incomplete downloads | `/data/downloads/incomplete` |

Keeping downloads and libraries on the same filesystem allows atomic imports
and hardlinks. Do not add remote path mappings between these applications.

`media-bootstrap-v1` creates the missing directories, connects Transmission to
the Arr applications, connects the Arr applications to Prowlarr, initializes
Jellyseerr against Jellyfin, adds the TV/Anime/Adult libraries, and renders the
Janitorr configuration. The Job is part of the Flux desired state; it must not
be run manually.

Janitorr starts in dry-run mode. Review its logs before changing
`application.dry-run` to `false`. Prowlarr indexers and Bazarr subtitle providers
are intentionally user-selected because their credentials, availability, and
content policies differ.

Transmission currently uses normal node egress. Its Kubernetes Service and
shared paths are stable so a later namespace VPN gateway can be inserted
without changing Arr download-client URLs.

All web interfaces are tailnet-only at `https://<app>.tail6c5ea9.ts.net`.
The Arr, Bazarr, and Transmission administrator username is `admin`; retrieve
the generated password locally without printing it into Git history:

```bash
sops decrypt apps/media/automation/credentials.sops.yaml \
  | yq -r '.stringData.ADMIN_PASSWORD'
```
