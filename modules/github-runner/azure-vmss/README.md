# GitHub Self-Hosted Runner on Azure (VMSS + Bastion)

Deploys a Linux VMSS that auto-registers as a [self-hosted GitHub Actions
runner](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)
against a repository, fronted by [Azure Bastion](https://learn.microsoft.com/azure/bastion/)
for SSH access. No public IPs on the runners themselves.

What this module creates (all in a freshly-created resource group):

- VNet (`10.0.0.0/16`) with two subnets: `snet-runners` (`10.0.1.0/24`) and
  `AzureBastionSubnet` (`10.0.2.0/26`)
- NSG on the runners subnet — inbound SSH only from `AzureBastionSubnet`,
  all other inbound denied; outbound to VNet + Internet
- Azure Bastion (`Standard` SKU) with native client tunneling enabled. Its
  public IP carries the `bastion_public_ip_tags` ipTags (default
  `FirstPartyUsage=/NonProd`)
- Linux VMSS (default `Standard_E32as_v4`, 1 TB Premium SSD) with
  cloud-init that installs Docker, a base toolchain (`git`, `git-lfs`,
  `python3` + `venv`/`pip`, `openssl`, `build-essential`, `jq`, `curl`,
  `wget`, `unzip`, `zip`, `rsync`, `xz-utils`, `zstd`) and the
  `actions/runner` agent, and registers each instance against the target repo

The [`azure-vmss-windows`](../azure-vmss-windows/) module can attach a
Windows pool to the same resource group, VNet and Bastion through the
`network` output (see [Shared network](#shared-network-with-a-windows-pool)).

The runner user (default `azureuser`) is granted passwordless `sudo`
via `/etc/sudoers.d/90-<user>-nopasswd` so CI jobs running on the
runner can do `sudo apt-get install …` / `sudo systemctl …` without
interactive prompts. The sudoers fragment is validated with
`visudo -c -f` before installation.

With `job_cleanup_enabled` (the default) the runner gets two job hooks in
`/opt/gh-runner/hooks`. The job-started hook takes ownership of the job
workspace, so root-owned files left by a previous container job cannot break
`actions/checkout`. The job-completed hook removes all Docker containers,
prunes unused networks and anonymous volumes, and deletes the workspace
contents. Both only act on a workspace strictly beneath the runner's `_work`
directory and log failures instead of failing the job. Docker-wide cleanup is
safe because each instance hosts exactly one runner.

The bootstrap is idempotent: re-applying with a new registration token
(VMSS `upgrade_mode = "Automatic"` rolls the new `custom_data` out, which
re-runs cloud-init via reimage and re-registers the runner with the
fresh token).

## Inputs

Required: `resource_group_name`, `github_repo`, `github_runner_token`,
`ssh_public_key`.

Common knobs (full list in [`vars.tf`](./vars.tf)):

| Variable          | Default              | Notes                                                                            |
| ----------------- | -------------------- | -------------------------------------------------------------------------------- |
| `location`        | `canadacentral`      | Any Azure region with Bastion Standard.                                          |
| `name_prefix`     | `ghrunner`           | Prepended to all resource names. Keep short.                                     |
| `instance_count`  | `2`                  | Manual scale-out — Azure adds more runners, each registers independently.        |
| `instance_sku`    | `Standard_E32as_v4`  | 32 vCPU / 256 GB RAM. Right-size for the workloads you'll run.                   |
| `os_disk_size_gb` | `1024`               | Premium SSD. Sized for Docker image layers + workspace data.                     |
| `runner_labels`   | `["self-hosted-azure"]` | Custom labels appended to the implicit `self-hosted, Linux, X64`.             |
| `runner_version`  | `2.338.2`            | actions/runner release tag.                                                      |
| `bastion_public_ip_tags` | `{ FirstPartyUsage = "/NonProd" }` | ipTags on the Bastion public IP. ipTags are immutable, so changing them (including the first apply after upgrading from a version without ipTags) **replaces the public IP and the Bastion host**. `{}` omits ipTags and adds the `hybrid-vm-migration-publicip-mustbefirstpartytagged` skip tags instead. |
| `extra_apt_packages` | `[]`              | Extra apt packages installed after the base toolchain.                           |
| `extra_bootstrap_script` | `""`          | Bash run as root after the packages and Docker, before the runner registers. Must be idempotent and secret-free (it ships in `custom_data`). |
| `job_cleanup_enabled` | `true`           | Installs the job-started / job-completed cleanup hooks described above.          |
| `upgrade_mode`    | `Automatic`          | `Manual`, `Automatic`, or `Rolling`. `Automatic`/`Rolling` reimage existing instances on model changes (re-registering the runner with the latest token) but require a health signal — set `health_extension_enabled = true`. |
| `rolling_upgrade_policy` | `{ max_batch_instance_percent = 50, max_unhealthy_instance_percent = 50, max_unhealthy_upgraded_instance_percent = 50, pause_time_between_batches = "PT2M" }` | Applied only for `Automatic`/`Rolling` (invalid for `Manual`). Set to `null` to omit the block. |
| `health_extension_enabled` | `false`     | Deploys the Application Health (Linux) extension. **Required for `Automatic`/`Rolling`** — without a health signal Azure marks every instance unhealthy and the rolling upgrade fails before the first batch. |
| `health_extension` | `{ protocol = "tcp", port = 22 }` | Probe used when `health_extension_enabled = true`. `protocol` is `tcp`/`http`/`https`; `request_path` is required (and must return 200) for `http`/`https`. The default `tcp:22` reports healthy whenever sshd is reachable. |

## Outputs

- Runner pool: `vmss_name`, `vmss_resource_id`, `admin_username`.
- Bastion: `bastion_name`, `bastion_resource_id`, `bastion_public_ip_id`,
  `bastion_public_ip_address`, plus the ready-to-paste hints
  `ssh_via_bastion_hint` and `tunnel_via_bastion_hint`.
- Network: `resource_group_name`, `resource_group_id`, `location`,
  `vnet_name`, `vnet_id`, `vnet_address_space`, `runners_subnet_id`,
  `runners_subnet_name`, `bastion_subnet_id`, `bastion_subnet_address_prefix`,
  `nsg_id`, `nsg_name`.
- `network`: `{ resource_group_name, location, virtual_network_name,
  bastion_subnet_address_prefix, bastion_name }`, the object the Windows
  module's `network` input takes. It resolves only after the Bastion host
  exists, so the Windows pool's subnet is not created while Azure is still
  updating the VNet for Bastion.

## Shared network with a Windows pool

```hcl
module "linux" {
  source              = "github.com/KangarooKube/terraform-infrastructure-modules//modules/github-runner/azure-vmss?ref=<sha>"
  resource_group_name = "gh-myrepo-rg"
  name_prefix         = "myrepo"
  github_repo         = "https://github.com/<owner>/<repo>"
  github_runner_token = var.github_runner_token
  ssh_public_key      = var.ssh_public_key
}

module "windows" {
  source              = "github.com/KangarooKube/terraform-infrastructure-modules//modules/github-runner/azure-vmss-windows?ref=<sha>"
  network             = module.linux.network
  name_prefix         = "myrepo-win"
  github_repo         = "https://github.com/<owner>/<repo>"
  github_runner_token = var.github_runner_token
}
```

## Example

See [`examples/github-runner-azure-vmss/`](../../../examples/github-runner-azure-vmss/)
for a runnable example with an Azure Storage backend for state.

## Registration token

The `github_runner_token` only lives for 1 hour. The typical pattern is
to mint a fresh one on every apply from an already-authenticated `gh`
CLI session:

```bash
gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token
```

## Wall time (rough)

| Operation                      |                                    |
| ------------------------------ | ---------------------------------- |
| `apply` (initial)              | ~10–12 min (Bastion ~7 min, VMSS ~3 min) |
| Cloud-init runner registration | ~3–5 min after VMSS is `Running`   |
| `destroy`                      | ~5–7 min (Bastion dominates)       |
| `apply` (no diff)              | ~30 s                              |

## SSH via Bastion

The two `*_via_bastion_hint` outputs print ready-to-paste `az network
bastion ssh` / `az network bastion tunnel` commands. Example:

```bash
RG=$(terraform output -raw resource_group_name)
VMSS=$(terraform output -raw vmss_name)
BAS=$(terraform output -raw bastion_name)

INSTANCE_ID=$(az vmss list-instances -g "$RG" -n "$VMSS" --query '[0].id' -o tsv)

az network bastion ssh -g "$RG" -n "$BAS" \
  --target-resource-id "$INSTANCE_ID" \
  --auth-type ssh-key --username azureuser --ssh-key ~/.ssh/id_ed25519
```

Or tunnel for `scp`/`rsync`/VS Code Remote-SSH:

```bash
az network bastion tunnel -g "$RG" -n "$BAS" \
  --target-resource-id "$INSTANCE_ID" \
  --resource-port 22 --port 50022 &
ssh -i ~/.ssh/id_ed25519 azureuser@localhost -p 50022
```
