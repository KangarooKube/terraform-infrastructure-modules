# Azure Kubernetes Service

Deploys an [AKS Cluster](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) - in 2 distinct configurations - RBAC **enabled** or **disabled**. Further enhancements available [here](https://docs.microsoft.com/en-us/azure/developer/terraform/create-k8s-cluster-with-tf-and-aks) as needed.

## Quick start

Terraform modules are not meant to be deployed directly. Instead, you should be including them in other Terraform configurations. 

See [examples/aks-rbac-yes](../../../examples/aks-rbac-yes) that deploys an AKS Cluster with Log Analytics for K8s Audit Logging.

See [examples/aks-rbac-no](../../../examples/aks-rbac-no) deploys an AKS Cluster with no RBAC or logging.