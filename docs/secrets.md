# Secrets with SOPS and Age

Secret values committed to this public repository must be encrypted with SOPS.
The repository's public Age recipient is stored in `.sops.yaml`. The matching
private identity remains at `~/.config/sops/age/keys.txt` and must never be
committed or copied into the OCI artifact.

The encrypted file keeps `apiVersion`, `kind`, and `metadata` readable while
encrypting only `data` and `stringData`. Flux decrypts the values in memory.

To inspect or edit an existing encrypted file, create a local plaintext copy:

```bash
just decrypt
```

This creates a gitignored `*.dec.yaml` sibling for every `*.sops.yaml` file
without printing the values. It refuses to overwrite existing decrypted files.
Edit whichever plaintext files need changing, then seal all of them again:

```bash
just encrypt
```

Encryption atomically updates `grafana-admin.sops.yaml`, verifies that SOPS can
recognize the ciphertext, and removes the plaintext copy. Validation and
artifact builds fail while any `*.dec.yaml` or `*.plain.yaml` file remains.

The Tailscale Operator OAuth credential follows the same workflow:

```bash
just decrypt
# Edit operator-oauth.dec.yaml and set stringData.client_id/client_secret.
just encrypt
```

Flux creates the resulting `tailscale/operator-oauth` Secret. No out-of-band
`kubectl create secret` step is required.

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
