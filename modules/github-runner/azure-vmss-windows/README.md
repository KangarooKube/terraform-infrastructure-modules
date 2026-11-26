# GitHub Self-Hosted Windows Runner on Azure (VMSS + Bastion)

Deploys a Windows Server 2025 VMSS whose instances register as
[self-hosted GitHub Actions runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)
against a repository. The runners have no public IPs; RDP is only reachable
from the Azure Bastion subnet.

The module runs in one of two modes:

- **Attached** (`network = module.linux.network`): joins the resource group,
  VNet and Bastion created by the [`azure-vmss`](../azure-vmss/) Linux module,
  so one resource group holds both pools behind one Bastion. The module
  creates only its subnet, NSG and VMSS.
- **Standalone** (`network = null`, `resource_group_name` set): creates its
  own resource group, VNet (`10.0.0.0/16`), `AzureBastionSubnet`
  (`10.0.2.0/26`), Bastion public IP with `bastion_public_ip_tags` ipTags
  (default `FirstPartyUsage=/NonProd`), and a `Standard` Bastion with native
  client tunneling.

In both modes it creates:

- Subnet `snet-runners-windows` (default `10.0.3.0/24`) and NSG
  `<name_prefix>-nsg-runners`: inbound RDP only from the Bastion subnet, all
  other inbound denied, outbound to the VNet and Internet.
- `<name_prefix>-vmss-runner`: Windows Server 2025 Datacenter Azure Edition
  (Gen2, Trusted Launch), Premium SSD OS disk, system-assigned identity, boot
  diagnostics, and a local administrator with a generated password.
- The `gh-runner-bootstrap` CustomScriptExtension and, by default, the
  Application Health (Windows) extension, provisioned after the bootstrap.

## What the bootstrap installs

The PowerShell bootstrap ([`bootstrap-github-runner.ps1.tftpl`](./bootstrap-github-runner.ps1.tftpl))
runs as SYSTEM and logs to `C:\gh-runner\bootstrap.log`. It covers what
workflows written for GitHub-hosted `windows-2025` runners implicitly rely on:

- Long paths enabled (registry and `git config --system core.longpaths true`).
- Git for Windows with Git LFS. `Git\bin` comes first on PATH, so
  `shell: bash` runs Git Bash, as on hosted runners, and `Git\usr\bin` provides
  the Unix tools.
- PowerShell 7 (`shell: pwsh`).
- GitHub CLI (`install_gh_cli`, default on).
- Optional: Visual Studio 2022 Build Tools with the VCTools workload (MSVC
  x64/x86 and the Windows SDK) via `install_msvc_build_tools`, and rustup at
  machine scope with `rust_toolchain` as the default via `install_rustup`.
- Optional `extra_bootstrap_script`.

`curl.exe` and `tar.exe` ship with Windows Server 2025. Node.js and .NET are
expected to come from `actions/setup-node` and `actions/setup-dotnet`, which
work as-is because the runner service runs as a local administrator.

The runner (`runner_version`, default `2.338.2`) is configured with
`--replace` as a Windows service that logs on as `admin_username`, so jobs
can install tooling. It registers under the instance's computer name with the
default `self-hosted, Windows, X64` labels plus `runner_labels`.

### Registration and job readiness

The registration token expires an hour after it is minted, and a Build Tools
install alone can take 20 minutes, so the bootstrap registers the runner
**before** installing tools:

1. Download the runner, write its `.env` (the PATH the machine will have once
   every tool is installed, plus the hook settings), and register it. The
   service starts immediately.
2. Install the tools. Every runner job is held by a job-started hook
   (`C:\gh-runner\hooks\job-started.ps1`) that waits until the bootstrap
   writes `C:\gh-runner\ready`, for up to 120 minutes.
3. If the installers added anything else to the machine PATH, rewrite `.env`
   and restart the runner service, then write the ready marker.
4. If an installer asked for a reboot and no job is running, restart the
   instance. The runner service starts on boot.

If the bootstrap fails, it disables the runner service so the broken instance
does not take jobs, and the extension reports the failure. The bootstrap is
idempotent: when it reruns on an instance whose runner is registered, running
and bootstrapped by the same script, it exits without changes.

### Job cleanup

With `job_cleanup_enabled` (default), a job-completed hook deletes the job
workspace contents after every job. It only acts on a workspace strictly
beneath `C:\actions-runner\_work`, refuses links, and logs (rather than fails
the job on) anything it cannot remove.

## Secrets

- `github_runner_token` and the admin password are passed to the bootstrap
  only through the extension's `protected_settings` (encrypted, never returned
  by the Azure API). They are never in `custom_data`, logs or outputs. The
  script in `custom_data` contains no secrets.
- `admin_password` defaults to a generated 24-character password. Read it with
  `terraform output -raw admin_password` when you need to RDP in.

## Token rotation and reimage

Mint a fresh token on every apply:

```bash
gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token
```

A new token changes the bootstrap extension's `force_update_tag`. With
`upgrade_mode = "Automatic"` (default) Azure reruns the extension on existing
instances, which is a no-op on a healthy runner and re-registers an unhealthy
one. Changes to the script itself (for example `runner_version` or
`tool_versions`) are delivered through `custom_data`, which Azure only rewrites
on reimage, so they reach existing instances on the next reimage. The usual
wrapper pattern reimages on every token change:

```hcl
resource "terraform_data" "reimage_windows" {
  triggers_replace = var.github_runner_token
  provisioner "local-exec" {
    command = "az vmss reimage --resource-group ${module.windows.resource_group_name} --name ${module.windows.vmss_name}"
  }
  depends_on = [module.windows]
}
```

A reimage starts from a clean OS disk and runs the full bootstrap again.

## Inputs

Required: `github_repo`, `github_runner_token`, and either `network`
(attached) or `resource_group_name` (standalone).

Full list in [`vars.tf`](./vars.tf):

| Variable | Default | Notes |
| --- | --- | --- |
| `network` | `null` | `{ resource_group_name, location, virtual_network_name, bastion_subnet_address_prefix, bastion_name }`. Pass the Linux module's `network` output to attach. |
| `resource_group_name` | `null` | Standalone only. Must not pre-exist. |
| `location` | `canadacentral` | Standalone only. Attached mode uses `network.location`. |
| `name_prefix` | `ghrunner-win` | Must differ from the Linux pool's prefix when attached. |
| `computer_name_prefix` | derived | Max 9 characters. Defaults to `name_prefix` lowercased, alphanumerics only, truncated to 9. |
| `runners_subnet_address_prefix` | `10.0.3.0/24` | Must not overlap `10.0.1.0/24` (Linux) or `10.0.2.0/26` (Bastion). |
| `bastion_public_ip_tags` | `{ FirstPartyUsage = "/NonProd" }` | Standalone only. ipTags are immutable: changing them replaces the public IP and the Bastion. `{}` adds the policy skip tags instead. |
| `runner_labels` | `["self-hosted-azure"]` | Added to `self-hosted, Windows, X64`. |
| `runner_version` | `2.338.2` | actions/runner release. |
| `instance_count` | `1` | |
| `instance_sku` | `Standard_D8as_v5` | Must support Trusted Launch. |
| `os_disk_size_gb` | `256` | Premium SSD. |
| `vm_image` | `WindowsServer` / `2025-datacenter-azure-edition` / `latest` | Must be Gen2. |
| `admin_username` | `runneradmin` | The runner service logs on as this local administrator. |
| `admin_password` | generated | Letters, digits and `-_.@+` only, 12-123 characters. |
| `tags` | `{ purpose, managed }` | Applied to every resource. |
| `upgrade_mode` | `Automatic` | `Manual`, `Automatic` or `Rolling`. With `Manual`, `az vmss reimage` keeps the old model; run `az vmss update-instances` first. |
| `rolling_upgrade_policy` | 50% / 50% / 50% / `PT2M` | Only for `Automatic`/`Rolling`. `null` omits it. |
| `health_extension_enabled` | `true` | Application Health (Windows). Needed for `Automatic`/`Rolling`. |
| `health_extension` | `{ protocol = "tcp", port = 3389 }` | `request_path` is required for `http`/`https`. |
| `tool_versions` | `{ git = "2.56.1.windows.1", pwsh = "7.6.10", gh = "2.106.0" }` | Each attribute is optional. |
| `install_gh_cli` | `true` | |
| `install_msvc_build_tools` | `false` | Adds about 15-20 minutes to the first boot. |
| `install_rustup` | `false` | `RUSTUP_HOME=C:\rust\rustup`, `CARGO_HOME=C:\rust\cargo`, minimal profile plus `clippy` and `rustfmt`. |
| `rust_toolchain` | `stable` | For example `1.90.0`. |
| `extra_bootstrap_script` | `""` | PowerShell run as SYSTEM after the tools, before jobs are released. Must be idempotent and secret-free. |
| `job_cleanup_enabled` | `true` | See [Job cleanup](#job-cleanup). |

## Outputs

`resource_group_name`, `location`, `vnet_name`, `subnet_id`, `nsg_id`,
`vmss_name`, `vmss_resource_id`, `bastion_name`, `bastion_resource_id`
(standalone only, otherwise `null`), `bastion_public_ip_address` (standalone
only), `admin_username`, `admin_password` (sensitive), and
`rdp_tunnel_via_bastion_hint`.

## Example

Attached to a Linux pool:

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
  source                   = "github.com/KangarooKube/terraform-infrastructure-modules//modules/github-runner/azure-vmss-windows?ref=<sha>"
  network                  = module.linux.network
  name_prefix              = "myrepo-win"
  github_repo              = "https://github.com/<owner>/<repo>"
  github_runner_token      = var.github_runner_token
  runner_labels            = ["myrepo-windows"]
  install_msvc_build_tools = true
}
```

Standalone:

```hcl
module "windows" {
  source              = "github.com/KangarooKube/terraform-infrastructure-modules//modules/github-runner/azure-vmss-windows?ref=<sha>"
  resource_group_name = "gh-myrepo-win-rg"
  name_prefix         = "myrepo-win"
  github_repo         = "https://github.com/<owner>/<repo>"
  github_runner_token = var.github_runner_token
}
```

## RDP via Bastion

`rdp_tunnel_via_bastion_hint` prints an `az network bastion tunnel` command
that forwards `localhost:53389` to RDP on the first instance. Connect an RDP
client to `localhost:53389` as `admin_username` with the `admin_password`
output. The bootstrap log is `C:\gh-runner\bootstrap.log`, and the
extension's own logs are under `C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension`.
