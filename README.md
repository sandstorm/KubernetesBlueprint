# K3s Standalone Boilerplate

Ansible-based setup for installing [K3s](https://k3s.io) (lightweight Kubernetes) on a single Linux server. Extracted
from a production setup running for 5+ years on bare metal at [Sandstorm](https://sandstorm.de).

This boilerplate is designed for small teams running Kubernetes without a dedicated DevOps department.

## Prerequisites

- **Server:** Linux (Ubuntu 22.04+ LTS or Debian 12+ recommended), x86_64 architecture
- **Access:** SSH root access to the server
- **Local:** [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) installed on your machine (
  `pip install ansible`)

## Quick Start with Hetzner Cloud

We run our own clusters on [Hetzner](https://www.hetzner.com/) — we're happy long-time customers, not affiliated.
The `mise` tasks in this repo automate the full setup: creating servers, load balancer, firewall, and generating the
Ansible inventory from real IPs.

**Prerequisites:** [mise](https://mise.jdx.dev/) installed locally, an active Hetzner Cloud project with an API token
configured in the `hcloud` CLI (`hcloud context create my-project`), and an SSH key uploaded to the project.

```bash
# 1. Install tools (gum, hcloud CLI, jq)
mise install

# 2. Interactive config — select context, SSH key, server type, location
mise run hetzner:setup

# 3. Create Hetzner infrastructure (network, firewall, server, load balancer)
mise run hetzner:create

# 4. Install k3s via Ansible
mise run hetzner:ansible

# --- Optional: add a second node (Variant 2) ---

# 5a. Create second server on Hetzner + regenerate inventory
mise run hetzner:add-node

# 5b. Install k3s on the new node only
mise run hetzner:ansible -- --limit <PREFIX>-node-2

# Tear everything down
mise run hetzner:destroy
```

After `mise r hetzner:ansible` completes, the playbook automatically writes a `kubeconfig` file into `server-setup/`
with the correct server address. Connect with:

```bash
export KUBECONFIG=server-setup/kubeconfig
kubectl get nodes
```

> **Note:** The kubeconfig grants cluster-admin access — store it securely and never commit it to version control.

> **What gets created:** a private network (10.208.183.0/24), a firewall allowing SSH/HTTP/HTTPS, a server with both a
> public IP (for SSH) and a private IP, and a load balancer forwarding ports 80/443 to the node via the private network.
> Config is persisted in `.cluster.env` (gitignored). Ansible inventory and group\_vars are generated automatically.

---

## Quick Start (manual)

```bash
cd server-setup

# 1. Create your inventory
cp inventory/hosts.yml.example inventory/hosts.yml
# Edit inventory/hosts.yml — set your server IP

# 2. Create your configuration
cp group_vars/all.yml.example group_vars/all.yml
# Edit group_vars/all.yml — set k3s_version and k3s_token

# 3. Run the playbook
ansible-playbook playbook.yml
```

After the playbook completes, a `kubeconfig` file is automatically written into `server-setup/` with the correct
server address. Connect with:

```bash
export KUBECONFIG=server-setup/kubeconfig
kubectl get nodes
```

> **Note:** The kubeconfig grants cluster-admin access — store it securely and never commit it to version control.

## What Gets Installed

- **K3s binary** with checksum verification (downloaded from GitHub releases)
- **systemd service** for automatic start/restart
- **CLI tools:** `kubectl`, `crictl`, `ctr` (symlinked from K3s binary)
- **etcdctl** wrapper for debugging the embedded etcd database (optional)
- **Kernel tuning:** sysctl settings for large clusters and Elasticsearch workloads
- **Rancher UI** with cert-manager and Let's Encrypt (optional)

## Network Architecture

### Recommended: Nodes Behind a Load Balancer (private-only)

The recommended setup — even for a single node — is to place all K3s nodes on a **private network only** and route
internet traffic through an **external load balancer**. This is how our production clusters run.

**Why this matters:**

- **Security:** etcd (2379-2380) and kubelet (10250) are never exposed to the internet — only the K3s API server
  (6443) is opened publicly so you can use `kubectl` from outside. etcd and kubelet stay on the private network only.
- **Scalability:** Adding nodes later is trivial — just add them to the internal network. The load balancer handles
  traffic distribution. You can scale from 1 to N nodes without changing your network architecture.
- **Flexibility:** You can swap nodes, update one at a time, or migrate to different hardware — the load balancer IP
  stays the same, so DNS and clients don't need to change.

```
                     Internet
                         │
                  ┌──────┴───────┐
                  │ Load Balancer│
                  │  (Public IP) │
                  │80/443 → Nodes│
                  └──────┬───────┘
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│    Node 1    │  │    Node 2    │  │    Node 3    │
│   private    │  │   private    │  │   private    │
│ 10.208.183.1 │  │ 10.208.183.2 │  │ 10.208.183.3 │
└──────────────┘  └──────────────┘  └──────────────┘
              Internal Network
           (e.g., 10.208.183.0/24)
```

This works with a single node too — the load balancer simply forwards to one backend.

**What you need:**

| What                    | Example           | Purpose                                                                            |
|-------------------------|-------------------|------------------------------------------------------------------------------------|
| Private IP per node     | `10.208.183.1`    | All K3s communication (API, etcd, CNI overlay, ingress) — set via `k3s_private_ip` |
| Load balancer public IP | `203.0.113.50`    | Single entry point for HTTP/HTTPS traffic                                          |
| DNS name                | `app.example.com` | Points to the load balancer IP                                                     |

You need a **shared internal network** between all nodes (and the load balancer). Most hosting providers offer this:
Hetzner (vSwitch/Cloud Network), AWS/GCP/Azure/DO (VPC), or bare metal (dedicated VLAN).

The load balancer forwards **port 80 and 443** to the nodes' internal IPs. SSH access goes through a bastion host or
VPN — not through a public IP on the K3s nodes themselves. **You might manually need to configure a gateway for outbound
network access.**

### Alternative: Load Balancer + Public IPs for SSH

Same as the recommended setup, but each node also gets a **public IP** for direct SSH access — no bastion host needed.
HTTP/HTTPS traffic still flows through the load balancer; the public IPs are only used for management access.

```
                     Internet
                         │
                  ┌──────┴───────┐
                  │ Load Balancer│
                  │  (Public IP) │
                  │80/443 → Nodes│
                  └──────┬───────┘
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│    Node 1    │  │    Node 2    │  │    Node 3    │
│   private    │  │   private    │  │   private    │
│ 10.208.183.1 │  │ 10.208.183.2 │  │ 10.208.183.3 │
│   public     │  │   public     │  │   public     │
│ 203.0.113.1  │  │ 203.0.113.2  │  │ 203.0.113.3  │
└──────────────┘  └──────────────┘  └──────────────┘
              Internal Network
           (e.g., 10.208.183.0/24)
```

**Make sure you protect the public Node IP addresses with a firewall.**

### Key K3s Network Flags

- `k3s_private_ip` (Ansible variable, per-host) — set to the node's private IP. Ansible auto-detects the NIC
  and injects `--node-ip` (always) and `--flannel-iface` (when Flannel is active) into the k3s service.
  `--node-ip` controls inter-node communication, etcd peer addresses, and CNI overlay routing.
  `--flannel-iface` forces Flannel VXLAN to use the private network interface instead of the public one.
  When using a non-Flannel CNI (`--flannel-backend=none`), only `--node-ip` is injected.
- `--tls-san <IP_OR_HOSTNAME>` (in `k3s_extra_args`) — adds additional IPs/hostnames to the API server TLS
  certificate (add one for every IP or hostname you'll use to reach the API server)

See the [`k3s_extra_args` examples](#k3s_extra_args--common-patterns) below for concrete configurations.

## Firewall Rules

K3s manages its own iptables rules for pod networking. You only need to configure your **host-level or provider-level
firewall** (Hetzner Firewall, cloud security groups, or `ufw`/`iptables` on the host).

**Inter-node ports (internal network only):**

| Port      | Protocol | Purpose                                                        |
|-----------|----------|----------------------------------------------------------------|
| 2379-2380 | TCP      | etcd (embedded, when using `--cluster-init`)                   |
| 10250     | TCP      | Kubelet metrics                                                |
| 8472      | UDP      | VXLAN overlay (Flannel, K3s default CNI)                       |
| 51820     | UDP      | WireGuard (only if using `--flannel-backend=wireguard-native`) |

**Public-facing ports:**

| Port | Protocol | Purpose                                                                                    |
|------|----------|--------------------------------------------------------------------------------------------|
| 80   | TCP      | HTTP ingress traffic                                                                       |
| 443  | TCP      | HTTPS ingress traffic                                                                      |
| 6443 | TCP      | **Kubernetes API server** (`kubectl` access) — **publicly exposed, see warning below**    |

> **Security warning — port 6443:** The Hetzner setup opens port 6443 to the internet so you can run `kubectl` from
> your local machine and CI/CD pipelines. The API is protected by TLS and cluster credentials, but exposing it
> publicly widens the attack surface. If possible, **restrict the source IPs** to your own address(es) by editing the
> firewall rule in `.mise/tasks/hetzner/create` before running `mise run hetzner:create`.

With private nodes behind a load balancer, the LB forwards 80/443 and you can allow all traffic between nodes on the
internal network. With public IPs on nodes, you must firewall the inter-node ports above to the internal network only.

## Configuration Reference

### Required Variables

| Variable      | Description                                                                    | Example          |
|---------------|--------------------------------------------------------------------------------|------------------|
| `k3s_version` | K3s release tag from [GitHub releases](https://github.com/k3s-io/k3s/releases) | `"v1.33.6+k3s1"` |
| `k3s_token`   | Cluster shared secret. Generate with `openssl rand -hex 32`                    | `"a1b2c3..."`    |

### Optional Variables

| Variable                        | Default                 | Description                                                                                            |
|---------------------------------|-------------------------|--------------------------------------------------------------------------------------------------------|
| `k3s_mode`                      | `"server"`              | `"server"` (control plane + worker) or `"agent"` (worker only)                                         |
| `k3s_private_ip`                | —                       | Private IP of this node; auto-injects `--node-ip` (always) and `--flannel-iface` (when Flannel active) |
| `k3s_extra_args`                | `"--cluster-init"`      | Additional K3s CLI arguments (see below)                                                               |
| `k3s_install_rancher`           | `false`                 | Deploy Rancher UI + cert-manager                                                                       |
| `k3s_rancher_hostname`          | —                       | Hostname for Rancher (required when Rancher enabled)                                                   |
| `k3s_rancher_letsencrypt_email` | —                       | Email for Let's Encrypt (required when Rancher enabled)                                                |
| `k3s_rancher_version`           | `"2.12.3"`              | Rancher Helm chart version                                                                             |
| `k3s_certmanager_version`       | `"1.19.0"`              | cert-manager Helm chart version                                                                        |
| `k3s_install_etcdctl`           | `true`                  | Install etcdctl debugging tool                                                                         |
| `etcdctl_version`               | `"v3.5.0"`              | etcdctl version                                                                                        |
| `k3s_private_registry_host`     | —                       | Private Docker registry hostname                                                                       |
| `k3s_private_registry_username` | —                       | Registry username                                                                                      |
| `k3s_private_registry_password` | —                       | Registry password                                                                                      |
| `systemd_dir`                   | `"/etc/systemd/system"` | Path for systemd unit files                                                                            |

### `k3s_extra_args` — Common Patterns

This is the main knob for configuring your cluster. It maps directly to K3s CLI flags.

**Single node (simplest setup):**

```yaml
k3s_extra_args: "--cluster-init"
```

**Single node, custom ingress (disable built-in Traefik):**

```yaml
k3s_extra_args: "--cluster-init --disable=traefik"
```

**Multi-node — first server (initializes the cluster):**

```yaml
# Per-host in inventory (--node-ip and --flannel-iface injected automatically):
k3s_private_ip: "10.208.183.1"
k3s_extra_args: "--cluster-init --tls-san 10.208.183.1 --tls-san 203.0.113.10"
```

**Multi-node — joining servers:**

```yaml
# Per-host in inventory:
k3s_private_ip: "10.208.183.2"
k3s_extra_args: "--server https://10.208.183.1:6443 --tls-san 10.208.183.2 --tls-san 203.0.113.20"
```

**With Cilium CNI (advanced networking):**

```yaml
k3s_extra_args: "--cluster-init --disable=traefik --disable-network-policy --flannel-backend=none"
```

**High pod density:**

```yaml
k3s_extra_args: "--cluster-init --kubelet-arg=max-pods=250"
```

For multi-node setups, use per-host variables in `inventory/hosts.yml` or separate host_vars files to give each node its
own `k3s_extra_args`.

### Enabling Rancher UI

[Rancher](https://rancher.com/) provides a web UI for managing your Kubernetes cluster. To enable it:

```yaml
# group_vars/all.yml
k3s_install_rancher: true
k3s_rancher_hostname: "rancher.example.com"
k3s_rancher_letsencrypt_email: "admin@example.com"
```

This automatically deploys cert-manager and Rancher as Helm charts via K3s auto-deploy. Make sure your DNS points
`k3s_rancher_hostname` to the server before running the playbook.

> **Rancher licensing notice:** Patch releases up to `.3` (e.g., `v2.10.0`–`v2.10.3`) are labeled
> *"Community and Prime"* — freely available. From `.4` onwards they are *"Prime version"* only and require a
> commercial subscription. Pin `k3s_rancher_version` to `.3` of your chosen minor version to stay on the free tier.
> See the [Rancher releases page](https://github.com/rancher/rancher/releases) for the exact label on each release.

### Security

- **k3s_token:** Use [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/) in production:
  `ansible-vault encrypt_string 'your-token' --name 'k3s_token'`
- **Private registry credentials:** Same recommendation — use Vault for `k3s_private_registry_password`
- The K3s binary is downloaded with SHA256 checksum verification

## Cluster Setup (Innenausbau)

After k3s is running, deploy the cluster-level services that every production cluster needs.

### What Gets Deployed

| Component | How | Purpose |
|---|---|---|
| Traefik | `HelmChartConfig` (patches k3s built-in) | DaemonSet + Gateway API support |
| cert-manager | `HelmChart` (deployed separately) | Automatic TLS via Let's Encrypt |
| local-path-provisioner | `HelmChartConfig` (patches k3s built-in) | `reclaimPolicy: Retain` |
| PriorityClass `customer` | manifest | Evict internal services before production workloads |

Traefik and local-path-provisioner are already bundled with k3s (v1.33.x ships Traefik v3.6.x). We patch them via `HelmChartConfig` — no need to disable or redeploy them.

The Hetzner setup (nodes + load balancer) is already configured to forward ports 80/443. Traefik runs as a DaemonSet with `hostPort: 80/443` — the LB forwards directly to each node's bound ports.

### Prerequisites

Add your email to `.cluster.env` (used for Let's Encrypt registration):

```bash
# In .cluster.env:
CERT_MANAGER_EMAIL="admin@example.com"
```

Works on existing clusters too — `HelmChartConfig` just patches the running Helm releases, no Ansible re-run needed.

### Apply

```bash
mise run cluster-setup:apply
```

This applies all components in order and waits for Traefik to be ready before applying cert-manager.

**Verify:**

```bash
export KUBECONFIG=server-setup/kubeconfig

kubectl get helmchart -A                      # traefik-gateway, cert-manager → status: deployed
kubectl get pods -n traefik-gateway           # DaemonSet pods running
kubectl get pods -n cert-manager              # cert-manager pods running
kubectl get clusterissuer                     # letsencrypt-prod, letsencrypt-staging
kubectl get storageclass                      # local-path (default), reclaimPolicy: Retain
kubectl get priorityclass customer            # value: 100
```

### Using TLS in Your Apps

Create a `Gateway` + `HTTPRoute` (Gateway API) and annotate it for cert-manager:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-app
  namespace: my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: traefik
  listeners:
    - name: websecure
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: my-app-tls   # cert-manager will create this Secret
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
    - name: my-app
      sectionName: websecure
  hostnames:
    - "my-app.example.com"
  rules:
    - backendRefs:
        - name: my-app-service
          port: 80
```

> **Tip:** Use `letsencrypt-staging` first to verify your setup (no rate limits, but untrusted cert), then switch to `letsencrypt-prod`.

### Optional: Upgrading to Cilium (Advanced Networking)

The default CNI is Flannel (k3s default). Cilium provides NetworkPolicy enforcement, Hubble observability, and `CiliumLocalRedirectPolicy` for proper client IP preservation (instead of hostPort).

**To switch from Flannel to Cilium:**

1. Update `k3s_extra_args` to disable Flannel and network policy:
   ```
   --disable=traefik --disable=local-storage --disable-network-policy --flannel-backend=none
   ```
2. Re-run Ansible: `mise run hetzner:ansible`
3. Install Cilium via Helm:
   ```bash
   helm repo add cilium https://helm.cilium.io/
   helm install cilium cilium/cilium --version <VERSION> \
     --namespace kube-system \
     --set kubeProxyReplacement=true \
     --set ipam.mode=kubernetes \
     --set hubble.relay.enabled=true \
     --set hubble.ui.enabled=true \
     --set localRedirectPolicy=true \
     --set operator.replicas=1   # for single-node clusters
   ```
4. Switch Traefik from `hostPort` to `ClusterIP` + add `CiliumLocalRedirectPolicy` per node IP (redirect node IP:80/443 → Traefik ClusterIP service). See [Cilium LocalRedirectPolicy docs](https://docs.cilium.io/en/stable/network/kubernetes/local-redirect-policy/) for the pattern.

---

## Operations

### Updating K3s

**Checklist:**

- [ ] Read release notes at [K3s releases](https://github.com/k3s-io/k3s/releases) and [Kubernetes changelog](https://kubernetes.io/releases/)
- [ ] Check for removed/deprecated APIs — update manifests before upgrading
- [ ] If using Cilium: check [Cilium K8s compatibility matrix](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) for the target k3s version
- [ ] Upgrade one minor version at a time (1.32 → 1.33), don't skip versions
- [ ] Update `K3S_VERSION` in `.cluster.env` and re-run: `mise run hetzner:ansible`
  - Ansible restarts K3s **one node at a time** (`throttle: 1`) — the cluster stays healthy
- [ ] Watch pods stabilise:
  ```bash
  kubectl get pods --all-namespaces -w
  kubectl get pods --all-namespaces | grep -v Running | grep -v Completed
  ```
- [ ] Restart Traefik DaemonSet if routing issues appear after upgrade:
  ```bash
  kubectl rollout restart daemonset -n traefik-gateway
  ```
- [ ] If pods are stuck in `CrashLoopBackOff`, delete them — controllers will recreate them:
  ```bash
  kubectl delete pod <pod-name> -n <namespace>
  ```
- [ ] If nodes are stuck after upgrade, reboot them one at a time
- [ ] Update `K3S_VERSION` in `group_vars/all.yml` to match the installed version (prevents accidental downgrade on next Ansible run)

**Rancher (if enabled):** Check the [support matrix](https://www.suse.com/suse-rancher/support-matrix/) for compatibility. Patch releases up to `.3` (e.g., `v2.12.3`) are free community editions; `.4`+ require a Rancher Prime subscription.

### Updating Cluster Components (Traefik, cert-manager, etc.)

**Checklist:**

- [ ] Check for new chart versions:
  ```bash
  helm repo add traefik https://traefik.github.io/charts && helm repo update
  helm search repo traefik/traefik --versions

  helm repo add jetstack https://charts.jetstack.io && helm repo update
  helm search repo jetstack/cert-manager --versions
  ```
- [ ] Read upgrade notes for each component (cert-manager: [upgrading docs](https://cert-manager.io/docs/releases/upgrading/))
- [ ] Update the chart version in the relevant `cluster-setup/*.yaml` file
- [ ] Re-apply: `mise run cluster-setup:apply`
- [ ] Watch pods stabilise: `kubectl get pods -n <namespace> -w`

### Updating Cilium (if using Cilium)

**Checklist:**

- [ ] Check that you are on the latest patch of your **current** Cilium minor version first:
  ```bash
  helm repo add cilium https://helm.cilium.io/ && helm repo update
  helm search repo cilium/cilium --versions | grep <current-minor>
  ```
- [ ] Check [Cilium K8s compatibility matrix](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) for target version
- [ ] Check [system requirements](https://docs.cilium.io/en/stable/operations/system_requirements/) (kernel version, Ubuntu version)
- [ ] Read [upgrade notes](https://docs.cilium.io/en/stable/operations/upgrade/) for breaking changes
- [ ] Run **preflight checks** before upgrading (validates node readiness):
  ```bash
  TARGETVERSION=<new-version>
  helm install cilium-preflight cilium/cilium --version $TARGETVERSION \
    --namespace=kube-system \
    --set preflight.enabled=true \
    --set agent=false \
    --set operator.enabled=false

  # READY must equal AVAILABLE must equal DESIRED
  kubectl get daemonset -n kube-system | grep cilium

  # Clean up preflight
  helm delete cilium-preflight --namespace=kube-system
  ```
- [ ] Run the upgrade (read current values first: `helm get values cilium -n kube-system`):
  ```bash
  helm upgrade cilium cilium/cilium --version $TARGETVERSION \
    --namespace=kube-system \
    --set kubeProxyReplacement=true \
    --set ipam.mode=kubernetes \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set localRedirectPolicy=true \
    --set operator.replicas=1   # single-node clusters only!
  ```
- [ ] Validate: `cilium status` → all green; `cilium connectivity test` → all passed
- [ ] Verify ingress still works end-to-end (HTTP + HTTPS request)
- [ ] If Cilium pods can't start after upgrade: reboot nodes one at a time

### Backup & Restore

When using `--cluster-init` (the default), K3s runs an embedded etcd database that stores all cluster state.
K3s automatically saves etcd snapshots to `/var/lib/rancher/k3s/server/db/snapshots/` (5 snapshots, every 12 hours).

**Manual snapshot** (requires `k3s_install_etcdctl: true`):

```bash
etcdctl snapshot save /tmp/etcd-backup.db
```

**Restoring from snapshot:**

```bash
# Stop K3s
systemctl stop k3s

# Restore the snapshot (resets the cluster to the snapshot state)
k3s server --cluster-reset --cluster-reset-restore-path=/path/to/snapshot.db

# Restart K3s
systemctl start k3s
```

**Recommendation:** Automate backups with a cron job or a backup tool (e.g., borgbackup) that regularly copies the
snapshots directory to offsite storage.

### CI/CD Integration

**Extracting kubeconfig** — to deploy from a CI/CD pipeline, copy the cluster's kubeconfig:

```bash
# On the server
cat /etc/rancher/k3s/k3s.yaml
```

Replace the `server: https://127.0.0.1:6443` URL with the server's reachable IP or hostname. Store it as a CI/CD
secret (e.g., `KUBECONFIG` file variable in GitLab CI, or a GitHub Actions secret).

```yaml
# Example GitLab CI usage
deploy:
  script:
    - export KUBECONFIG=$KUBECONFIG_K3S
    - kubectl apply -f manifests/
```

**Security tip:** Create a dedicated ServiceAccount with limited RBAC permissions for CI/CD instead of using the
cluster-admin kubeconfig in production.

**Private registry authentication** — if your CI/CD pipeline pushes images to a private registry, configure K3s to
pull from it using the `k3s_private_registry_*` variables (see [Optional Variables](#optional-variables)). This writes
`/etc/rancher/k3s/registries.yaml` which K3s uses for registry authentication.

## Troubleshooting

### "Too many open files"

This role already configures sysctl settings (`fs.inotify.max_user_instances`, `user.max_inotify_instances`) to prevent
this. If you still see the error, check process-level limits:

```bash
ulimit -n    # Should be high (1048576 is set by the K3s systemd unit)
```

### Node not joining the cluster (multi-node)

- Verify firewall ports between nodes: **6443/TCP**, **2379-2380/TCP**, **8472/UDP**, **10250/TCP**
- Check that the `--server` URL in `k3s_extra_args` points to the first node's **internal IP**
- Ensure all nodes use the same `k3s_token`
- Check K3s logs: `journalctl -u k3s -f`

### Certificate errors when using kubectl

If you see `x509: certificate is valid for ... not for ...`:

- Ensure `--tls-san` in `k3s_extra_args` includes every IP and hostname you use to access the API server
- After adding a new TLS SAN, restart K3s: `systemctl restart k3s`
- Copy the updated kubeconfig: `cat /etc/rancher/k3s/k3s.yaml`

## License

MIT
