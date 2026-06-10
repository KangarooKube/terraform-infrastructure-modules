# GitHub self-hosted runner (Azure VMSS + Bastion) example

This folder contains a [Terraform](https://www.terraform.io/) configuration
that shows an example of how to use the
[github-runner/azure-vmss module](../../modules/github-runner/azure-vmss)
to deploy:

- A fresh resource group with a `10.0.0.0/16` VNet
- An Azure Bastion host (`Standard` SKU) with native client tunneling enabled
- A Linux VMSS (default 2 × `Standard_E32as_v4`, 1 TB Premium SSD per instance)
  that auto-registers each instance as a self-hosted runner against a target
  GitHub repository

The runners themselves have no public IPs — SSH only flows over Bastion.

## Pre-requisites

- Azure subscription with permissions to create a resource group, VNet, NSG,
  Public IP, Bastion, and VMSS
- A GitHub repository where you can mint a runner registration token
- An OpenSSH-format public key (the example will inject it as `azureuser`'s
  authorized key on every instance)
- An Azure Storage Account + container for Terraform state

This example was written for Terraform 1.x+.

## Quick start — manual run

Change directory to here:

```bash
cd examples/github-runner-azure-vmss
```

Set the Azure subscription Terraform should target:

```bash
# Either pass ARM_SUBSCRIPTION_ID via env...
export ARM_SUBSCRIPTION_ID="$subscriptionId"
# ...or rely on `az login` having already selected the right subscription.
```

Configure module-specific variables:

```bash
export TF_VAR_resource_group_name='gh-runner-example-rg'
export TF_VAR_location='canadacentral'
export TF_VAR_name_prefix='ghrunner'
export TF_VAR_github_repo='https://github.com/<owner>/<repo>'
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"

# Mint a fresh runner registration token (expires in 1 hour)
export TF_VAR_github_runner_token="$(gh api -X POST \
  /repos/<owner>/<repo>/actions/runners/registration-token --jq .token)"
```

Configure the Azure Storage backend before running `init`:

```bash
export stateFileKeyName="github-runner-azure-vmss/${TF_VAR_resource_group_name}/terraform.tfstate"
export TF_CLI_ARGS_init="-backend-config='storage_account_name=${TFSTATE_STORAGE_ACCOUNT_NAME}'"
export TF_CLI_ARGS_init="$TF_CLI_ARGS_init -backend-config='container_name=${TFSTATE_STORAGE_ACCOUNT_CONTAINER_NAME}'"
export TF_CLI_ARGS_init="$TF_CLI_ARGS_init -backend-config='access_key=${TFSTATE_STORAGE_ACCOUNT_KEY}'"
export TF_CLI_ARGS_init="$TF_CLI_ARGS_init -backend-config='key=${stateFileKeyName}'"
```

Deploy:

```bash
terraform init
terraform plan
terraform apply -auto-approve
```

After ~10–12 min the Bastion + VMSS will be up. Wait another ~3–5 min for
cloud-init to install Docker + the runner agent and register each instance.
You should then see two new runners in `${GH_REPO}/settings/actions/runners`.

## SSH via Bastion

The `terraform apply` output includes ready-to-paste `az network bastion ssh`
and `az network bastion tunnel` commands as `ssh_via_bastion_hint` and
`tunnel_via_bastion_hint`. See the [module README](../../modules/github-runner/azure-vmss/README.md#ssh-via-bastion)
for the full pattern.

## Clean up

```bash
terraform destroy -auto-approve
rm -rf .terraform
rm .terraform.lock.hcl
```
