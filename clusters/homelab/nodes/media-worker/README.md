# media-worker policy

This folder owns Kubernetes labels for `media-worker`.

The worker must join the cluster before this policy is applied. The host
reconcile script does that in the correct order.

There is no `archbtw` Node policy. `archbtw` is agentless, so it does not have
a Kubernetes Node object.

