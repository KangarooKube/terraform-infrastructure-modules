# Terraform Infrastructure modules

Fairly matured Terraform modules that are used for automated testing throughout other projects.

``` bash
.
├── examples                            # Example modules that are ready to call
│   ├── aks-rbac-no
│   ├── aks-rbac-yes
│   ├── github-runner-azure-vmss        # Self-hosted GitHub Actions runner on Azure VMSS + Bastion
│   └── kustomize                       # Sample Nginx deployment with LoadBalancer for automated tests
├── LICENSE
├── modules                             # Core modules
│   ├── github-runner                   # Self-hosted GitHub Actions runners
│   ├── kubernetes
│   ├── misc
│   └── monitoring
├── README.md
└── test                                # CI tests using Terratest and Kustomize
    ├── aks_rbac_yes_example_test.go
    ├── go.mod
    ├── go.sum
    ├── k8s_helper.go
    ├── README.md
    └── test_helpers.go
```