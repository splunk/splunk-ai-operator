package v1

import (
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"sigs.k8s.io/yaml"
)

// These assertions use the actual validating webhooks behind the local API
// server. A field-only unit error is insufficient if admission later echoes it.
var _ = Describe("PostgreSQL credential admission", func() {
	It("rejects parent credential literals in both profiles without echoing them", func() {
		for _, profile := range []string{"cpuonly", "fullfeature"} {
			raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tools", "ai-tier-cluster-setup", "testdata", "profile", "aiplatform-cr-"+profile+".expected.yaml"))
			Expect(err).NotTo(HaveOccurred())
			p := &aiv1.AIPlatform{}
			Expect(yaml.Unmarshal(raw, p)).To(Succeed())
			p.Name, p.Namespace = "pg-credential-"+profile, "default"
			for i := range p.Spec.Features {
				if p.Spec.Features[i].Name == "agentruntime" {
					p.Spec.Features[i].Env = map[string]string{"DATABASE_URL": "postgresql://user:admission-secret-canary@db/checkpoints"}
				}
			}
			err = k8sClient.Create(ctx, p)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("checkpointDbSecretRef"))
			Expect(err.Error()).NotTo(ContainSubstring("admission-secret-canary"))
			for i := range p.Spec.Features {
				p.Spec.Features[i].Env = nil
			}
			Expect(k8sClient.Create(ctx, p)).To(Succeed())
			Expect(k8sClient.Delete(ctx, p)).To(Succeed())
		}
	})

	It("rejects direct-service create and update overrides at both environment paths", func() {
		for _, topLevel := range []bool{false, true} {
			svc := serviceForPlatform("weaviate")
			svc.Name, svc.Namespace = "pg-direct-feature", "default"
			if topLevel {
				svc.Name = "pg-direct-top-level"
			}
			svc.Spec.Feature = aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"}
			svc.Spec.CheckpointDbSecretRef = "checkpoint"
			svc.Spec.Resources = corev1.ResourceRequirements{
				Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("100m"), corev1.ResourceMemory: resource.MustParse("128Mi"), corev1.ResourceEphemeralStorage: resource.MustParse("64Mi")},
				Limits:   corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("1"), corev1.ResourceMemory: resource.MustParse("1Gi"), corev1.ResourceEphemeralStorage: resource.MustParse("1Gi")},
			}
			set := func(value string) {
				if topLevel {
					svc.Spec.Env = map[string]string{"PGPASSWORD": value}
				} else {
					svc.Spec.Feature.Env = map[string]string{"PGPASSWORD": value}
				}
			}
			set("admission-secret-canary")
			err := k8sClient.Create(ctx, svc)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("checkpointDbSecretRef"))
			Expect(err.Error()).NotTo(ContainSubstring("admission-secret-canary"))
			if topLevel {
				Expect(err.Error()).To(ContainSubstring("spec.env[PGPASSWORD]"))
			} else {
				Expect(err.Error()).To(ContainSubstring("spec.features.env[PGPASSWORD]"))
			}
			svc.Spec.Env, svc.Spec.Feature.Env = nil, nil
			Expect(k8sClient.Create(ctx, svc)).To(Succeed())
			set("")
			Expect(k8sClient.Update(ctx, svc)).NotTo(Succeed(), "even empty connection overrides must be rejected")
			Expect(k8sClient.Delete(ctx, svc)).To(Succeed())
		}
	})
})
