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

Run two specific modules and all test cases within it - can run in parallel since the AKS modules have identical input requirements, and the paths used by the tests will be unique:

```bash
# RBAC: Yes
go test -timeout 30m -run 'TestAksRbacExampleWithStages' -args -aksRbacExampleGitDir="../examples/aks-rbac-yes"

# RBAC: No
go test -timeout 30m -run 'TestAksRbacExampleWithStages' -args -aksRbacExampleGitDir="../examples/aks-rbac-no"
```

## Development workflow via `Stages`

Example:
```bash
# Blow away old local state (for yes and no)
MODULE='aks-rbac-yes'
rm -rf /workspaces/terraform-infrastructure-modules/examples/${MODULE}/.terraform
rm -rf /workspaces/terraform-infrastructure-modules/examples/${MODULE}/.test-data
rm -rf /workspaces/terraform-infrastructure-modules/examples/${MODULE}/.terraform.lock.hcl

# 1. Deploy one-time
SKIP_teardown_aksRbac=true \
SKIP_validate_aksRbac=true \
go test -timeout 30m -run 'TestAksRbacExampleWithStages' -args -aksRbacExampleGitDir="../examples/aks-rbac-yes"
# ...

# 2. Iterate on validation
SKIP_teardown_aksRbac=true \
SKIP_deploy_aksRbac=true \
go test -timeout 30m -run 'TestAksRbacExampleWithStages' -args -aksRbacExampleGitDir="../examples/aks-rbac-yes"
# PASS
# ok      github.com/kangarookube/terraform-infrastructure-modules        97.323s

# 3. Destroy
SKIP_deploy_aksRbac=true \
go test -timeout 30m -run 'TestAksRbacExampleWithStages' -args -aksRbacExampleGitDir="../examples/aks-rbac-yes"
```