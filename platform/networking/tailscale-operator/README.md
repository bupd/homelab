# Tailscale Kubernetes Operator

The operator creates private tailnet ingress proxies and valid HTTPS
certificates. Funnel is not enabled, so these services are not public.

Before Flux bootstrap, enable MagicDNS and HTTPS in the Tailscale admin console,
configure `tag:k8s-operator` as an owner of `tag:k8s`, and create an OAuth client
with Devices Core, Auth Keys, and Services write scopes. Assign the OAuth client
the `tag:k8s-operator` tag.

Create the credential from the
[Tailscale Trust Credentials page](https://console.tailscale.com/admin/settings/trust-credentials/add),
choose **OAuth**, and match the checked scopes and tags shown below:

![Tailscale OAuth scopes for the Kubernetes Operator](../../../docs/image/tailscale-kubernetes-operator-oauth-scopes.png)

The OAuth credential is stored in the SOPS-encrypted
`operator-oauth.sops.yaml` manifest. To set or rotate it:

```bash
just decrypt platform/networking/tailscale-operator/operator-oauth.sops.yaml
# Edit operator-oauth.dec.yaml and replace client_id and client_secret.
just encrypt platform/networking/tailscale-operator/operator-oauth.dec.yaml
just validate
```

Only ciphertext enters Git and the public OCI artifact. Flux decrypts the
manifest in memory and creates `tailscale/operator-oauth`; the official chart
mounts that Secret automatically. Do not apply or create it manually.
