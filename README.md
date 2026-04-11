# K3s Standalone Boilerplate

Ansible-based setup for installing [K3s](https://k3s.io) (lightweight Kubernetes) on a single Linux server. Extracted
from a production setup running for 5+ years on bare metal at [Sandstorm](https://sandstorm.de).

This boilerplate is designed for small teams running Kubernetes without a dedicated DevOps department.

## Prerequisites

- **Server:** Linux (Ubuntu 22.04+ or Debian 12+ recommended), x86_64 architecture
- **Access:** SSH root access to the server
- **Local:** [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) installed on your machine (
  `pip install ansible`)

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

## License

MIT
