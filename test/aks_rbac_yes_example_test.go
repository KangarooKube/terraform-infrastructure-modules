package test

import (
	// Native

	"fmt"
	"path/filepath"
	"strings"
	"testing"

	// Terragrunt
	"github.com/gruntwork-io/terratest/modules/azure"
	"github.com/gruntwork-io/terratest/modules/k8s"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"

	// Testing
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	aksRbacYesExampleGitDir = "../examples/aks-rbac-yes"
	k8sPayloadSampleDir     = "../examples/kustomize/overlays/loadbalancer"
	k8sPayloadTempDir       = "../examples/kustomize/temp"
)

// Test run that has skippable stages built in
func TestAksRbacYesExampleWithStages(t *testing.T) {
	t.Parallel()

	// Defer destruction
	defer test_structure.RunTestStage(t, "teardown_aksRbacYes", func() {
		aksRbacYesOpts := test_structure.LoadTerraformOptions(t, aksRbacYesExampleGitDir)
		defer terraform.Destroy(t, aksRbacYesOpts)
	})

	// Deploy
	test_structure.RunTestStage(t, "deploy_aksRbacYes", func() {
		aksRbacYesOpts := createAksRbacYesOpts(t, aksRbacYesExampleGitDir)

		// Save data to disk so that other test stages executed at a later time can read the data back in
		test_structure.SaveTerraformOptions(t, aksRbacYesExampleGitDir, aksRbacYesOpts)

		terraform.InitAndApply(t, aksRbacYesOpts)
	})

	// Test
	test_structure.RunTestStage(t, "validate_aksRbacYes", func() {
		aksRbacYesOpts := test_structure.LoadTerraformOptions(t, aksRbacYesExampleGitDir)

		validateNodeCountWithARM(t, aksRbacYesOpts)
		validateLoadBalancerReachableWithK8s(t, aksRbacYesOpts)
	})
}

// Creates Terraform Options for with remote state backend
func createAksRbacYesOpts(t *testing.T, terraformDir string) *terraform.Options {
	uniqueId := strings.ToLower(random.UniqueId())

	// State backend environment variables
	stateBlobAccountNameForTesting := GetRequiredEnvVar(t, TerraformStateBlobStoreNameForTestEnvVarName)
	stateBlobAccountContainerForTesting := GetRequiredEnvVar(t, TerraformStateBlobStoreContainerForTestEnvVarName)
	stateBlobAccountKeyForTesting := GetRequiredEnvVar(t, TerraformStateBlobStoreKeyForTestEnvVarName)

	storageAccountStateKey := fmt.Sprintf("%s/%s/terraform.tfstate", t.Name(), uniqueId)

	return &terraform.Options{
		// Set the path to the Terraform code that will be tested.
		TerraformDir: terraformDir,

		// Variables to pass to our Terraform code using -var options.
		Vars: map[string]interface{}{
			"resource_prefix": fmt.Sprintf("%s%s", "aksrbac", uniqueId),
			"location":        "canadacentral",
			"tags": map[string]string{
				"Source":  "terratest",
				"Owner":   "Raki Rahman",
				"Project": "Terraform CI testing",
			},
		},

		BackendConfig: map[string]interface{}{
			"storage_account_name": stateBlobAccountNameForTesting,
			"container_name":       stateBlobAccountContainerForTesting,
			"access_key":           stateBlobAccountKeyForTesting,
			"key":                  storageAccountStateKey,
		},

		// Service Principal creds from Environment Variables
		EnvVars: setTerraformVariables(t),

		// Colors in Terraform commands - we like colors
		NoColor: false,
	}
}

// Validate that the Node Count is g.t zero (since module hard codes it)
func validateNodeCountWithARM(t *testing.T, aksRbacYesOpts *terraform.Options) {
	inputResourcePrefix := aksRbacYesOpts.Vars["resource_prefix"].(string)
	expectedResourceGroupName := fmt.Sprintf("%s%s", inputResourcePrefix, "rg")
	expectedClusterName := fmt.Sprintf("%s%s", inputResourcePrefix, "aks")

	// Look up the cluster node count from ARM
	cluster, err := azure.GetManagedClusterE(t, expectedResourceGroupName, expectedClusterName, "")
	require.NoError(t, err)
	actualCount := *(*cluster.ManagedClusterProperties.AgentPoolProfiles)[0].Count
	t.Logf("Found cluster with %d nodes", actualCount)

	t.Run("aks_node_count_greater_than_zero", func(t *testing.T) {
		assert.Greater(t, int32(actualCount), int32(0), "AKS Node Count > 0")
	})
}

func validateLoadBalancerReachableWithK8s(t *testing.T, aksRbacYesOpts *terraform.Options) {
	// Get absolute paths to the Kustomize directory and the staging directory
	kustomizePath, err := filepath.Abs(k8sPayloadSampleDir)
	require.NoError(t, err)
	payloadPath, err := filepath.Abs(k8sPayloadTempDir)
	require.NoError(t, err)

	// Setup the kubectl config and context - grabbed from Terraform module output
	namespaceName := strings.ToLower(random.UniqueId())
	options := k8s.NewKubectlOptions("", fmt.Sprintf("%s/kubeconfig", aksRbacYesExampleGitDir), namespaceName)

	// Generate Kustomized manifest
	tempKustomizedManifestPath := generateKustomizedManifest(t, kustomizePath, payloadPath)

	// Clean up
	defer k8s.DeleteNamespace(t, options, namespaceName)
	defer k8s.KubectlDelete(t, options, tempKustomizedManifestPath)
	defer deleteDir(t, tempKustomizedManifestPath)

	// Create resources
	k8s.CreateNamespace(t, options, namespaceName)
	k8s.KubectlApply(t, options, tempKustomizedManifestPath)

	// Test type LoadBalancer

	// Test reachable

}
