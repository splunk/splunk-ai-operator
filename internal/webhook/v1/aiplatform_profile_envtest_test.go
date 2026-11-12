package v1

import (
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/yaml"
)

// These specs run against a real kube-apiserver with the mutating and validating
// webhooks installed (the envtest suite), so they cover what unit tests cannot:
// CRD structural defaulting, the webhook's JSON patch and the defaulting that
// runs again after mutating admission. They are skipped, like the rest of this
// suite, when the envtest binaries are not installed (make setup-envtest).
var _ = Describe("AIPlatform profile admission through a real API server", func() {
	var created []*unstructured.Unstructured

	gvk := schema.GroupVersionKind{Group: "ai.splunk.com", Version: "v1", Kind: "AIPlatform"}

	fromYAML := func(raw string) *unstructured.Unstructured {
		obj := &unstructured.Unstructured{}
		Expect(yaml.Unmarshal([]byte(raw), &obj.Object)).To(Succeed())
		obj.SetGroupVersionKind(gvk)
		obj.SetNamespace("default")
		return obj
	}
	golden := func(name string) *unstructured.Unstructured {
		raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tools", "ai-tier-cluster-setup", "testdata", "profile",
			"aiplatform-cr-"+name+".expected.yaml"))
		Expect(err).NotTo(HaveOccurred())
		return fromYAML(string(raw))
	}
	create := func(obj *unstructured.Unstructured) error {
		err := k8sClient.Create(ctx, obj)
		if err == nil {
			created = append(created, obj)
		}
		return err
	}

	AfterEach(func() {
		for _, obj := range created {
			_ = k8sClient.Delete(ctx, obj)
		}
		created = nil
	})

	It("admits the CR the installer renders for cpuOnly and keeps it free of vectorDB", func() {
		obj := golden("cpuonly")
		obj.SetName("profile-golden-cpuonly")
		Expect(create(obj)).To(Succeed())

		stored := &unstructured.Unstructured{}
		stored.SetGroupVersionKind(gvk)
		Expect(k8sClient.Get(ctx, clientKey(obj), stored)).To(Succeed())
		profile, _, _ := unstructured.NestedString(stored.Object, "spec", "profile")
		Expect(profile).To(Equal("cpuOnly"))
		_, found, _ := unstructured.NestedMap(stored.Object, "spec", "storage", "vectorDB")
		Expect(found).To(BeFalse(), "cpuOnly must not end up with a vectorDB object: %v", stored.Object["spec"])
	})

	It("admits a minimal cpuOnly CR (profile and objectStorage only)", func() {
		obj := fromYAML("apiVersion: ai.splunk.com/v1\nkind: AIPlatform\nmetadata: {name: profile-minimal-cpuonly}\nspec:\n  profile: cpuOnly\n  objectStorage: {path: s3://bucket, region: us-west-2}\n")
		Expect(create(obj)).To(Succeed())
	})

	It("admits the CR the installer renders for fullfeature", func() {
		obj := golden("fullfeature")
		obj.SetName("profile-golden-fullfeature")
		Expect(create(obj)).To(Succeed())
	})

	It("admits a minimal CR with the profile omitted (legacy behaviour)", func() {
		obj := fromYAML("apiVersion: ai.splunk.com/v1\nkind: AIPlatform\nmetadata: {name: profile-minimal-legacy}\nspec:\n  objectStorage: {path: s3://bucket, region: us-west-2}\n")
		Expect(create(obj)).To(Succeed())
	})

	It("leaves the legacy defaults of a minimal CR exactly as they were", func() {
		obj := fromYAML("apiVersion: ai.splunk.com/v1\nkind: AIPlatform\nmetadata: {name: profile-legacy-defaults}\nspec:\n  objectStorage: {path: s3://bucket, region: us-west-2}\n")
		Expect(create(obj)).To(Succeed())
		stored := &unstructured.Unstructured{}
		stored.SetGroupVersionKind(gvk)
		Expect(k8sClient.Get(ctx, clientKey(obj), stored)).To(Succeed())
		size, _, _ := unstructured.NestedString(stored.Object, "spec", "storage", "vectorDB", "size")
		Expect(size).To(Equal("50Gi"))
		otel, _, _ := unstructured.NestedBool(stored.Object, "spec", "sidecars", "otel")
		prom, _, _ := unstructured.NestedBool(stored.Object, "spec", "sidecars", "prometheusOperator")
		Expect(otel).To(BeTrue())
		Expect(prom).To(BeTrue())
	})

	It("rejects cpuOnly with a partial sidecars object (it picks up the CRD defaults)", func() {
		obj := fromYAML("apiVersion: ai.splunk.com/v1\nkind: AIPlatform\nmetadata: {name: profile-cpuonly-partial}\nspec:\n  profile: cpuOnly\n  sidecars: {envoy: false}\n  objectStorage: {path: s3://bucket, region: us-west-2}\n")
		err := create(obj)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.sidecars"))
	})

	It("rejects cpuOnly with a vectorDB object (it picks up the CRD default size)", func() {
		obj := fromYAML("apiVersion: ai.splunk.com/v1\nkind: AIPlatform\nmetadata: {name: profile-cpuonly-vectordb}\nspec:\n  profile: cpuOnly\n  storage: {vectorDB: {}}\n  objectStorage: {path: s3://bucket, region: us-west-2}\n")
		err := create(obj)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.storage.vectorDB"))
	})

	It("rejects cpuOnly with a GPU setting (the webhook is live)", func() {
		obj := fromYAML("apiVersion: ai.splunk.com/v1\nkind: AIPlatform\nmetadata: {name: profile-bad-cpuonly}\nspec:\n  profile: cpuOnly\n  defaultAcceleratorType: L40S\n  objectStorage: {path: s3://bucket, region: us-west-2}\n")
		err := create(obj)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("spec.defaultAcceleratorType"))
	})
})

func clientKey(obj *unstructured.Unstructured) types.NamespacedName {
	return types.NamespacedName{Namespace: obj.GetNamespace(), Name: obj.GetName()}
}
