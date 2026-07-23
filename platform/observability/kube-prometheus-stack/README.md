# Prometheus and Grafana

`kube-prometheus-stack` installs Prometheus Operator, Prometheus, Alertmanager,
kube-state-metrics, node-exporter, Grafana, default rules, and dashboards.

This is cluster-wide. Prometheus and Grafana are central workloads that may run
on any schedulable worker. Node-exporter is a DaemonSet and automatically runs
on every eligible worker, including workers added later. kube-state-metrics
observes objects across the cluster. Application `ServiceMonitor` and
`PodMonitor` resources are selected across namespaces.

The Grafana administrator Secret is SOPS-encrypted in
`grafana-admin.sops.yaml`. Flux decrypts it only in memory while reconciling.
Retrieve the generated password after deployment:

```bash
kubectl -n observability get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 --decode
printf '\n'
```

After reconciliation:

```bash
kubectl -n observability get pods,pvc,ingress
kubectl -n observability get prometheus,alertmanager
```

Both web interfaces are available only inside the tailnet:

- Grafana: `https://grafana.tail6c5ea9.ts.net`
- Prometheus: `https://prometheus.tail6c5ea9.ts.net`

Prometheus does not provide application-level authentication. Tailscale ACLs
are therefore the access-control boundary for its private Ingress. A temporary
local fallback remains available with
`kubectl -n observability port-forward service/kube-prometheus-stack-prometheus 9090:9090`.
