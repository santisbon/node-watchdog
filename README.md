# Kubernetes node watchdog

[Under Development]

Kubernetes CronJob that automatically recovers workloads when a cluster node goes down in a homelab. It runs every 2 minutes, force-deletes pods stuck in `Terminating`, and blocklists stale Ceph RBD client locks so rescheduled pods can re-attach their volumes.

## Problem it solves

When a node goes `NotReady`, Kubernetes can't confirm its pods have stopped, so they stay in `Terminating` indefinitely. Meanwhile, any `RWO` (ReadWriteOnce) Ceph RBD volumes those pods held remain locked by the dead node's client, blocking the replacement pod from mounting them on a healthy node. This watchdog breaks both locks automatically.

## How it works

On each run the script:

1. Lists all `NotReady` nodes and their internal IPs
2. Force-deletes every pod stuck in `Terminating` on those nodes
3. Scans every RBD volume in the `microk8s-rbd0` pool for watchers from the dead node's IP
4. Calls `ceph osd blocklist add <watcher>` for each match, releasing the lock

## Prerequisites

- MicroK8s cluster with MicroCeph
- Helm 3
- `kubectl` access from the machine you deploy from

## How the Ceph keyring is handled

The `ceph` and `rbd` CLI tools need two files to talk to the cluster: `ceph.conf` (monitor addresses and cluster ID) and `ceph.client.admin.keyring` (the CephX authentication token for the admin user). On a MicroCeph node these live at `/var/snap/microceph/current/conf/`.

Rather than mounting that path directly into every watchdog pod run — which would permanently pin the CronJob to a specific node — the chart uses a Helm pre-install hook to copy those files into a Kubernetes Secret once, at install time. After that, the CronJob mounts the Secret as `/etc/ceph` and can be scheduled on any node.

**The keyring is a CephX token, not an SSH key.** It is a short base64-encoded string that Ceph uses for its own internal authentication (similar to a database password). It lives in etcd alongside every other Secret in the cluster. If it ever needs to be rotated, MicroCeph supports `ceph auth rotate client.admin`.

### Keyring init hook

`templates/hook-keyring-init.yaml` defines four resources, all annotated as Helm hooks so they run before the main chart resources are created:

| Weight | Resource | Purpose |
|--------|----------|---------|
| -10 | `ServiceAccount` node-watchdog-init | Identity for the hook Job |
| -5 | `Role` + `RoleBinding` node-watchdog-init | Grants permission to create/update Secrets in the release namespace |
| 0 | `Job` node-watchdog-keyring-init | Mounts the MicroCeph conf dir from `cephNode` and writes `ceph-admin-keyring` Secret |

The Job runs on `cephNode` (the only time node pinning is required). On `helm upgrade` the hook re-runs, so the Secret stays current if MicroCeph is upgraded between Helm releases.

### What gets deleted and when

Hook resources carry a `helm.sh/hook-delete-policy` annotation that controls cleanup:

| Resource | Delete policy | When it is deleted |
|----------|--------------|-------------------|
| `Job` node-watchdog-keyring-init | `before-hook-creation,hook-succeeded` | Deleted by Helm after it completes successfully; also deleted at the start of the next `helm upgrade` before a new one is created |
| Pod created by the Job | (follows the Job) | Deleted together with the Job |
| `ServiceAccount` node-watchdog-init | `before-hook-creation` | Persists after install; deleted only at the start of the next `helm upgrade` |
| `Role` + `RoleBinding` node-watchdog-init | `before-hook-creation` | Same as above |
| `ceph-admin-keyring` Secret | none (not a hook) | Persists for the lifetime of the release; deleted only on `helm uninstall` |

The Secret is intentionally not a hook resource. It must outlive the Job that created it so the CronJob can mount it on every run.

## Ceph image version

The `quay.io/ceph/ceph` image in `cronjob.yaml` must match your MicroCeph version. To check:

On a cluster node:
```bash
snap info microceph | grep installed
```

Example output:
```
installed: 19.2.3+snapcf306793a4  (1736)  117MB  held
```

The version is `19.2.3`, so the image tag is `v19.2.3`. Update `image.ceph.tag` in `values.yaml` if you upgrade MicroCeph. Similarly, pin `image.kubectl.tag` to your MicroK8s version:

On a cluster node:
```bash
snap info microk8s | grep installed
```

## Key paths

| Path | What it is |
|------|-----------|
| `/var/snap/microceph/current/conf` | MicroCeph config dir — read once by the hook Job at install time |
| `/var/snap/microceph/current/conf/ceph.conf` | Ceph cluster config (monitor addresses, cluster ID) |
| `/var/snap/microceph/current/conf/ceph.client.admin.keyring` | CephX admin token, stored in the `ceph-admin-keyring` Secret after install |
| `ceph-admin-keyring` | Kubernetes Secret created by the hook; mounted as `/etc/ceph` in the CronJob pod |
| `microk8s-rbd0` | RBD pool used by MicroK8s PersistentVolumes |

## RBAC

`rbac.yaml` defines a `ClusterRole` scoped to the minimum required verbs (`get`/`list` nodes, `get`/`list`/`delete` pods). It is safe to apply even if the MicroK8s `rbac` addon is currently disabled. The resources are stored but not enforced until you enable it:

```bash
microk8s enable rbac
```

## Deploy

### Package the chart

```bash
helm package charts/node-watchdog
```

This produces `node-watchdog-0.1.0.tgz` (version comes from `Chart.yaml`).

### Push to the MicroK8s built-in registry

The MicroK8s registry addon exposes an unauthenticated registry on port `32000` on every node. Use any node's LAN IP or hostname to reach it from your workstation. If the node you're using is `node-01`:

```bash
helm push node-watchdog-*.tgz oci://node-01.local:32000/charts --plain-http
```

View published charts:

```bash
# List all repositories in the registry
curl -s http://node-01.local:32000/v2/_catalog | jq

# List available versions of the chart
curl -s http://node-01.local:32000/v2/charts/node-watchdog/tags/list | jq

# Inspect chart metadata for a specific version
helm show chart oci://node-01.local:32000/charts/node-watchdog --version 0.1.0 --plain-http
```

### Install from the registry

```bash
helm upgrade --install node-watchdog oci://node-01.local:32000/charts/node-watchdog \
  --version 0.1.0 --plain-http \
  --namespace node-watchdog \
  --create-namespace \
  --set cephNode=node-01
```

The `--install` flag makes `helm upgrade` behave as an install if the release does not exist yet, so the same command works for both the initial deploy and all subsequent upgrades. Omit `--set` flags to accept the defaults from `values.yaml`.

To see the rendered manifests before applying:

```bash
helm template node-watchdog charts/node-watchdog --namespace node-watchdog
```

## Verify

Check the CronJob was created:

```bash
kubectl get cronjob -n node-watchdog
```

Wait up to 2 minutes for the first Job to run, then inspect its logs:

```bash
kubectl logs -n node-watchdog -l job-name --tail=50
```

A healthy run with all nodes up looks like:

```
[2026-06-27T18:00:00Z] Watchdog run starting
[2026-06-27T18:00:01Z] All nodes Ready — exiting
```

A recovery run looks like:

```
[2026-06-27T18:02:00Z] Watchdog run starting
[2026-06-27T18:02:01Z] Node node-02 (192.168.X.Y) is NotReady — starting recovery
[2026-06-27T18:02:02Z] Force-deleting stuck pod bookorbit/bookorbit-xxxx-yyy
[2026-06-27T18:02:03Z] Blocklisting 192.168.X.Y:0/1234567890 (held lock on csi-vol-abc123-...)
[2026-06-27T18:02:04Z] Blocklisting 192.168.X.Y:0/1234567890 (held lock on csi-vol-def456-...)
[2026-06-27T18:02:05Z] Recovery complete for node-02
[2026-06-27T18:02:05Z] Watchdog run complete
```

## Full failure and recovery lifecycle

### Phase 1 — Node goes down

- The node's Kubernetes status transitions to `NotReady`
- Its pods get stuck in `Terminating`. The kubelet is gone so Kubernetes can't confirm they stopped
- Any RWO PVCs those pods held remain locked by the dead node's Ceph client session (identified by `<node-ip>:<port>/<nonce>`)
- Replacement pods scheduled on healthy nodes get stuck in `ContainerCreating`. The CSI driver tries to map the RBD image but the exclusive lock is still held by the dead client

### Phase 2 — Watchdog runs (within 2 minutes)

- Detects the `NotReady` node and its internal IP
- Force-deletes the stuck `Terminating` pods, freeing Kubernetes to treat them as gone
- Scans every RBD volume for watchers matching the dead node's IP and calls `ceph osd blocklist add` for each one
- Ceph immediately invalidates those client sessions and releases their locks
- The CSI driver on the healthy node retries, successfully maps the RBD images, and the replacement pods move from `ContainerCreating` to `Running`
- PVCs remain in `Bound` state throughout — only their lock holder changes

### Phase 3 — Node is rebooted and rejoins

- The node's Kubernetes status returns to `Ready`
- Its Ceph OSD (e.g. `osd.2`) starts a fresh client session with a new random nonce — a completely different session identity from the one that was blocklisted
- The new session is not on the blocklist, so the OSD reconnects to the monitors without issue
- Ceph begins re-replicating the data that was degraded while the OSD was absent; the cluster returns to `HEALTH_OK` once replication is complete
- The old blocklist entry (tied to the previous session's nonce) expires harmlessly within 1 hour — no manual cleanup required
- The watchdog finds all nodes `Ready` on its next run and exits immediately without taking any action
- PVCs stay attached to the healthy node where the replacement pods are running; Kubernetes does not move them back unless those pods are rescheduled onto the recovered node

## Why not just use fencing like enterprise clusters do?

Enterprise clusters solve this at the hardware level using **fencing**, also called STONITH (Shoot The Other Node In The Head). A fencing agent — IPMI, iDRAC, iLO, a smart PDU, or a cloud provider API — can physically power off a dead node on demand. Once the node is confirmed dead at the hardware level, Ceph's watcher timeout (~30 seconds) clears the RBD lock naturally because the dead client can never send another heartbeat. No blocklist command is needed.

Without fencing you can't be sure the node is truly gone — it might be network-partitioned but still running. If it came back while another pod held the volume, both would think they owned it, risking data corruption. The blocklist is what you reach for when you can't guarantee the node is dead.

**How enterprise environments handle it:**

- **Rook on bare metal** — pairs Rook with Medik8s (Node Health Check + Self Node Remediation) to fence via IPMI before touching any storage state.
- **Managed Kubernetes (EKS, GKE, AKS)** — the cloud provider API is the fencing agent. The node group or autoscaler terminates the VM, giving an instant hardware-level guarantee.
- **RHCS / VMware** — Pacemaker/Corosync with a dedicated fencing agent per host.

**Why this cluster needs the watchdog instead:** Raspberry Pis have no IPMI or BMC — there is no hardware management interface to pull the plug remotely. Software-only remediation is the best available option without adding a smart PDU to the rack. A network-controlled PDU would act as a fencing agent and eliminate this problem class entirely.

## Tear down

```bash
helm uninstall node-watchdog --namespace node-watchdog
kubectl delete namespace node-watchdog
```

## Glossary

| Term | Definition |
|------|-----------|
| **AKS** | Azure Kubernetes Service — Microsoft's managed Kubernetes offering |
| **CephX** | Ceph's internal authentication system. Each user (e.g. `client.admin`) has a base64-encoded secret key stored in a keyring file. Clients present this key to the monitors to prove their identity before accessing the cluster |
| **Helm hook** | A Kubernetes resource annotated with `helm.sh/hook` so that Helm runs it at a specific point in the release lifecycle (e.g. `pre-install` before any chart resources are created). Hook resources are managed separately from the main chart and can be deleted automatically on completion |
| **Helm** | Package manager for Kubernetes. A chart is a collection of templated manifests with a `values.yaml` for configuration; `helm install` renders the templates and applies them to the cluster |
| **BMC** | Baseboard Management Controller — a dedicated chip on server motherboards that provides out-of-band management (power control, console access) independent of the OS |
| **Ceph** | Open-source distributed storage system providing block, file, and object storage |
| **CronJob** | Kubernetes resource that runs a Job on a repeating schedule |
| **CSI** | Container Storage Interface — standard API for exposing storage systems to containerized workloads |
| **EKS** | Elastic Kubernetes Service — AWS's managed Kubernetes offering |
| **Fencing** | The act of forcibly isolating a failed node to guarantee it can no longer access shared resources, preventing data corruption |
| **GKE** | Google Kubernetes Engine — Google Cloud's managed Kubernetes offering |
| **iDRAC** | Integrated Dell Remote Access Controller — Dell's BMC implementation |
| **iLO** | Integrated Lights-Out — HPE's BMC implementation |
| **IPMI** | Intelligent Platform Management Interface — industry standard protocol for out-of-band server management via the BMC |
| **MicroCeph** | Canonical's lightweight Ceph distribution, packaged as a snap, designed for small clusters |
| **MicroK8s** | Canonical's lightweight Kubernetes distribution, packaged as a snap |
| **Medik8s** | A set of Kubernetes operators (Node Health Check, Self Node Remediation) for automated bare-metal node remediation |
| **OSD** | Object Storage Daemon — the Ceph process that manages one storage device (disk) and handles data replication |
| **PDU** | Power Distribution Unit — a rack-mounted power strip; a "smart PDU" adds network control for remote power cycling, enabling software fencing |
| **PVC** | PersistentVolumeClaim — a Kubernetes request for storage, bound to a PersistentVolume |
| **RBAC** | Role-Based Access Control — Kubernetes authorization system that restricts API access based on roles assigned to users or service accounts |
| **RBD** | RADOS Block Device — Ceph's block storage layer, presenting a virtual disk backed by the Ceph cluster |
| **RHCS** | Red Hat Ceph Storage — Red Hat's enterprise-supported Ceph distribution |
| **Rook** | Kubernetes operator that manages Ceph clusters running inside Kubernetes |
| **RWO** | ReadWriteOnce — a PVC access mode meaning the volume can only be mounted by one node at a time; enforced via an exclusive lock in RBD |
| **STONITH** | Shoot The Other Node In The Head — colloquial term for fencing; ensures a failed node is definitively killed before its resources are reassigned |
