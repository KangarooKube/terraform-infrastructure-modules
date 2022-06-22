# Automated testing

This folder contains examples of how to write automated tests for infrastructure code using Go and
[Terratest](https://terratest.gruntwork.io/).

## Pre-requisites

* Launch this `.devcontainer`
* You must have an Azure Service Principal with `Contributor` priveleges injected into this container.

## Quick start

First time build:
```bash
cd /workspaces/terraform-infrastructure-modules/test

# Can call it whatever we want - in this case our repo name
go mod init github.com/kangarookube/terraform-infrastructure-modules

# This creates a go.sum file with all our dependencies linked to git commits, and cleans up ones not required
go mod tidy
```

Run all the test modules:

```bash
go test -v -timeout 90m
```

Run one specific modules and all test cases within it:

```bash
go test -v -timeout 90m -run 'TestAksRbacYesExampleWithStages'
```

## Development workflow via `Stages`

Example:
```bash
# Blow away old local state
rm -rf /workspaces/terraform-infrastructure-modules/examples/aks-rbac-yes/.terraform
rm -rf /workspaces/terraform-infrastructure-modules/examples/aks-rbac-yes/.test-data
rm -rf /workspaces/terraform-infrastructure-modules/examples/aks-rbac-yes/.terraform.lock.hcl

# 1. Deploy one-time
SKIP_teardown_aksRbacYes=true \
SKIP_validate_aksRbacYes=true \
go test -timeout 30m -run 'TestAksRbacYesExampleWithStages'
# ...

# 2. Iterate on validation
SKIP_teardown_aksRbacYes=true \
SKIP_deploy_aksRbacYes=true \
go test -timeout 30m -run 'TestAksRbacYesExampleWithStages'
# ...
```