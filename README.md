# K3s Standalone Boilerplate

<!-- TOC -->

* [K3s Standalone Boilerplate](#k3s-standalone-boilerplate)
    * [Prerequisites](#prerequisites)
    * [Quick Start with Hetzner Cloud](#quick-start-with-hetzner-cloud)
    * [Quick Start (manual)](#quick-start-manual)
    * [What Gets Installed](#what-gets-installed)
    * [Network Architecture](#network-architecture)
        * [Recommended: Nodes Behind a Load Balancer (private-only)](#recommended-nodes-behind-a-load-balancer-private-only)
        * [Alternative: Load Balancer + Public IPs for SSH](#alternative-load-balancer--public-ips-for-ssh)
        * [Key K3s Network Flags](#key-k3s-network-flags)
    * [Firewall Rules](#firewall-rules)
    * [Configuration Reference](#configuration-reference)
        * [Required Variables](#required-variables)
        * [Optional Variables](#optional-variables)
        * [`k3s_extra_args` — Common Patterns](#k3s_extra_args--common-patterns)
        * [Enabling Rancher UI](#enabling-rancher-ui)
        * [Security](#security)
    * [`.cluster.env` Reference](#clusterenv-reference)
    * [Cluster Setup](#cluster-setup)
        * [What Gets Deployed](#what-gets-deployed)
        * [Prerequisites](#prerequisites-1)
        * [Apply](#apply)
        * [Using TLS in Your Apps](#using-tls-in-your-apps)
        * [Cilium CNI](#cilium-cni)
    * [Operations](#operations)
        * [Updating K3s](#updating-k3s)
        * [Updating Cluster Components (Traefik, cert-manager, etc.)](#updating-cluster-components-traefik-cert-manager-etc)
        * [Updating Cilium](#updating-cilium)
        * [Backup & Restore](#backup--restore)
        * [CI/CD Integration](#cicd-integration)
    * [Troubleshooting](#troubleshooting)
        * ["Too many open files"](#too-many-open-files)
        * [Node not joining the cluster (multi-node)](#node-not-joining-the-cluster-multi-node)
        * [Certificate errors when using kubectl](#certificate-errors-when-using-kubectl)
    * [Database Operator](#database-operator)
        * [How It Works](#how-it-works)
        * [Installing a Database Server on the Host](#installing-a-database-server-on-the-host)
        * [Setup](#setup)
            * [1. Deploy the operator](#1-deploy-the-operator)
            * [2. Register a database server](#2-register-a-database-server)
            * [3. Create a database](#3-create-a-database)
            * [4. Use credentials in your app](#4-use-credentials-in-your-app)
        * [Local development](#local-development)
    * [OneContainerOnePort Operator](#onecontaineroneport-operator)
        * [How It Works](#how-it-works-1)
        * [Setup](#setup-1)
            * [1. Deploy the operator](#1-deploy-the-operator-1)
            * [2. Deploy an app](#2-deploy-an-app)
            * [3. Spec reference](#3-spec-reference)
            * [4. Domain aliases with redirects](#4-domain-aliases-with-redirects)
            * [5. Redis](#5-redis)
        * [Local development](#local-development-1)
    * [License](#license)

<!-- TOC -->

Ansible-based setup for installing [K3s](https://k3s.io) (lightweight Kubernetes) on a single Linux server. Extracted
from a production setup running for 5+ years on bare metal at [Sandstorm](https://sandstorm.de).

This boilerplate is designed for small teams running Kubernetes without a dedicated DevOps department.

## Prerequisites

- **Server:** Linux (Ubuntu 22.04+ LTS or Debian 12+ recommended), x86_64 architecture
- **Access:** SSH root access to the server
- **Local:** [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) installed on your machine (
  `pip install ansible`)
- **Local:** [mise](https://mise.jdx.dev/) for running tasks and managing tool versions — install with:
  ```bash
  curl https://mise.run | sh
  # then add to your shell profile as instructed, e.g.:
  echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
  ```
  `mise` is used throughout this repo to run setup tasks, manage the Hetzner infrastructure, deploy cluster
  components, and wrap `kubectl`. Run `mise install` once in the repo root to install pinned tool versions (
  `gum`, `hcloud`, `jq`, etc.).

## Quick Start with Hetzner Cloud

We run our own clusters on [Hetzner](https://www.hetzner.com/) — we're happy long-time customers, not affiliated.
The `mise` tasks in this repo automate the full setup: creating servers, load balancer, firewall, and generating the
Ansible inventory from real IPs.

**Prerequisites:** `mise` installed locally (see [Prerequisites](#prerequisites)), an active Hetzner Cloud project
with an API token configured in the `hcloud` CLI (`hcloud context create my-project`), and an SSH key uploaded to
the project.

```bash
# 1. Install tools (gum, hcloud CLI, jq)
mise install

# 2. Interactive config — select context, SSH key, server type, location
mise run hetzner:setup

# 3. Create Hetzner infrastructure (network, firewall, server, load balancer)
mise run hetzner:create

# 4. Install k3s via Ansible
mise run hetzner:ansible

# 5. Install Cilium CNI (required before cluster-setup:apply)
mise run cluster-setup:cilium

# 6. Deploy cluster services (Traefik, cert-manager, storage, priority classes)
mise run cluster-setup:apply

# 7. Deploy operators (onecontaineroneport + database)
mise run cluster-setup:operators

# --- Optional: deploy demo apps (uses *.BASE_DOMAIN wildcard DNS) ---

# 8. Deploy Excalidraw (collaborative whiteboard)
mise run demos:excalidraw
mise run demos:neos

# --- Optional: add a second node ---

# 9a. Create second server on Hetzner + regenerate inventory
mise run hetzner:add-node

# 9b. Install k3s on the new node only
mise run hetzner:ansible -- --limit <PREFIX>-node-2

# 9c. Re-apply cluster-setup to create CLRP for the new node
mise run cluster-setup:apply

# Tear down servers (preserves LB, IPs, network, firewall for rebuild)
mise run hetzner:destroy

# Full teardown (deletes everything including IPs — DNS will break)
mise run hetzner:destroy --full
```

After `mise r hetzner:ansible` completes, the playbook automatically writes a `kubeconfig` file into `server-setup/`
with the correct server address. Connect with:

```bash
mise run kubectl get nodes
```

This automatically uses the correct kubeconfig. Alternatively, set it manually:

```bash
export KUBECONFIG=server-setup/kubeconfig
kubectl get nodes
```

> **Note:** The kubeconfig grants cluster-admin access — store it securely and never commit it to version control.

> **What gets created:** a private network (10.208.183.0/24), a firewall allowing SSH/HTTP/HTTPS, a Hetzner Primary IP
> (stable across server rebuilds), a server using that Primary IP, and a load balancer forwarding ports 80/443 to the
> node via the private network. Config is persisted in `.cluster.env` (gitignored). Ansible inventory and group\_vars
> are generated automatically. `mise run hetzner:destroy` only deletes servers — the LB, Primary IPs, network, and
> firewall are preserved so DNS stays stable. Use `-- --full` for complete teardown.

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
mise run kubectl get nodes
```

Or manually:

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
- **Cilium CNI** via `mise run cluster-setup:cilium` (required, before cluster-setup:apply)
- **Rancher UI** via `mise run cluster-setup:rancher` (optional, post-cluster)

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
  and injects `--node-ip` into the k3s service. `--node-ip` controls inter-node communication, etcd peer
  addresses, and CNI overlay routing. With Cilium (`--flannel-backend=none`), only `--node-ip` is injected
  (no `--flannel-iface` needed — Cilium picks up the correct interface via the node IP).
- `--tls-san <IP_OR_HOSTNAME>` (in `k3s_extra_args`) — adds additional IPs/hostnames to the API server TLS
  certificate (add one for every IP or hostname you'll use to reach the API server)

See the [`k3s_extra_args` examples](#k3s_extra_args--common-patterns) below for concrete configurations.

## Firewall Rules

K3s manages its own iptables rules for pod networking. You only need to configure your **host-level or provider-level
firewall** (Hetzner Firewall, cloud security groups, or `ufw`/`iptables` on the host).

**Inter-node ports (internal network only):**

| Port      | Protocol | Purpose                                                     |
|-----------|----------|-------------------------------------------------------------|
| 2379-2380 | TCP      | etcd (embedded, when using `--cluster-init`)                |
| 10250     | TCP      | Kubelet metrics                                             |
| 8472      | UDP      | VXLAN overlay (Cilium default tunnel mode, inter-node pods) |

**Public-facing ports:**

| Port | Protocol | Purpose                                                                                |
|------|----------|----------------------------------------------------------------------------------------|
| 80   | TCP      | HTTP ingress traffic                                                                   |
| 443  | TCP      | HTTPS ingress traffic                                                                  |
| 6443 | TCP      | **Kubernetes API server** (`kubectl` access) — **publicly exposed, see warning below** |

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

| Variable                        | Default                                                            | Description                                                                                            |
|---------------------------------|--------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| `k3s_mode`                      | `"server"`                                                         | `"server"` (control plane + worker) or `"agent"` (worker only)                                         |
| `k3s_private_ip`                | —                                                                  | Private IP of this node; auto-injects `--node-ip` (always) and `--flannel-iface` (when Flannel active) |
| `k3s_extra_args`                | `"--cluster-init --disable-network-policy --flannel-backend=none"` | Additional K3s CLI arguments (see below)                                                               |
| `k3s_install_etcdctl`           | `true`                                                             | Install etcdctl debugging tool                                                                         |
| `etcdctl_version`               | `"v3.5.0"`                                                         | etcdctl version                                                                                        |
| `k3s_private_registry_host`     | —                                                                  | Private Docker registry hostname                                                                       |
| `k3s_private_registry_username` | —                                                                  | Registry username                                                                                      |
| `k3s_private_registry_password` | —                                                                  | Registry password                                                                                      |
| `systemd_dir`                   | `"/etc/systemd/system"`                                            | Path for systemd unit files                                                                            |

### `k3s_extra_args` — Common Patterns

This is the main knob for configuring your cluster. It maps directly to K3s CLI flags.

**`--disable-network-policy`:** K3s ships with a built-in network policy controller. This flag disables it because
Cilium enforces NetworkPolicy natively via eBPF — running both would cause conflicts. Always include this flag when
using Cilium (i.e., whenever `--flannel-backend=none` is set).

**Single node (default — with Cilium CNI):**

```yaml
k3s_extra_args: "--cluster-init --disable-network-policy --flannel-backend=none"
```

**Multi-node — first server (initializes the cluster):**

```yaml
# Per-host in inventory (--node-ip injected automatically when k3s_private_ip is set):
k3s_private_ip: "10.208.183.1"
k3s_extra_args: "--cluster-init --disable-network-policy --flannel-backend=none --tls-san 10.208.183.1 --tls-san 203.0.113.10"
```

**Multi-node — joining servers:**

```yaml
# Per-host in inventory:
k3s_private_ip: "10.208.183.2"
k3s_extra_args: "--server https://10.208.183.1:6443 --disable-network-policy --flannel-backend=none --tls-san 10.208.183.2 --tls-san 203.0.113.20"
```

**High pod density:**

```yaml
k3s_extra_args: "--cluster-init --kubelet-arg=max-pods=250"
```

For multi-node setups, use per-host variables in `inventory/hosts.yml` or separate host_vars files to give each node its
own `k3s_extra_args`.

### Enabling Rancher UI

[Rancher](https://rancher.com/) provides a web UI for managing your Kubernetes cluster. It is deployed as an optional
post-cluster step after cert-manager and ClusterIssuers are running.

If `BASE_DOMAIN` is set, Rancher defaults to `rancher.${BASE_DOMAIN}`. To override, set `RANCHER_HOSTNAME` explicitly in
`.cluster.env`:

```bash
RANCHER_HOSTNAME="rancher.example.com"
```

Run `cluster-setup:apply` first (if not done already), then:

```bash
mise run cluster-setup:rancher
```

This applies `cluster-setup/50_rancher.yaml` which deploys Rancher via the K3s Helm controller. TLS is handled
automatically by cert-manager using the `letsencrypt-prod` ClusterIssuer.

> **Rancher licensing notice:** Patch releases up to `.3` (e.g., `v2.12.0`–`v2.12.3`) are labeled
> *"Community and Prime"* — freely available. From `.4` onwards they are *"Prime version"* only and require a
> commercial subscription. Pin the version in `cluster-setup/50_rancher.yaml` to `.3` of your chosen minor version to
> stay on the free tier.
> See the [Rancher releases page](https://github.com/rancher/rancher/releases) for the exact label on each release.

### Security

- **k3s_token:** Use [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/) in production:
  `ansible-vault encrypt_string 'your-token' --name 'k3s_token'`
- **Private registry credentials:** Same recommendation — use Vault for `k3s_private_registry_password`
- The K3s binary is downloaded with SHA256 checksum verification

## `.cluster.env` Reference

`.cluster.env` is the central config file for all `mise` tasks. It is gitignored. Copy `.cluster.env.example` to
`.cluster.env` and fill in your values, or let `mise run hetzner:setup` generate it interactively.

| Variable             | Required | Description                                                                                                                                                                                                                                                   |
|----------------------|----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `HCLOUD_CONTEXT`     | Hetzner  | Hetzner Cloud CLI context (`hcloud context create <name>`)                                                                                                                                                                                                    |
| `CLUSTER_PREFIX`     | Hetzner  | Name prefix for all Hetzner resources (servers, LB, firewall, network)                                                                                                                                                                                        |
| `SSH_KEY_NAME`       | Hetzner  | Name of the SSH key uploaded to Hetzner Cloud                                                                                                                                                                                                                 |
| `SERVER_TYPE`        | Hetzner  | Hetzner server type (e.g. `cx22`, `cx32`)                                                                                                                                                                                                                     |
| `LOCATION`           | Hetzner  | Hetzner datacenter location (e.g. `nbg1`, `fsn1`, `hel1`)                                                                                                                                                                                                     |
| `OS_IMAGE`           | Hetzner  | OS image to use (e.g. `ubuntu-24.04`)                                                                                                                                                                                                                         |
| `K3S_VERSION`        | yes      | K3s release tag (e.g. `v1.33.6+k3s1`). Also set in `group_vars/all.yml` to keep Ansible in sync.                                                                                                                                                              |
| `K3S_TOKEN`          | yes      | Cluster shared secret. Generate with `openssl rand -hex 32`.                                                                                                                                                                                                  |
| `BASE_DOMAIN`        | yes      | Wildcard base domain for cluster apps. Set up a DNS wildcard: `*.BASE_DOMAIN → load balancer IP`. Apps deployed via `OneContainerOnePort` or demos are reachable at `<app>.BASE_DOMAIN`. Also used as the default domain for Rancher (`rancher.BASE_DOMAIN`). |
| `CERT_MANAGER_EMAIL` | yes      | Email address for Let's Encrypt certificate registration (used by cert-manager).                                                                                                                                                                              |
| `CILIUM_VERSION`     | yes      | Cilium Helm chart version to install (e.g. `1.18.5`).                                                                                                                                                                                                         |
| `RANCHER_HOSTNAME`   | no       | Override the Rancher UI hostname. Defaults to `rancher.${BASE_DOMAIN}` if unset.                                                                                                                                                                              |
| `MARIADB_ENABLED`    | no       | Set to `"true"` to install MariaDB on the host via Ansible (see [Installing a Database Server on the Host](#installing-a-database-server-on-the-host)).                                                                                                       |
| `POSTGRES_ENABLED`   | no       | Set to `"true"` to install PostgreSQL on the host via Ansible (see [Installing a Database Server on the Host](#installing-a-database-server-on-the-host)).                                                                                                    |

## Cluster Setup

After k3s is running, deploy the cluster-level services that every production cluster needs.

### What Gets Deployed

| Component                | How                                      | Purpose                                             |
|--------------------------|------------------------------------------|-----------------------------------------------------|
| Traefik                  | `HelmChartConfig` (patches k3s built-in) | DaemonSet + Gateway API support                     |
| cert-manager             | `HelmChart` (deployed separately)        | Automatic TLS via Let's Encrypt                     |
| local-path-provisioner   | `HelmChartConfig` (patches k3s built-in) | `reclaimPolicy: Retain`                             |
| PriorityClass `customer` | manifest                                 | Evict internal services before production workloads |

Traefik and local-path-provisioner are already bundled with k3s (v1.33.x ships Traefik v3.6.x). We patch them via
`HelmChartConfig` — no need to disable or redeploy them.

The Hetzner setup (nodes + load balancer) is already configured to forward ports 80/443. Traefik runs as a ClusterIP
DaemonSet — `CiliumLocalRedirectPolicy` intercepts traffic arriving at each node's IP on port 80/443 and redirects it to
the local Traefik pod via eBPF (no hostPort, client IPs preserved).

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

> **Tip:** Use `letsencrypt-staging` first to verify your setup (no rate limits, but untrusted cert), then switch to
`letsencrypt-prod`.

### Cilium CNI

This boilerplate uses [Cilium](https://cilium.io/) as the default CNI. Flannel (the k3s default) is disabled.

**Why Cilium?**

- **eBPF-based data plane** — all packet processing happens in the kernel via eBPF programs, bypassing iptables chains
  entirely. Lower latency, higher throughput, and CPU savings at scale.
- **Full kube-proxy replacement** — Cilium handles service routing, load balancing, and NodePort/hostPort via eBPF
  instead of iptables. No kube-proxy sidecar needed.
- **`CiliumLocalRedirectPolicy`** — redirects traffic arriving at a node's IP directly to a local pod via eBPF, without
  SNAT. This is how Traefik receives traffic from the load balancer while preserving real client IPs.
- **NetworkPolicy enforcement** — Cilium enforces Kubernetes NetworkPolicy natively via eBPF (k3s's built-in network
  policy controller is disabled via `--disable-network-policy`).
- **Hubble observability** — built-in network flow visibility and UI via `hubble relay` and `hubble ui`.

**servicelb note:** `--disable=servicelb` is intentionally NOT set. Disabling k3s's built-in load balancer controller (
servicelb) breaks the Rancher management UI. servicelb is kept running but sits idle — simply avoid creating
`type: LoadBalancer` services and there is no conflict with `CiliumLocalRedirectPolicy`.

**Install:**

```bash
# Set version in .cluster.env:
CILIUM_VERSION="1.18.5"

# Run before cluster-setup:apply:
mise run cluster-setup:cilium
```

This runs `helm upgrade --install` with: kube-proxy replacement, `ipam.mode=kubernetes`, Hubble relay + UI,
`localRedirectPolicy=true`, `operator.replicas=1` (single-node).

`cluster-setup:apply` then creates a `CiliumLocalRedirectPolicy` per node (see
`cluster-setup/25_cilium_traefik_redirect.yaml`) that routes the node's IP:80/443 to the local Traefik pod.

**Verify:**

```bash
cilium status                                   # all components green
kubectl get ciliumlocalredirectpolicy -A        # one entry per node
kubectl get pods -n kube-system | grep cilium   # cilium + cilium-operator running
```

**Hubble UI:** Access the network observability dashboard locally via port-forward:

```bash
mise run hubble-ui    # opens http://localhost:12000
```

---

## Operations

### Updating K3s

**Checklist:**

- [ ] Read release notes at [K3s releases](https://github.com/k3s-io/k3s/releases)
  and [Kubernetes changelog](https://kubernetes.io/releases/)
- [ ] Check for removed/deprecated APIs — update manifests before upgrading
- [ ] Check [Cilium K8s compatibility matrix](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) for
  the target k3s version
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
- [ ] Update `K3S_VERSION` in `group_vars/all.yml` to match the installed version (prevents accidental downgrade on next
  Ansible run)

**Rancher (if deployed):** Check the [support matrix](https://www.suse.com/suse-rancher/support-matrix/) for
compatibility. Update the version in `cluster-setup/50_rancher.yaml` and re-run `mise run cluster-setup:rancher`. Patch
releases up to `.3` (e.g., `v2.12.3`) are free community editions; `.4`+ require a Rancher Prime subscription.

### Updating Cluster Components (Traefik, cert-manager, etc.)

**Checklist:**

- [ ] Check for new chart versions:
  ```bash
  helm repo add traefik https://traefik.github.io/charts && helm repo update
  helm search repo traefik/traefik --versions

  helm repo add jetstack https://charts.jetstack.io && helm repo update
  helm search repo jetstack/cert-manager --versions
  ```
- [ ] Read upgrade notes for each component (
  cert-manager: [upgrading docs](https://cert-manager.io/docs/releases/upgrading/))
- [ ] Update the chart version in the relevant `cluster-setup/*.yaml` file
- [ ] Re-apply: `mise run cluster-setup:apply`
- [ ] Watch pods stabilise: `kubectl get pods -n <namespace> -w`

### Updating Cilium

**Checklist:**

- [ ] Check that you are on the latest patch of your **current** Cilium minor version first:
  ```bash
  helm repo add cilium https://helm.cilium.io/ && helm repo update
  helm search repo cilium/cilium --versions | grep <current-minor>
  ```
- [ ] Check [Cilium K8s compatibility matrix](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) for
  target version
- [ ] Check [system requirements](https://docs.cilium.io/en/stable/operations/system_requirements/) (kernel version,
  Ubuntu version)
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
- [ ] Update `CILIUM_VERSION` in `.cluster.env` and re-run:
  ```bash
  mise run cluster-setup:cilium
  ```
  This runs `helm upgrade --install` with the same values used at install time. Read current values first if you've
  customised them: `helm get values cilium -n kube-system`.
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

## Database Operator

The `operator-database/` directory contains a Kubernetes operator that provisions databases on pre-existing MySQL,
PostgreSQL, and ClickHouse servers. It creates isolated databases with per-application credentials and exposes
connection details as ConfigMaps and Secrets.

Built with [Operator SDK](https://sdk.operatorframework.io/) (Ansible).

### How It Works

The operator manages two Custom Resources:

- **`DatabaseServer`** — admin-level config for a database server (host, port, admin credentials). Created once per
  server in the operator's namespace.
- **`Database`** — user-facing resource. References a `DatabaseServer` by name. When created, the operator:
    1. Looks up the `DatabaseServer` and its admin password Secret (both in the operator namespace)
    2. Generates a random password and stores it in a **Secret** (named after the Database CR, in the CR's namespace)
       with key `DB_PASSWORD`
    3. Creates a **ConfigMap** (same name) with keys `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_NAME`
    4. Provisions the actual database and user on the server (PostgreSQL, MariaDB, or ClickHouse)

Database and user names are derived as `{namespace}_{name}` (overridable via `spec.databaseNameOverride`).

### Installing a Database Server on the Host

The Database Operator connects to existing database servers — it does not install them. You need at least one
database server reachable from inside the cluster before the operator can provision databases.

The Ansible playbook includes optional `mariadb` and `postgres` roles that install MariaDB or PostgreSQL **directly
on the K3s host** and automatically register them as `DatabaseServer` CRDs with the operator.

> **Important:** Deploy the operator first (`mise run cluster-setup:operators`), then run Ansible to install the
> database server. The registration step creates the `DatabaseServer` CRD — this requires the operator's CRDs to
> already be installed in the cluster.

**Enable in `.cluster.env`:**

```bash
MARIADB_ENABLED="true"
POSTGRES_ENABLED="true"
```

**Set passwords in `group_vars/all.yml`** (use Ansible Vault in production):

```yaml
# MariaDB
mariadb_enabled: true
mariadb_root_password: "your-secure-password"   # ansible-vault encrypt_string recommended
mariadb_version: "10.11"
mariadb_operator_server_name: "mariadb1"        # name of the DatabaseServer CRD

# PostgreSQL
postgres_enabled: true
postgres_root_password: "your-secure-password"  # ansible-vault encrypt_string recommended
postgres_version: "17"
postgres_operator_server_name: "postgres1"      # name of the DatabaseServer CRD
```

**Re-run Ansible** after deploying the operator:

```bash
mise run hetzner:ansible
# or manually:
ansible-playbook server-setup/playbook.yml
```

This installs the database server, configures it to accept connections from the cluster's internal network, and
creates the `DatabaseServer` CRD in the `operator-database-system` namespace — ready for apps to use.

### Setup

#### 1. Deploy the operator

The easiest way to deploy both operators at once:

```bash
mise run cluster-setup:operators
```

This installs CRDs and deploys the controller using the pre-built image from
`ghcr.io/sandstorm/kubernetesblueprint/operator-database:latest`.

<details>
<summary>Manual build & deploy (custom image)</summary>

```bash
cd operator-database

# Build the image
make docker-build IMG=your-registry.com/operator-database:v0.0.1
make docker-push IMG=your-registry.com/operator-database:v0.0.1

# Install CRDs and deploy the operator
make install
make deploy IMG=your-registry.com/operator-database:v0.0.1
```

</details>

The operator runs in the `operator-database-system` namespace.

#### 2. Register a database server

Create a `DatabaseServer` CR and its admin password Secret **in the operator namespace**:

```bash
# Create the admin password secret
kubectl -n operator-database-system create secret generic postgres1 \
  --from-literal='admin_password=YOUR_ADMIN_PASSWORD'

# Create the DatabaseServer CR
cat <<EOF | kubectl -n operator-database-system apply -f -
apiVersion: k8s.sandstorm.de/v1alpha1
kind: DatabaseServer
metadata:
  name: postgres1
spec:
  type: postgres
  host: postgres.example.com
  port: 5432
  adminUser: operator-database-admin
  adminPasswordSecret: postgres1
EOF
```

Supported `type` values: `postgres`, `mariadb`, `clickhouse`.

#### 3. Create a database

In any namespace, create a `Database` CR referencing the server:

```yaml
apiVersion: k8s.sandstorm.de/v1alpha1
kind: Database
metadata:
  name: my-app-db
  namespace: my-app
spec:
  databaseServer: postgres1
```

The operator will create:

- **Secret** `my-app-db` in namespace `my-app` with key `DB_PASSWORD`
- **ConfigMap** `my-app-db` in namespace `my-app` with keys `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_NAME`
- A PostgreSQL database `my_app_my_app_db` with user `my_app_my_app_db` on the server

#### 4. Use credentials in your app

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  template:
    spec:
      containers:
        - name: my-app
          envFrom:
            - configMapRef:
                name: my-app-db
            - secretRef:
                name: my-app-db
```

This injects `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_NAME`, and `DB_PASSWORD` as environment variables.

### Local development

```bash
cd operator-database

# Install CRDs into the current cluster
make install

# Run the operator locally (requires KUBECONFIG and POD_NAMESPACE)
export POD_NAMESPACE=operator-database-system
make run
```

## OneContainerOnePort Operator

The `operator-onecontaineroneport/` directory contains a Kubernetes operator that deploys single-container applications
with Gateway API routing, automatic TLS, persistent volumes, and optional Redis. One Custom Resource = one running app.

Built with [Operator SDK](https://sdk.operatorframework.io/) (Helm).

### How It Works

The operator manages a single Custom Resource:

- **`OneContainerOnePort`** — defines everything needed to run a containerized app: image, hostnames, environment,
  volumes, health checks, and optional Redis. When created, the operator deploys:
    - **Deployment** — single container with configurable replicas, health probes, env vars, and volume mounts
    - **Service** — port 80 → container port
    - **Gateway + HTTPRoutes** — TLS termination via cert-manager, domain alias 301 redirects, HTTP→HTTPS redirects (
      hostnames chunked into groups of 16 per Gateway API limit)
    - **ConfigMap** — from `env` key-value pairs
    - **PersistentVolumeClaims** — auto-created from `volumes` spec
    - **NetworkPolicy** — allows ingress from Traefik and same-app pods only
    - **Redis** (optional) — transient or persistent Redis deployment with service, network policy, and PVC

All resource names are derived from the CR name (not namespace), so **multiple apps can coexist in the same namespace**.

### Setup

#### 1. Deploy the operator

The easiest way to deploy both operators at once:

```bash
mise run cluster-setup:operators
```

This installs CRDs and deploys the controller using the pre-built image from
`ghcr.io/sandstorm/kubernetesblueprint/operator-onecontaineroneport:latest`.

<details>
<summary>Manual build & deploy (custom image)</summary>

```bash
cd operator-onecontaineroneport

# Build the image
make docker-build IMG=your-registry.com/operator-onecontaineroneport:v0.0.1
make docker-push IMG=your-registry.com/operator-onecontaineroneport:v0.0.1

# Install CRDs and deploy the operator
make install
make deploy IMG=your-registry.com/operator-onecontaineroneport:v0.0.1
```

</details>

The operator runs in the `operator-onecontaineroneport-system` namespace.

#### 2. Deploy an app

Create a namespace and a `OneContainerOnePort` CR:

```yaml
apiVersion: k8s.sandstorm.de/v1alpha1
kind: OneContainerOnePort
metadata:
  name: hello-world
  namespace: my-apps
spec:
  image: nginx:latest
  port: 80
  hostNames:
    hello-world.example.com: [ ]
  stagingCertificates: true
  env:
    MESSAGE: "Hello World"
  volumes:
    - name: data
      mountPath: /usr/share/nginx/html
      storage: 100Mi
  healthChecks:
    readinessProbe:
      enabled: true
    startupProbe:
      enabled: true
```

This creates a Deployment, Service, Gateway, HTTPRoute, ConfigMap, PVC, and NetworkPolicy — all named with the
`hello-world` prefix.

#### 3. Spec reference

| Field                          | Type   | Default      | Description                                                    |
|--------------------------------|--------|--------------|----------------------------------------------------------------|
| `image`                        | string | required     | Container image                                                |
| `port`                         | int    | `8080`       | Container listening port                                       |
| `replicas`                     | int    | `1`          | Number of replicas                                             |
| `hostNames`                    | map    | `{}`         | Primary domain → alias domains (aliases get 301 redirects)     |
| `ssl`                          | bool   | `true`       | Enable TLS via cert-manager                                    |
| `stagingCertificates`          | bool   | `true`       | Use Let's Encrypt staging (`false` for production certs)       |
| `env`                          | map    | `{}`         | Environment variables (non-secret)                             |
| `envFromSecrets`               | list   | `[]`         | Secret names to mount as `envFrom`                             |
| `envFromConfigMaps`            | list   | `[]`         | ConfigMap names to mount as `envFrom`                          |
| `extraPodEnvInK8sFormat`       | list   | `[]`         | Advanced env vars (supports `valueFrom`, interpolation)        |
| `volumes`                      | list   | `[]`         | Persistent volumes: `{name, mountPath, storage}`               |
| `extraVolumesInK8sFormat`      | list   | `[]`         | Extra volumes in native K8s format                             |
| `extraVolumeMountsInK8sFormat` | list   | `[]`         | Extra volume mounts in native K8s format                       |
| `command`                      | list   | `[]`         | Entrypoint override                                            |
| `args`                         | list   | `[]`         | Arguments override                                             |
| `imagePullPolicy`              | string | `Always`     | `Always`, `IfNotPresent`, or `Never`                           |
| `redis`                        | string | `""`         | `"transient"`, `"persistent"`, or `""` (disabled)              |
| `stopped`                      | bool   | `false`      | Scale to 0 and remove routing, keep PVCs                       |
| `healthChecks`                 | object | all disabled | `readinessProbe`, `livenessProbe`, `startupProbe` (TCP socket) |

#### 4. Domain aliases with redirects

```yaml
spec:
  hostNames:
    myapp.example.com:
      - www.myapp.example.com
      - old-domain.com
```

Requests to `www.myapp.example.com` and `old-domain.com` are 301-redirected to `myapp.example.com`. All domains get TLS
certificates.

#### 5. Redis

```yaml
spec:
  redis: transient    # in-memory, cleared on redeploy
  # or
  redis: persistent   # appendonly with PVC (50Mi)
```

When enabled, `REDIS_HOST` and `REDIS_PORT` env vars are automatically injected into the app container, pointing to the
per-app Redis service.

### Local development

```bash
cd operator-onecontaineroneport

# Install CRDs into the current cluster
make install

# Run the operator locally (requires KUBECONFIG)
make run
```

## License

MIT
