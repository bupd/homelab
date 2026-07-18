# Secrets with SOPS and Age

Secret values committed to this public repository must be encrypted with SOPS.
The repository's public Age recipient is stored in `.sops.yaml`. The matching
private identity remains at `~/.config/sops/age/keys.txt` and must never be
committed or copied into the OCI artifact.

The encrypted file keeps `apiVersion`, `kind`, and `metadata` readable while
encrypting only `data` and `stringData`. Flux decrypts the values in memory.

After installing Flux and before bootstrapping reconciliation, install the Age
identity into `flux-system`:

```bash
just flux-install
just flux-sops-key
just flux-bootstrap
```

The resulting `sops-age` Kubernetes Secret is a bootstrap credential. Back up
the original Age identity securely; without it, a rebuilt cluster cannot
decrypt the committed Secrets.

Create a new encrypted Kubernetes Secret without writing plaintext to the
repository:

```bash
kubectl -n <namespace> create secret generic <name> \
  --from-literal='<key>=<value>' \
  --dry-run=client -o yaml \
  | sops encrypt \
      --filename-override '<path>/<name>.sops.yaml' \
      --input-type yaml --output-type yaml \
      --output '<path>/<name>.sops.yaml' /dev/stdin
```

Add the encrypted file to the relevant `kustomization.yaml`, run
`just validate`, and commit it. Never apply a SOPS-encrypted manifest directly
with kubectl; Flux performs the decryption during reconciliation.
