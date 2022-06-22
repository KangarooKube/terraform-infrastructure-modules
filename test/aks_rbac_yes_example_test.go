package test

import (
	// Native

	"crypto/tls"
	"flag"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	// Terragrunt
	"github.com/gruntwork-io/terratest/modules/azure"
	http_helper "github.com/gruntwork-io/terratest/modules/http-helper"
	"github.com/gruntwork-io/terratest/modules/k8s"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"

	// Testing
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var aksRbacExampleGitDir = flag.String("aksRbacExampleGitDir", "", "relative directory of package containing AKS Terraform Module")

const (
	k8sPayloadSampleDir = "../examples/kustomize/overlays/loadbalancer"
	k8sPayloadTempDir   = "../examples/kustomize/.temp"
)

// Test run that has skippable stages built in
func TestAksRbacExampleWithStages(t *testing.T) {
	t.Parallel()

	// Defer destruction
	defer test_structure.RunTestStage(t, "teardown_aksRbac", func() {
		aksRbacOpts := test_structure.LoadTerraformOptions(t, *aksRbacExampleGitDir)
		defer terraform.Destroy(t, aksRbacOpts)
	})

	// Deploy
	test_structure.RunTestStage(t, "deploy_aksRbac", func() {
		aksRbacOpts := createAksRbacOpts(t, *aksRbacExampleGitDir)

		// Save data to disk so that other test stages executed at a later time can read the data back in
		test_structure.SaveTerraformOptions(t, *aksRbacExampleGitDir, aksRbacOpts)

		terraform.InitAndApply(t, aksRbacOpts)
	})

	// Test
	test_structure.RunTestStage(t, "validate_aksRbac", func() {
		// Set environment variables for ARM authentication
		setARMVariables(t)
		aksRbacOpts := test_structure.LoadTerraformOptions(t, *aksRbacExampleGitDir)

		validateNodeCountWithARM(t, aksRbacOpts)
		validateLoadBalancerReachableWithK8s(t, aksRbacOpts)
	})
}

// Creates Terraform Options for with remote state backend
func createAksRbacOpts(t *testing.T, terraformDir string) *terraform.Options {
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
func validateNodeCountWithARM(t *testing.T, aksRbacOpts *terraform.Options) {
	inputResourcePrefix := aksRbacOpts.Vars["resource_prefix"].(string)
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

// Validate that the service is of type LoadBalancer, and that the deployment webpage is reachable
func validateLoadBalancerReachableWithK8s(t *testing.T, aksRbacOpts *terraform.Options) {
	// Get absolute paths to the Kustomize directory and the temporary staging directory
	kustomizePath, err := filepath.Abs(k8sPayloadSampleDir)
	require.NoError(t, err)
	payloadPath, err := filepath.Abs(k8sPayloadTempDir)
	require.NoError(t, err)

	// Setup the kubectl config and context - grabbed from Terraform module output
	namespaceName := strings.ToLower(random.UniqueId())
	options := k8s.NewKubectlOptions("", fmt.Sprintf("%s/kubeconfig", *aksRbacExampleGitDir), namespaceName)

	// Generate Kustomized manifest
	tempKustomizedManifestPath := generateKustomizedManifest(t, kustomizePath, payloadPath)

	// Clean up - note that defer is LIFO - so we have to delete the manifest folder last
	// Resources > Namespace, Folder
	defer deleteDir(t, tempKustomizedManifestPath)
	defer k8s.DeleteNamespace(t, options, namespaceName)
	defer k8s.KubectlDelete(t, options, tempKustomizedManifestPath)

	// Create namespace scoped resources
	k8s.CreateNamespace(t, options, namespaceName)
	k8s.KubectlApply(t, options, tempKustomizedManifestPath)

	// Test the service type is LoadBalancer
	// This will wait up to 200 seconds for the service to become available, to ensure that we can access it
	k8s.WaitUntilServiceAvailable(t, options, "nginx-service", 10, 20*time.Second)
	service := k8s.GetService(t, options, "nginx-service")
	serviceType := string(service.Spec.Type)

	t.Run("service_is_LoadBalancer", func(t *testing.T) {
		assert.Equal(t, strings.ToLower("LoadBalancer"), strings.ToLower(serviceType), "Ensure Service is of type LoadBalancer as declared")
	})

	// Test that the nginx deployment is reachable over the web
	// Setup a TLS configuration to submit with the helper, a blank struct is acceptable
	tlsConfig := tls.Config{}

	// Test the endpoint for up to 5 minutes. This will only fail if we timeout waiting for the service to return a 200 response.
	http_helper.HttpGetWithRetryWithCustomValidation(
		t,
		fmt.Sprintf("http://%s", k8s.GetServiceEndpoint(t, options, service, 80)),
		&tlsConfig,
		30,
		10*time.Second,
		func(statusCode int, body string) bool {
			return statusCode == 200
		},
	)
}
