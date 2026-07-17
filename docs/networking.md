# Private networking

## Policy

The `ins1` cluster is private. Tailscale is the only remote access plane, and
no Kubernetes application is intentionally exposed to the public internet.

The following are prohibited:

- Tailscale Funnel and the `tailscale.com/funnel` annotation
- Public DNS records for cluster services
- Router port forwards to Kubernetes ingress, NodePorts, or the API server
- Public cloud load balancers

The LAN and tailnet have deliberately different responsibilities:

| Plane | Purpose | Valid identities |
| --- | --- | --- |
| LAN underlay | K3s registration, kubelet, CNI, and local storage traffic | `192.168.0.0/24` addresses |
| Tailnet access | Administration and every user-facing service | Dedicated `*.tail6c5ea9.ts.net` names |
| Cluster network | Pod-to-Service traffic | `<service>.<namespace>.svc.cluster.local` |

An application must never publish, redirect to, or generate links containing a
LAN node address. LAN addresses are implementation details, not service
identities.

## Control-plane access

`archbtw` has these stable identities:

| Network | Address |
| --- | --- |
| LAN | `192.168.0.4` |
| Tailscale IPv4 | `100.81.118.34` |
| Tailscale MagicDNS | `archbtw.tail6c5ea9.ts.net` |

The K3s API certificate declares both addresses and the MagicDNS name through
`hosts/instance1/k3s/config.yaml`. Local agents register through
`https://192.168.0.4:6443`; tailnet administrators use
`https://archbtw.tail6c5ea9.ts.net:6443`.

The checked-in kubeconfig must never contain credentials. To create a private
remote kubeconfig, copy the administrator kubeconfig outside Git and replace
its loopback server URL with the MagicDNS API URL.

## Application ingress

Applications do not share the control-plane Tailscale address. Flux will
install the Tailscale Kubernetes Operator from its Helm chart. Each HTTP
application will declare an `Ingress` with `ingressClassName: tailscale`, and
the operator will provision a tailnet-only MagicDNS name and TLS certificate.

This keeps ingress proxy Pods on schedulable worker nodes instead of
`archbtw`. Non-HTTP services may use a `Service` with
`loadBalancerClass: tailscale` when explicitly required.

The operator requires a Tailscale OAuth client. Its client ID and secret must
be stored as a SOPS-encrypted Kubernetes Secret and must never be committed in
plaintext.

### Service identity contract

Each application receives its bare application name as its stable tailnet
identity. The Kubernetes cluster name is not included in user-facing URLs.

| Application | Tailscale identity |
| --- | --- |
| Immich | `https://immich.tail6c5ea9.ts.net` |
| Jellyfin | `https://jellyfin.tail6c5ea9.ts.net` |
| Sonarr | `https://sonarr.tail6c5ea9.ts.net` |
| Radarr | `https://radarr.tail6c5ea9.ts.net` |
| Prowlarr | `https://prowlarr.tail6c5ea9.ts.net` |
| Bazarr | `https://bazarr.tail6c5ea9.ts.net` |
| Transmission | `https://transmission.tail6c5ea9.ts.net` |
| File Browser | `https://filebrowser.tail6c5ea9.ts.net` |

Additional Arr services follow the same rule: the lower-case application name
is the Tailscale hostname. For example, a future Lidarr deployment uses
`https://lidarr.tail6c5ea9.ts.net`. Hostnames must remain unique across the
tailnet.

The exact name is declared in the application's Tailscale `Ingress`, for
example:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: immich
  namespace: immich
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: immich-server
      port:
        number: 2283
  tls:
    - hosts:
        - immich
```

The matching Helm values must configure the application's external URL,
trusted proxy settings, callback URLs, and generated links with the resulting
HTTPS MagicDNS FQDN. Internal dependencies continue to use Kubernetes Service
DNS and never route through Tailscale ingress.

Application manifests must use `ClusterIP` Services unless a reviewed
non-HTTP protocol explicitly requires a Tailscale `LoadBalancer`. `NodePort`
Services and load balancers without `loadBalancerClass: tailscale` are not
allowed.

## Bootstrap sequence

1. Log `archbtw` back into its intended tailnet and confirm that it receives
   `100.81.118.34` and `archbtw.tail6c5ea9.ts.net`.
2. Run the declared `media-worker` host reconciler. It joins the worker first,
   then makes the control plane agentless and restarts both sides safely.
3. Confirm that `media-worker` is the only Ready Kubernetes Node.
4. Bootstrap Flux.
5. Install the Tailscale Kubernetes Operator through a pinned Helm release and
   a SOPS-encrypted OAuth Secret.
6. Expose each application with a tailnet-only Tailscale Ingress.

Until steps 1-5 are complete, application deployment must remain blocked: the
control plane is tainted, and there is no approved private ingress path.
