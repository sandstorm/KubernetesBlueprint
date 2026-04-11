# K3s Standalone Boilerplate

Ansible-based setup for installing [K3s](https://k3s.io) (lightweight Kubernetes) on a single Linux server. Extracted
from a production setup running for 5+ years on bare metal at [Sandstorm](https://sandstorm.de).

This boilerplate is designed for small teams running Kubernetes without a dedicated DevOps department.

## Prerequisites

- **Server:** Linux (Ubuntu 22.04+ LTS or Debian 12+ recommended), x86_64 architecture
- **Access:** SSH root access to the server
- **Local:** [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) installed on your machine (
  `pip install ansible`)

## Network Architecture

### Recommended: Nodes Behind a Load Balancer (private-only)

The recommended setup — even for a single node — is to place all K3s nodes on a **private network only** and route
internet traffic through an **external load balancer**. This is how our production clusters run.

**Why this matters:**

- **Security:** The K3s API server (6443), etcd (2379-2380), and kubelet (10250) are never exposed to the internet.
  No firewall misconfiguration can accidentally open them.
- **Scalability:** Adding nodes later is trivial — just add them to the internal network. The load balancer handles
  traffic distribution. You can scale from 1 to N nodes without changing your network architecture.
- **Flexibility:** You can swap nodes, update one at a time, or migrate to different hardware — the load balancer IP
  stays the same, so DNS and clients don't need to change.

```
              Internet
                 │
         ┌───────┴────────┐
         │ Load Balancer  │
         │ (Public IP)    │
         │ 80/443 → Nodes │
         └───────┬────────┘
                 │
     ┌───────────┼───────────┐
     │           │           │
┌────┴────┐  ┌───┴─────┐ ┌───┴─────┐
│ Node 1  │  │ Node 2  │ │ Node 3  │
│ private │  │ private │ │ private │
│ 10.0.0.1│  │ 10.0.0.2│ │ 10.0.0.3│
└─────────┘  └─────────┘ └─────────┘
         Internal Network
        (e.g., 10.0.0.0/24)
```

This works with a single node too — the load balancer simply forwards to one backend:

```
              Internet
                 │
         ┌───────┴────────┐
         │ Load Balancer  │
         │ (Public IP)    │
         │ 80/443 → Node  │
         └───────┬────────┘
                 │
         ┌───────┴────────┐
         │ Single Node    │
         │ private only   │
         │ 10.0.0.1       │
         └────────────────┘
```

Most hosting providers offer load balancers that work with private networks:

- **Hetzner:** Cloud Load Balancer + Cloud Network or vSwitch
- **Cloud providers (AWS, GCP, Azure, DO):** Network Load Balancer + VPC
- **Bare metal:** HAProxy or nginx on a small dedicated VM, or a hardware load balancer

The load balancer forwards **port 80 and 443** to the nodes' internal IPs. SSH access goes through a bastion host or
VPN — not through a public IP on the K3s nodes themselves. **You might manually need to configure a gateway for outbound network access.**

### Alternative: Load Balancer + Public IPs for SSH

Same as the recommended setup, but each node also gets a **public IP** for direct SSH access — no bastion host needed.
HTTP/HTTPS traffic still flows through the load balancer; the public IPs are only used for management access.

```
              Internet
                 │
         ┌───────┴────────┐
         │ Load Balancer  │
         │ (Public IP)    │
         │ 80/443 → Nodes │
         └───────┬────────┘
                 │
     ┌───────────┼───────────┐
     │           │           │
┌────┴────┐  ┌───┴─────┐ ┌───┴─────┐
│ Node 1  │  │ Node 2  │ │ Node 3  │
│ private │  │ private │ │ private │
│ 10.0.0.1│  │ 10.0.0.2│ │ 10.0.0.3│
│ public  │  │ public  │ │ public  │
│ 203.x.1 │  │ 203.x.2 │ │ 203.x.3 │
└─────────┘  └─────────┘ └─────────┘
         Internal Network
        (e.g., 10.0.0.0/24)
```

**Make sure you protect the public Node IP addresses with a firewall.**

### Key K3s Network Flags

Use these `k3s_extra_args` flags to control networking:

- `--node-ip <PRIVATE_IP>` — tells K3s which IP to advertise for inter-node communication
- `--flannel-iface <NIC>` — forces Flannel CNI to use the internal network interface (e.g., `ens20`)
- `--tls-san <IP_OR_HOSTNAME>` — adds additional IPs/hostnames to the API server TLS certificate

See the [`k3s_extra_args` examples](#k3s_extra_args--common-patterns) below for concrete configurations.

## IP Address Prerequisites

### Recommended: Private Network + Load Balancer

| What                    | Example           | Purpose                                                 |
|-------------------------|-------------------|---------------------------------------------------------|
| Private IP per node     | `10.0.0.1`        | All K3s communication (API, etcd, CNI overlay, ingress) |
| Internal NIC name       | `ens20`, `eth1`   | For `--flannel-iface` so CNI uses the right interface   |
| Load balancer public IP | `203.0.113.50`    | Single entry point for HTTP/HTTPS traffic               |
| DNS name                | `app.example.com` | Points to the load balancer IP                          |

You need a **shared internal network** between all nodes (and the load balancer). Most hosting providers offer this:

- **Hetzner:** vSwitch (VLAN) or Cloud Network
- **Cloud providers:** VPC / private network
- **Bare metal:** dedicated VLAN or direct cabling

SSH access: use a bastion/jump host on the same internal network, or a VPN (e.g., WireGuard).

### Alternative: Public IPs (no load balancer)

| What                | Example         | Purpose                                               |
|---------------------|-----------------|-------------------------------------------------------|
| Private IP per node | `10.0.0.1`      | Inter-node communication (API, etcd, CNI overlay)     |
| Public IP per node  | `203.0.113.10`  | Ingress traffic, SSH access, kubectl from outside     |
| Internal NIC name   | `ens20`, `eth1` | For `--flannel-iface` so CNI uses the right interface |

Optional: a **DNS name** pointing to the server (required if you enable Rancher with Let's Encrypt).

### TLS SANs

Add `--tls-san` for every IP or hostname you'll use to reach the API server. This ensures the K3s API certificate is
valid for both internal and external access. Example:

```yaml
# Node 1 (first server)
k3s_extra_args: "--cluster-init --node-ip 10.0.0.1 --tls-san 10.0.0.1 --tls-san 203.0.113.10 --flannel-iface ens20"

# Node 2 (joining server)
k3s_extra_args: "--server https://10.0.0.1:6443 --tls-san 10.0.0.2 --tls-san 203.0.113.20 --flannel-iface ens20"
```

## Firewall Rules

K3s manages its own iptables rules for pod networking. You only need to configure your **host-level or provider-level
firewall** (Hetzner Firewall, cloud security groups, or `ufw`/`iptables` on the host).

### Recommended Setup (private nodes + load balancer)

In this setup, nodes have **no public IP**. The only internet-facing component is the load balancer.

**Load balancer (public-facing):**

| Port | Protocol | Direction             | Purpose               |
|------|----------|-----------------------|-----------------------|
| 80   | TCP      | Internet → LB → Nodes | HTTP ingress traffic  |
| 443  | TCP      | Internet → LB → Nodes | HTTPS ingress traffic |

**Between nodes (internal network only — no internet exposure):**

| Port      | Protocol | Direction           | Purpose                                                        |
|-----------|----------|---------------------|----------------------------------------------------------------|
| 6443      | TCP      | Between nodes       | K3s API server                                                 |
| 2379-2380 | TCP      | Between servers     | etcd (embedded, when using `--cluster-init`)                   |
| 10250     | TCP      | Between nodes       | Kubelet metrics                                                |
| 8472      | UDP      | Between nodes       | VXLAN overlay (Flannel, K3s default CNI)                       |
| 51820     | UDP      | Between nodes       | WireGuard (only if using `--flannel-backend=wireguard-native`) |
| 22        | TCP      | Bastion/VPN → Nodes | SSH access                                                     |

Since nodes are on a private network, you can allow all traffic between nodes on the internal network and block
everything from the internet. This is the simplest and most secure firewall configuration.

### Alternative Setup (public IPs on nodes)

If nodes have public IPs, you must be more careful with firewall rules:

**Public-facing (restrict to what's needed):**

| Port | Protocol | Direction | Purpose                              |
|------|----------|-----------|--------------------------------------|
| 80   | TCP      | Inbound   | HTTP ingress traffic                 |
| 443  | TCP      | Inbound   | HTTPS ingress traffic                |
| 22   | TCP      | Inbound   | SSH access (or your custom SSH port) |

**Internal network only (never expose to internet):**

| Port      | Protocol | Direction       | Purpose                                                        |
|-----------|----------|-----------------|----------------------------------------------------------------|
| 6443      | TCP      | Between nodes   | K3s API server                                                 |
| 2379-2380 | TCP      | Between servers | etcd (embedded, when using `--cluster-init`)                   |
| 10250     | TCP      | Between nodes   | Kubelet metrics                                                |
| 8472      | UDP      | Between nodes   | VXLAN overlay (Flannel, K3s default CNI)                       |
| 51820     | UDP      | Between nodes   | WireGuard (only if using `--flannel-backend=wireguard-native`) |

**Important:** Ports 6443, 2379-2380, 8472, and 10250 must **never** be exposed to the internet. Use your hosting
provider's firewall or security groups to restrict them to the internal network only.

## Quick Start

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

After the playbook completes, SSH into the server and verify:

```bash
kubectl get nodes
```

## What Gets Installed

- **K3s binary** with checksum verification (downloaded from GitHub releases)
- **systemd service** for automatic start/restart
- **CLI tools:** `kubectl`, `crictl`, `ctr` (symlinked from K3s binary)
- **etcdctl** wrapper for debugging the embedded etcd database (optional)
- **Kernel tuning:** sysctl settings for large clusters and Elasticsearch workloads
- **Rancher UI** with cert-manager and Let's Encrypt (optional)

## Configuration Reference

### Required Variables

| Variable      | Description                                                                    | Example          |
|---------------|--------------------------------------------------------------------------------|------------------|
| `k3s_version` | K3s release tag from [GitHub releases](https://github.com/k3s-io/k3s/releases) | `"v1.33.6+k3s1"` |
| `k3s_token`   | Cluster shared secret. Generate with `openssl rand -hex 32`                    | `"a1b2c3..."`    |

### Optional Variables

| Variable                        | Default                 | Description                                                    |
|---------------------------------|-------------------------|----------------------------------------------------------------|
| `k3s_mode`                      | `"server"`              | `"server"` (control plane + worker) or `"agent"` (worker only) |
| `k3s_extra_args`                | `"--cluster-init"`      | Additional K3s CLI arguments (see below)                       |
| `k3s_install_rancher`           | `false`                 | Deploy Rancher UI + cert-manager                               |
| `k3s_rancher_hostname`          | —                       | Hostname for Rancher (required when Rancher enabled)           |
| `k3s_rancher_letsencrypt_email` | —                       | Email for Let's Encrypt (required when Rancher enabled)        |
| `k3s_rancher_version`           | `"2.12.3"`              | Rancher Helm chart version                                     |
| `k3s_certmanager_version`       | `"1.19.0"`              | cert-manager Helm chart version                                |
| `k3s_install_etcdctl`           | `true`                  | Install etcdctl debugging tool                                 |
| `etcdctl_version`               | `"v3.5.0"`              | etcdctl version                                                |
| `k3s_private_registry_host`     | —                       | Private Docker registry hostname                               |
| `k3s_private_registry_username` | —                       | Registry username                                              |
| `k3s_private_registry_password` | —                       | Registry password                                              |
| `systemd_dir`                   | `"/etc/systemd/system"` | Path for systemd unit files                                    |

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
k3s_extra_args: "--cluster-init --node-ip 10.0.0.1 --tls-san 10.0.0.1 --tls-san 203.0.113.10"
```

**Multi-node — joining servers:**

```yaml
k3s_extra_args: "--server https://10.0.0.1:6443 --tls-san 203.0.113.20"
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

## Enabling Rancher UI

[Rancher](https://rancher.com/) provides a web UI for managing your Kubernetes cluster. To enable it:

```yaml
# group_vars/all.yml
k3s_install_rancher: true
k3s_rancher_hostname: "rancher.example.com"
k3s_rancher_letsencrypt_email: "admin@example.com"
```

This automatically deploys cert-manager and Rancher as Helm charts via K3s auto-deploy. Make sure your DNS points
`k3s_rancher_hostname` to the server before running the playbook.

## Security Notes

- **k3s_token:** Use [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/) in production:
  `ansible-vault encrypt_string 'your-token' --name 'k3s_token'`
- **Private registry credentials:** Same recommendation — use Vault for `k3s_private_registry_password`
- The K3s binary is downloaded with SHA256 checksum verification

## Updating K3s

To update K3s to a new version:

1. Change `k3s_version` in `group_vars/all.yml` (find versions
   at [K3s releases](https://github.com/k3s-io/k3s/releases))
2. Re-run the playbook: `ansible-playbook playbook.yml`
3. The Ansible handler restarts K3s automatically. In multi-node setups, it restarts **one node at a time** (
   `throttle: 1`) to keep the cluster healthy.
4. Verify: `kubectl get nodes` — the version column should show the new version.

**Recommendation:** In multi-node setups, test the update on a staging cluster first. K3s supports upgrading one minor
version at a time (e.g., 1.32 → 1.33).

## Backup & Restore

When using `--cluster-init` (the default), K3s runs an embedded etcd database that stores all cluster state.

### Automatic Snapshots

K3s automatically saves etcd snapshots to `/var/lib/rancher/k3s/server/db/snapshots/`. By default, it keeps 5 snapshots
and creates a new one every 12 hours.

### Manual Snapshot

If this role installed etcdctl (`k3s_install_etcdctl: true`), you can create a snapshot manually:

```bash
etcdctl snapshot save /tmp/etcd-backup.db
```

### Restoring from Snapshot

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
