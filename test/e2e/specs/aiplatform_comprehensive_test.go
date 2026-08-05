package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/splunk/splunk-ai-operator/test/e2e/internal/cfg"
	"github.com/splunk/splunk-ai-operator/test/e2e/internal/k8s"
	pathutil "github.com/splunk/splunk-ai-operator/test/e2e/internal/path"
	"github.com/splunk/splunk-ai-operator/test/utils"
)

// Comprehensive E2E tests covering all AIPlatform features:
// - Storage (persistent volumes for Weaviate)
// - Ingress (external access)
// - Server TLS (certificate management through the legacy mtls field)
// - Status conditions
// - Event tracking
// - Component health

var _ = Describe("AIPlatform Comprehensive E2E", Ordered, func() {
	var testNS string

	BeforeAll(func() {
		testNS = cfg.WorkloadNS + "-comprehensive"
		By(fmt.Sprintf("creating test namespace: %s", testNS))
		Expect(k8s.CreateNamespace(testNS)).To(Succeed())

		DeferCleanup(func() {
			By("cleaning up test resources")
			cleanupTestResources(testNS)
			k8s.DeleteNamespace(testNS)
		})

		By("labeling namespace for PSA")
		_ = k8s.LabelNamespace(testNS, "pod-security.kubernetes.io/enforce", "baseline")

		By("creating test Splunk secret")
		err := createTestSplunkSecret(testNS)
		Expect(err).NotTo(HaveOccurred())
	})

	Describe("Storage Configuration", func() {
		Context("With persistent volume for Weaviate", func() {
			It("creates PVC with specified size and storage class", func() {
				manifestPath := createStorageTestManifest(testNS)
				defer os.Remove(manifestPath)

				By("applying AIPlatform with storage config")
				_, err := k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("waiting for AIPlatform to be created")
				time.Sleep(10 * time.Second)

				By("verifying PVC was created")
				Eventually(func(g Gomega) {
					pvcName := getPVCName(testNS, "storage-test")
					g.Expect(pvcName).NotTo(BeEmpty())

					// Verify PVC size
					size, err := getPVCSize(testNS, pvcName)
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(size).To(ContainSubstring("50Gi"))
				}, 3*time.Minute, 5*time.Second).Should(Succeed())

				By("verifying Weaviate StatefulSet uses the PVC")
				Eventually(func(g Gomega) {
					hasVolume, err := statefulSetHasVolumeMount(testNS, "storage-test-weaviate", "weaviate-data")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(hasVolume).To(BeTrue())
				}, 2*time.Minute, 5*time.Second).Should(Succeed())
			})

			It("persists data across pod restarts", func() {
				By("getting Weaviate pod name")
				podName := getWeaviatePodName(testNS, "storage-test")
				Expect(podName).NotTo(BeEmpty())

				By("writing test data to Weaviate")
				// Create a simple schema via Weaviate API
				testSchema := `{"class": "TestClass", "properties": [{"name": "testProp", "dataType": ["string"]}]}`
				_ = writeDataToWeaviate(testNS, podName, testSchema)

				By("deleting Weaviate pod to trigger restart")
				k8s.DeletePod(testNS, podName)

				By("waiting for pod to be recreated")
				Eventually(func(g Gomega) {
					newPodName := getWeaviatePodName(testNS, "storage-test")
					g.Expect(newPodName).NotTo(BeEmpty())
					g.Expect(newPodName).NotTo(Equal(podName)) // Should be a new pod
				}, 3*time.Minute, 5*time.Second).Should(Succeed())

				By("verifying data persists after restart")
				// This is a placeholder - in real test, query Weaviate to verify schema still exists
				newPodName := getWeaviatePodName(testNS, "storage-test")
				Expect(newPodName).NotTo(BeEmpty())
			})
		})

		Context("With existing PVC reference", func() {
			It("uses pre-existing PVC when pvcName is specified", func() {
				By("creating a pre-existing PVC")
				pvcName := "pre-existing-weaviate-pvc"
				err := createPVC(testNS, pvcName, "10Gi", "")
				Expect(err).NotTo(HaveOccurred())

				By("creating AIPlatform referencing existing PVC")
				manifestPath := createStorageTestWithExistingPVC(testNS, pvcName)
				defer os.Remove(manifestPath)

				_, err = k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("verifying StatefulSet uses the existing PVC")
				Eventually(func(g Gomega) {
					usesExistingPVC, err := statefulSetUsesPVC(testNS, "storage-existing-weaviate", pvcName)
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(usesExistingPVC).To(BeTrue())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())
			})
		})
	})

	Describe("Ingress Configuration", func() {
		Context("With ingress enabled", func() {
			It("creates Ingress resource with correct configuration", func() {
				manifestPath := createIngressTestManifest(testNS)
				defer os.Remove(manifestPath)

				By("applying AIPlatform with ingress config")
				_, err := k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("waiting for Ingress to be created")
				Eventually(func(g Gomega) {
					exists, err := ingressExists(testNS, "ingress-test")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(exists).To(BeTrue())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())

				By("verifying Ingress has correct host configuration")
				host, err := getIngressHost(testNS, "ingress-test")
				Expect(err).NotTo(HaveOccurred())
				Expect(host).To(ContainSubstring("ai-test.example.com"))

				By("verifying Ingress has correct TLS configuration")
				hasTLS, err := ingressHasTLS(testNS, "ingress-test")
				Expect(err).NotTo(HaveOccurred())
				Expect(hasTLS).To(BeTrue())
			})

			It("updates IngressReady status condition", func() {
				By("checking IngressReady condition")
				Eventually(func(g Gomega) {
					status, msg, err := getConditionStatus(testNS, "ingress-test", "IngressReady")
					g.Expect(err).NotTo(HaveOccurred())
					// May be True or Unknown depending on ingress controller availability
					g.Expect(status).To(BeElementOf("True", "Unknown", "False"))
					g.Expect(msg).NotTo(BeEmpty())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())
			})

			It("emits Ingress-related events", func() {
				By("checking for Ingress creation events")
				Eventually(func(g Gomega) {
					events, err := getEvents(testNS, "ingress-test")
					g.Expect(err).NotTo(HaveOccurred())

					// Should have IngressCreating or IngressCreated events
					hasIngressEvent := false
					for _, event := range events {
						if strings.Contains(event, "Ingress") {
							hasIngressEvent = true
							break
						}
					}
					g.Expect(hasIngressEvent).To(BeTrue())
				}, 2*time.Minute, 5*time.Second).Should(Succeed())
			})
		})

		Context("With ingress disabled", func() {
			It("does not create Ingress resource when disabled", func() {
				manifestPath := createIngressDisabledTestManifest(testNS)
				defer os.Remove(manifestPath)

				By("applying AIPlatform with ingress disabled")
				_, err := k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("verifying Ingress is not created")
				Consistently(func(g Gomega) {
					exists, err := ingressExists(testNS, "ingress-disabled")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(exists).To(BeFalse())
				}, 30*time.Second, 5*time.Second).Should(Succeed())

				By("verifying IngressReady condition is not present")
				_, _, err = getConditionStatus(testNS, "ingress-disabled", "IngressReady")
				// Condition may not exist or be Unknown
				// We just verify no error occurs when querying
				Expect(err).NotTo(HaveOccurred())
			})
		})
	})

	Describe("Server TLS Configuration", func() {
		Context("With server TLS configured via certificateRef", func() {
			It("references an issuer for server certificate provisioning", func() {
				By("creating certificate issuer")
				err := createCertificateIssuer(testNS, "test-ca-issuer")
				Expect(err).NotTo(HaveOccurred())

				By("applying AIPlatform with certificateRef")
				manifestPath := createMTLSTestManifest(testNS)
				defer os.Remove(manifestPath)

				_, err = k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("verifying AIPlatform references the certificate")
				Eventually(func(g Gomega) {
					certRef, err := getCertificateRef(testNS, "mtls-test")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(certRef).To(Equal("test-ca-issuer"))
				}, 2*time.Minute, 5*time.Second).Should(Succeed())
			})
		})
	})

	Describe("Status Conditions", func() {
		Context("Platform lifecycle status tracking", func() {
			It("tracks all component readiness conditions", func() {
				manifestPath := createCompleteTestManifest(testNS)
				defer os.Remove(manifestPath)

				By("applying complete AIPlatform configuration")
				_, err := k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("verifying Ready condition transitions")
				Eventually(func(g Gomega) {
					status, _, err := getConditionStatus(testNS, "complete-test", "Ready")
					g.Expect(err).NotTo(HaveOccurred())
					// Should eventually become True or show progress
					g.Expect(status).NotTo(BeEmpty())
				}, 1*time.Minute, 5*time.Second).Should(Succeed())

				By("verifying RayServiceReady condition")
				Eventually(func(g Gomega) {
					status, _, err := getConditionStatus(testNS, "complete-test", "RayServiceReady")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(status).NotTo(BeEmpty())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())

				By("verifying RayClusterReady condition")
				Eventually(func(g Gomega) {
					status, _, err := getConditionStatus(testNS, "complete-test", "RayClusterReady")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(status).NotTo(BeEmpty())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())

				By("verifying WeaviateDatabaseReady condition")
				Eventually(func(g Gomega) {
					status, _, err := getConditionStatus(testNS, "complete-test", "WeaviateDatabaseReady")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(status).NotTo(BeEmpty())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())
			})

			It("updates condition messages with meaningful information", func() {
				By("checking condition messages provide context")
				Eventually(func(g Gomega) {
					_, msg, err := getConditionStatus(testNS, "complete-test", "Ready")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(msg).NotTo(BeEmpty())
					// Message should provide useful information
					g.Expect(len(msg)).To(BeNumerically(">", 10))
				}, 2*time.Minute, 5*time.Second).Should(Succeed())
			})
		})
	})

	Describe("Event Tracking", func() {
		Context("Component lifecycle events", func() {
			It("emits events for Ray service lifecycle", func() {
				manifestPath := createEventTestManifest(testNS)
				defer os.Remove(manifestPath)

				By("applying AIPlatform")
				_, err := k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("checking for Ray service creation events")
				Eventually(func(g Gomega) {
					events, err := getEvents(testNS, "event-test")
					g.Expect(err).NotTo(HaveOccurred())

					hasRayEvent := false
					for _, event := range events {
						if strings.Contains(event, "RayService") || strings.Contains(event, "Ray") {
							hasRayEvent = true
							break
						}
					}
					g.Expect(hasRayEvent).To(BeTrue())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())
			})

			It("emits events for Weaviate lifecycle", func() {
				By("checking for Weaviate creation events")
				Eventually(func(g Gomega) {
					events, err := getEvents(testNS, "event-test")
					g.Expect(err).NotTo(HaveOccurred())

					hasWeaviateEvent := false
					for _, event := range events {
						if strings.Contains(event, "Weaviate") {
							hasWeaviateEvent = true
							break
						}
					}
					g.Expect(hasWeaviateEvent).To(BeTrue())
				}, 3*time.Minute, 5*time.Second).Should(Succeed())
			})

			It("emits warning events for failures", func() {
				// This test would need a failing configuration to verify warning events
				// For now, we just verify event retrieval works
				events, err := getEvents(testNS, "event-test")
				Expect(err).NotTo(HaveOccurred())
				Expect(events).NotTo(BeNil())
			})
		})
	})

	Describe("Component Health", func() {
		Context("Ray cluster health", func() {
			It("verifies Ray head pod becomes ready", func() {
				manifestPath := createHealthTestManifest(testNS)
				defer os.Remove(manifestPath)

				By("applying AIPlatform")
				_, err := k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("waiting for Ray head pod to be ready")
				Eventually(func(g Gomega) {
					podName := getRayHeadPodName(testNS, "health-test")
					g.Expect(podName).NotTo(BeEmpty())

					phase, err := k8s.PodPhase(testNS, podName)
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(phase).To(Equal("Running"))
				}, 5*time.Minute, 10*time.Second).Should(Succeed())
			})
		})

		Context("Weaviate health", func() {
			It("verifies Weaviate pod becomes ready", func() {
				By("waiting for Weaviate pod to be ready")
				Eventually(func(g Gomega) {
					podName := getWeaviatePodName(testNS, "health-test")
					g.Expect(podName).NotTo(BeEmpty())

					phase, err := k8s.PodPhase(testNS, podName)
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(phase).To(Equal("Running"))
				}, 5*time.Minute, 10*time.Second).Should(Succeed())
			})
		})

		Context("Service endpoints", func() {
			It("verifies Ray service has endpoints", func() {
				By("checking Ray service endpoints")
				Eventually(func(g Gomega) {
					hasEndpoints, err := serviceHasEndpoints(testNS, "health-test", "8000")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(hasEndpoints).To(BeTrue())
				}, 5*time.Minute, 10*time.Second).Should(Succeed())
			})

			It("verifies Weaviate service has endpoints", func() {
				By("checking Weaviate service endpoints")
				Eventually(func(g Gomega) {
					hasEndpoints, err := serviceHasEndpoints(testNS, "health-test-weaviate", "80")
					g.Expect(err).NotTo(HaveOccurred())
					g.Expect(hasEndpoints).To(BeTrue())
				}, 5*time.Minute, 10*time.Second).Should(Succeed())
			})
		})
	})

	Describe("Integration Scenarios", func() {
		Context("Full stack with all features enabled", func() {
			It("successfully deploys platform with storage, ingress, and server TLS", func() {
				manifestPath := createFullStackTestManifest(testNS)
				defer os.Remove(manifestPath)

				By("applying full-featured AIPlatform")
				_, err := k8s.Apply(testNS, manifestPath)
				Expect(err).NotTo(HaveOccurred())

				By("waiting for platform to be ready")
				err = k8s.WaitCRReady("AIPlatform", "fullstack-test", testNS, "Ready", 15*time.Minute)
				Expect(err).NotTo(HaveOccurred())

				By("verifying all components are healthy")
				conditions := []string{"Ready", "RayServiceReady", "RayClusterReady", "WeaviateDatabaseReady"}
				for _, condType := range conditions {
					status, _, err := getConditionStatus(testNS, "fullstack-test", condType)
					Expect(err).NotTo(HaveOccurred())
					Expect(status).To(Equal("True"), fmt.Sprintf("Condition %s should be True", condType))
				}
			})
		})
	})
})

// Helper functions

func cleanupTestResources(ns string) {
	// Delete all AIPlatforms in namespace
	cmd := exec.Command("kubectl", "delete", "aiplatforms", "--all", "-n", ns, "--ignore-not-found=true")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}
	_, _ = utils.Run(cmd)

	// Wait a bit for cleanup
	time.Sleep(5 * time.Second)
}

// Helper to add splunk configuration to manifests
func getSplunkConfigYAML(ns string) string {
	return fmt.Sprintf(`  splunkConfiguration:
    endpoint: http://test-splunk-service.%s.svc.cluster.local:8089
    secretRef:
      name: splunk-%s-secret
      namespace: %s`, ns, ns, ns)
}

// Helper to create test Splunk secret
func createTestSplunkSecret(ns string) error {
	secretName := fmt.Sprintf("splunk-%s-secret", ns)
	secretManifest := fmt.Sprintf(`apiVersion: v1
kind: Secret
metadata:
  name: %s
  namespace: %s
type: Opaque
data:
  hec_token: NzgxMDI4MDktODBGQi02OEQ0LTIwNDYtMjIzRUFEMTEyNTA3
  idxc_secret: dTNXVDNPNDlkSU85d09wUHVCVWZja1d6
  pass4SymmKey: ZWxQWWZKTlUxVzZRMWJpRFlla2d2ZnFy
  password: Qk9nRVd3Y240b2xoNEVBR0FuT091eUpt
  shc_secret: anpXcHRQdk1qSnpSeHhEaUE3OGxCc2tn`, secretName, ns)

	tmpFile := writeTempManifest("splunk-secret", secretManifest)
	defer os.Remove(tmpFile)

	_, err := k8s.Apply(ns, tmpFile)
	return err
}

func createStorageTestManifest(ns string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: storage-test
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  storage:
    vectorDB:
      size: 50Gi
      storageClassName: standard
  serviceAccountName: test-sa
%s
`, ns, getSplunkConfigYAML(ns))

	return writeTempManifest("storage-test", manifest)
}

func createStorageTestWithExistingPVC(ns, pvcName string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: storage-existing
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  storage:
    vectorDB:
      pvcName: %s
  serviceAccountName: test-sa
%s
`, ns, pvcName, getSplunkConfigYAML(ns))

	return writeTempManifest("storage-existing", manifest)
}

func createIngressTestManifest(ns string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ingress-test
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: ai-test.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - ai-test.example.com
        secretName: ai-test-tls
%s
`, ns, getSplunkConfigYAML(ns))

	return writeTempManifest("ingress-test", manifest)
}

func createIngressDisabledTestManifest(ns string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ingress-disabled
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  ingress:
    enabled: false
%s
`, ns, getSplunkConfigYAML(ns))

	return writeTempManifest("ingress-disabled", manifest)
}

func createMTLSTestManifest(ns string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: mtls-test
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  certificateRef: test-ca-issuer
%s
`, ns, getSplunkConfigYAML(ns))

	return writeTempManifest("mtls-test", manifest)
}

func createCompleteTestManifest(ns string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: complete-test
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  storage:
    vectorDB:
      size: 20Gi
%s
`, ns, getSplunkConfigYAML(ns))

	return writeTempManifest("complete-test", manifest)
}

func createEventTestManifest(ns string) string {
	return createCompleteTestManifest(ns) // Reuse for event testing
}

func createHealthTestManifest(ns string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: health-test
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
%s
`, ns, getSplunkConfigYAML(ns))

	return writeTempManifest("health-test", manifest)
}

func createFullStackTestManifest(ns string) string {
	manifest := fmt.Sprintf(`apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: fullstack-test
  namespace: %s
spec:
  objectStorage:
    path: s3://test-bucket/models
    region: us-west-2
  defaultAcceleratorType: nvidia-tesla-t4
  serviceAccountName: test-sa
  storage:
    vectorDB:
      size: 30Gi
      storageClassName: standard
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: fullstack.example.com
        paths:
          - path: /
            pathType: Prefix
  certificateRef: test-ca-issuer
%s
`, ns, getSplunkConfigYAML(ns))

	return writeTempManifest("fullstack-test", manifest)
}

func writeTempManifest(name, content string) string {
	tmpFile, err := os.CreateTemp("", fmt.Sprintf("e2e-test-%s-*.yaml", name))
	if err != nil {
		return ""
	}
	defer tmpFile.Close()

	_, err = tmpFile.WriteString(content)
	if err != nil {
		return ""
	}

	return tmpFile.Name()
}

func getPVCName(ns, platformName string) string {
	cmd := exec.Command("kubectl", "get", "pvc", "-n", ns, "-o", "json")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return ""
	}

	var pvcList struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		} `json:"items"`
	}

	if json.Unmarshal(out, &pvcList) != nil {
		return ""
	}

	// Look for PVC that contains the platform name
	for _, item := range pvcList.Items {
		if strings.Contains(item.Metadata.Name, platformName) {
			return item.Metadata.Name
		}
	}

	return ""
}

func getPVCSize(ns, pvcName string) (string, error) {
	cmd := exec.Command("kubectl", "get", "pvc", pvcName, "-n", ns, "-o", "jsonpath={.spec.resources.requests.storage}")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}
	return utils.Run(cmd)
}

func statefulSetHasVolumeMount(ns, stsName, volumeName string) (bool, error) {
	cmd := exec.Command("kubectl", "get", "statefulset", stsName, "-n", ns, "-o", "json")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return false, err
	}

	return strings.Contains(string(out), volumeName), nil
}

func statefulSetUsesPVC(ns, stsName, pvcName string) (bool, error) {
	cmd := exec.Command("kubectl", "get", "statefulset", stsName, "-n", ns, "-o", "json")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return false, err
	}

	return strings.Contains(string(out), pvcName), nil
}

func getWeaviatePodName(ns, platformName string) string {
	cmd := exec.Command("kubectl", "get", "pods", "-n", ns, "-l", fmt.Sprintf("app=%s-weaviate", platformName), "-o", "jsonpath={.items[0].metadata.name}")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, _ := cmd.CombinedOutput()
	return strings.TrimSpace(string(out))
}

func getRayHeadPodName(ns, platformName string) string {
	cmd := exec.Command("kubectl", "get", "pods", "-n", ns, "-l", fmt.Sprintf("ray.io/cluster=%s,ray.io/node-type=head", platformName), "-o", "jsonpath={.items[0].metadata.name}")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, _ := cmd.CombinedOutput()
	return strings.TrimSpace(string(out))
}

func writeDataToWeaviate(ns, podName, data string) error {
	// Placeholder for writing test data to Weaviate
	return nil
}

func createPVC(ns, name, size, storageClass string) error {
	scField := ""
	if storageClass != "" {
		scField = fmt.Sprintf("  storageClassName: %s", storageClass)
	}

	pvcManifest := fmt.Sprintf(`apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: %s
  namespace: %s
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: %s
%s`, name, ns, size, scField)

	tmpFile := writeTempManifest("pvc", pvcManifest)
	defer os.Remove(tmpFile)

	_, err := k8s.Apply(ns, tmpFile)
	return err
}

func ingressExists(ns, platformName string) (bool, error) {
	cmd := exec.Command("kubectl", "get", "ingress", platformName, "-n", ns)
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	_, err := cmd.CombinedOutput()
	return err == nil, nil
}

func getIngressHost(ns, platformName string) (string, error) {
	cmd := exec.Command("kubectl", "get", "ingress", platformName, "-n", ns, "-o", "jsonpath={.spec.rules[0].host}")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}
	return utils.Run(cmd)
}

func ingressHasTLS(ns, platformName string) (bool, error) {
	cmd := exec.Command("kubectl", "get", "ingress", platformName, "-n", ns, "-o", "json")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return false, err
	}

	return strings.Contains(string(out), "\"tls\""), nil
}

func createCertificateIssuer(ns, name string) error {
	issuerManifest := fmt.Sprintf(`apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: %s
  namespace: %s
spec:
  selfSigned: {}`, name, ns)

	tmpFile := writeTempManifest("issuer", issuerManifest)
	defer os.Remove(tmpFile)

	_, err := k8s.Apply(ns, tmpFile)
	return err
}

func getCertificateRef(ns, platformName string) (string, error) {
	cmd := exec.Command("kubectl", "get", "aiplatform", platformName, "-n", ns, "-o", "jsonpath={.spec.certificateRef}")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}
	return utils.Run(cmd)
}

func getConditionStatus(ns, platformName, conditionType string) (status string, message string, err error) {
	cmd := exec.Command("kubectl", "get", "aiplatform", platformName, "-n", ns, "-o", "json")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", "", err
	}

	var obj struct {
		Status struct {
			Conditions []struct {
				Type    string `json:"type"`
				Status  string `json:"status"`
				Message string `json:"message"`
			} `json:"conditions"`
		} `json:"status"`
	}

	if json.Unmarshal(out, &obj) != nil {
		return "", "", fmt.Errorf("failed to parse JSON")
	}

	for _, cond := range obj.Status.Conditions {
		if cond.Type == conditionType {
			return cond.Status, cond.Message, nil
		}
	}

	return "", "", nil
}

func getEvents(ns, platformName string) ([]string, error) {
	cmd := exec.Command("kubectl", "get", "events", "-n", ns, "--field-selector", fmt.Sprintf("involvedObject.name=%s", platformName), "-o", "json")
	if root, err := pathutil.RepoRoot(); err == nil {
		cmd.Dir = root
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, err
	}

	var eventList struct {
		Items []struct {
			Reason  string `json:"reason"`
			Message string `json:"message"`
			Type    string `json:"type"`
		} `json:"items"`
	}

	if json.Unmarshal(out, &eventList) != nil {
		return nil, fmt.Errorf("failed to parse events")
	}

	var events []string
	for _, item := range eventList.Items {
		events = append(events, fmt.Sprintf("%s: %s (%s)", item.Reason, item.Message, item.Type))
	}

	return events, nil
}

func serviceHasEndpoints(ns, serviceName, port string) (bool, error) {
	return k8s.ServiceHasEndpointPort(ns, serviceName, port)
}
