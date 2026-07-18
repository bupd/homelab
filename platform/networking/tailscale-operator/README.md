# Tailscale Kubernetes Operator

The operator creates private tailnet ingress proxies and valid HTTPS
certificates. Funnel is not enabled, so these services are not public.

Before Flux bootstrap, enable MagicDNS and HTTPS in the Tailscale admin console,
configure `tag:k8s-operator` as an owner of `tag:k8s`, and create an OAuth client
with Devices Core, Auth Keys, and Services write scopes. Assign the OAuth client
the `tag:k8s-operator` tag.

Create its Secret directly in the cluster:

```bash
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
kubectl -n tailscale create secret generic operator-oauth \
  --from-literal=client_id='<oauth-client-id>' \
  --from-literal=client_secret='<oauth-client-secret>'
```

The Secret is intentionally absent from the public OCI artifact. The official
chart automatically mounts a pre-created Secret named `operator-oauth`.
