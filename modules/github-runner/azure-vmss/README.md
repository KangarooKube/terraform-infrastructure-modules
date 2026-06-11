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
- Azure Bastion (`Standard` SKU) with native client tunneling enabled
- Linux VMSS (default `Standard_E32as_v4`, 1 TB Premium SSD) with
  cloud-init that installs Docker + the `actions/runner` agent and
  registers each instance against the target repo

The runner user (default `azureuser`) is granted passwordless `sudo`
via `/etc/sudoers.d/90-<user>-nopasswd` so CI jobs running on the
runner can do `sudo apt-get install …` / `sudo systemctl …` without
interactive prompts. The sudoers fragment is validated with
`visudo -c -f` before installation.

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
| `runner_version`  | `2.331.0`            | actions/runner release tag.                                                      |

## Outputs

`resource_group_name`, `vmss_name`, `bastion_name`, `vmss_resource_id`,
`bastion_resource_id`, plus two ready-to-paste hints
`ssh_via_bastion_hint` and `tunnel_via_bastion_hint`.

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
