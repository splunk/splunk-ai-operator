package imagesnapshot

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"

	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Regression tests for the PR #283 review findings: the installer's defaults and
// images.registry, the operator gate in the install references, refresh pairing of
// shared components, and platform variants of single-manifest images.

func inputWith(t *testing.T, mutateCfg func(*InstallerConfig), values bool) InventoryInput {
	in := fullInput(t)
	in.Installer = InstallerConfig{}
	mutateCfg(&in.Installer)
	if !values {
		in.Values = nil
	}
	return in
}

func sources(images []Image, profile string) map[string]string {
	out := map[string]string{}
	for _, i := range images {
		if hasProfile(i.Profiles, profile) {
			out[i.Component] = i.Source
		}
	}
	return out
}

func refMap(refs []InstallRef) map[string]string {
	out := map[string]string{}
	for _, r := range refs {
		out[r.Component] = r.Ref
	}
	return out
}

// ---- finding 1: images the installer defaults when the configuration omits them ----

func TestInventory_AnOmittedImageTakesTheInstallersDefault(t *testing.T) {
	for _, withValues := range []bool{true, false} {
		in := inputWith(t, func(c *InstallerConfig) {
			c.Images.Operator.Image = "docker.io/splunk/splunk-ai-operator:c1"
			c.Splunk.Enabled = true // internal Splunk mode: the Splunk Operator is installed
		}, withValues)
		inv, err := BuildInventory(in)
		require.NoError(t, err)

		full := sources(inv.Images, ProfileFullFeature)
		assert.Equal(t, DefaultSplunkOperatorImage, full["splunk-operator"], "values=%v", withValues)
		assert.Equal(t, DefaultFluentBitImage, full["fluent-bit"])
		assert.Equal(t, DefaultOtelCollectorImage, full["otel-collector"])
		assert.Equal(t, DefaultNginxImage, full["nginx"])

		cpu := sources(inv.Images, ProfileCPUOnly)
		assert.Equal(t, DefaultFluentBitImage, cpu["fluent-bit"])
		assert.NotContains(t, cpu, "nginx", "nginx is the SAIA front end: fullfeature only")

		// The same images are what an install pulls, so compare accounts for them.
		refs := refMap(InstallRefs(ProfileFullFeature, in))
		assert.Equal(t, DefaultNginxImage, refs["nginx"])
		assert.Equal(t, DefaultFluentBitImage, refs["fluent-bit"])
		assert.Equal(t, DefaultSplunkOperatorImage, refs["splunk-operator"])
	}
}

func TestInventory_AnExplicitImageBeatsTheDefaultAndNullCountsAsOmitted(t *testing.T) {
	in := inputWith(t, func(c *InstallerConfig) {
		c.Images.Nginx.Image = "quay.io/x/nginx:9"
		c.Images.FluentBit.Image = "null"
	}, true)
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	s := sources(inv.Images, ProfileFullFeature)
	assert.Equal(t, "quay.io/x/nginx:9", s["nginx"])
	assert.Equal(t, DefaultFluentBitImage, s["fluent-bit"])
}

func TestInventory_ADefaultFollowsItsComponentSwitch(t *testing.T) {
	// Rendered values switch the OpenTelemetry collector and the Splunk operator off.
	in := inputWith(t, func(c *InstallerConfig) {}, true)
	for _, p := range Profiles {
		in.Values[p].Components["otel"] = false
		in.Values[p].Components["splunkOperator"] = false
	}
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	for _, p := range Profiles {
		s := sources(inv.Images, p)
		assert.NotContains(t, s, "otel-collector", p)
		assert.NotContains(t, s, "splunk-operator", p)
		assert.Contains(t, s, "fluent-bit", p)
	}
}

// Without rendered values the installer configuration's own switches decide, and an
// omitted switch is on, as in k0s_cluster_with_stack.sh.
func TestInventory_WithoutRenderedValuesTheConfigurationComponentSwitchesApply(t *testing.T) {
	in := inputWith(t, func(c *InstallerConfig) {
		c.Components = map[string]any{"otel": false, "splunkOperator": "false", "aiOperator": false, "kuberay": true}
		c.Images.Operator.Image = "docker.io/splunk/splunk-ai-operator:c1"
		c.Images.Ray.HeadImage = "docker.io/rayproject/ray:2.44.0"
	}, false)
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	for _, p := range Profiles {
		s := sources(inv.Images, p)
		assert.NotContains(t, s, "otel-collector", p)
		assert.NotContains(t, s, "splunk-operator", p)
		assert.NotContains(t, s, "splunk-ai-operator", p)
		assert.Contains(t, s, "fluent-bit", p, "an omitted switch is on")
	}
	// An explicit configuration switch is honoured for a profile too (kuberay: true is
	// the installer's request, and the cpuOnly profile default is overridden by it).
	assert.Contains(t, sources(inv.Images, ProfileFullFeature), "ray-head")
	assert.NotContains(t, sources(InstallRefsAsImages(InstallRefs(ProfileFullFeature, in)), ProfileFullFeature), "otel-collector")
}

// InstallRefsAsImages adapts install references for the shared assertions.
func InstallRefsAsImages(refs []InstallRef) []Image {
	var out []Image
	for _, r := range refs {
		out = append(out, Image{Component: r.Component, Source: r.Ref, Profiles: Profiles})
	}
	return out
}

func TestInventory_RenderedValuesWinOverTheConfigurationSwitches(t *testing.T) {
	in := inputWith(t, func(c *InstallerConfig) { c.Components = map[string]any{"otel": false} }, true)
	in.Values[ProfileFullFeature].Components["otel"] = true
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	assert.Contains(t, sources(inv.Images, ProfileFullFeature), "otel-collector")
}

// ---- finding 2: images.registry and build_image_url ----

func TestBuildImageURL_MatchesTheInstallerForEveryShape(t *testing.T) {
	const reg = "registry.airgap.local"
	for ref, want := range map[string]string{
		"splunk/ai-api:v1":                                   reg + "/splunk/ai-api:v1", // no registry host
		"fluent/fluent-bit:1.9.6":                            reg + "/fluent/fluent-bit:1.9.6",
		"docker.io/splunk/splunk-operator:3":                 "docker.io/splunk/splunk-operator:3", // dotted host
		"quay.io/k0sproject/coredns:1.11.3":                  "quay.io/k0sproject/coredns:1.11.3",
		"10.0.0.5:5000/team/img:2":                           "10.0.0.5:5000/team/img:2", // IPv4 with port
		"myhost.example.com:8443/a/b:1":                      "myhost.example.com:8443/a/b:1",
		"localhost:5000/team/img:2":                          reg + "/localhost:5000/team/img:2", // installer quirk: no dot, so prefixed
		"quay.io/team/img":                                   reg + "/quay.io/team/img",          // installer quirk: no tag, so prefixed
		"quay.io/team/img@sha256:" + strings.Repeat("a", 64): "quay.io/team/img@sha256:" + strings.Repeat("a", 64),
	} {
		assert.Equal(t, want, buildImageURL(reg, ref), ref)
	}
	for _, none := range []string{"", "  ", "null"} {
		assert.Equal(t, "splunk/ai-api:v1", buildImageURL(none, "splunk/ai-api:v1"), "registry %q", none)
	}
}

// The Go copy must not drift from the installer's own function: run the real one.
func TestBuildImageURL_AgreesWithTheInstallerFunction(t *testing.T) {
	script, err := os.ReadFile("../../tools/ai-tier-cluster-setup/k0s_cluster_with_stack.sh")
	require.NoError(t, err)
	m := regexp.MustCompile(`(?s)\nbuild_image_url\(\) \{.*?\n\}\n`).Find(script)
	require.NotNil(t, m, "build_image_url not found in the installer")
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	for _, registry := range []string{"", "null", "registry.airgap.local", "10.1.2.3:5000"} {
		for _, ref := range []string{
			"splunk/ai-api:v1", "fluent/fluent-bit:1.9.6", "docker.io/splunk/x:3", "quay.io/a/b:1", "10.0.0.5:5000/t/i:2",
			"localhost:5000/t/i:2", "quay.io/t/i", "quay.io/t/i@sha256:" + strings.Repeat("b", 64), "nginx:1.27", "a.b/c:d",
			"host.example.com:8443/a:b", "1.2.3.4/x:1", "x.y",
		} {
			out, err := exec.Command(bash, "-c", string(m)+`build_image_url "$1" "$2"`, "_", registry, ref).Output()
			require.NoError(t, err)
			assert.Equal(t, strings.TrimSpace(string(out)), buildImageURL(registry, ref), "registry=%q ref=%q", registry, ref)
		}
	}
}

func TestInventory_ImagesRegistryIsAppliedToInstallerConfigImagesOnly(t *testing.T) {
	const reg = "registry.airgap.local"
	for _, withValues := range []bool{true, false} {
		in := inputWith(t, func(c *InstallerConfig) {
			c.Images.Registry = reg
			c.Images.Ray.HeadImage = "rayproject/ray:2.44.0"                  // relative: prefixed
			c.Images.Weaviate.Image = "docker.io/semitechnologies/weaviate:1" // qualified: untouched
			c.Images.Slim.APIImage = "ml-platform/slim:v1"
		}, withValues)
		in.AddonRefs = []string{"quay.io/jetstack/cert-manager-controller:v1.13.0"} // enumerated refs are already full
		inv, err := BuildInventory(in)
		require.NoError(t, err)

		s := sources(inv.Images, ProfileFullFeature)
		assert.Equal(t, reg+"/rayproject/ray:2.44.0", s["ray-head"], "values=%v", withValues)
		assert.Equal(t, "docker.io/semitechnologies/weaviate:1", s["weaviate"])
		assert.Equal(t, reg+"/"+strings.TrimPrefix(DefaultFluentBitImage, ""), s["fluent-bit"], "a relative default is prefixed too")
		assert.Equal(t, DefaultNginxImage, s["nginx"], "a qualified default is not")
		assert.Equal(t, "quay.io/jetstack/cert-manager-controller:v1.13.0", s["cert-manager"], "add-on refs are used as listed")

		// The install references agree with the inventory sources, so compare and the
		// snapshot speak about the same strings.
		refs := refMap(InstallRefs(ProfileFullFeature, in))
		assert.Equal(t, s["ray-head"], refs["ray-head"])
		assert.Equal(t, s["fluent-bit"], refs["fluent-bit"])
		if !withValues {
			assert.Equal(t, reg+"/ml-platform/slim:v1", refs["slim"], "config path applies build_image_url to slim")
		}
	}
}

func TestInventory_NoRegistryLeavesReferencesAsWritten(t *testing.T) {
	in := inputWith(t, func(c *InstallerConfig) { c.Images.Ray.HeadImage = "rayproject/ray:2.44.0" }, true)
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	assert.Equal(t, "rayproject/ray:2.44.0", sources(inv.Images, ProfileFullFeature)["ray-head"])
}

// ---- finding 3: the operator is an install reference only where it is installed ----

func TestInstallRefs_OperatorIsGatedByAIOperator(t *testing.T) {
	for _, withValues := range []bool{true, false} {
		on := inputWith(t, func(c *InstallerConfig) { c.Images.Operator.Image = "docker.io/splunk/splunk-ai-operator:c1" }, withValues)
		if withValues {
			for _, p := range Profiles {
				on.Values[p].Images.Operator = "docker.io/splunk/splunk-ai-operator:c1"
			}
		}
		off := on
		if withValues {
			off.Values = map[string]*RenderedValues{}
			for _, p := range Profiles {
				v := *on.Values[p]
				v.Components = map[string]bool{"aiOperator": false}
				off.Values[p] = &v
			}
		} else {
			off.Installer.Components = map[string]any{"aiOperator": false}
		}
		for _, p := range Profiles {
			n := 0
			for _, r := range InstallRefs(p, on) {
				if r.Component == "splunk-ai-operator" {
					n++
				}
			}
			assert.Equal(t, 1, n, "the operator is listed once, from rendered values when there are some (values=%v %s)", withValues, p)
			assert.Equal(t, "docker.io/splunk/splunk-ai-operator:c1", refMap(InstallRefs(p, on))["splunk-ai-operator"], "on values=%v %s", withValues, p)
			assert.NotContains(t, refMap(InstallRefs(p, off)), "splunk-ai-operator", "off values=%v %s", withValues, p)
		}
		inv, err := BuildInventory(off)
		require.NoError(t, err)
		assert.NotContains(t, components(inv.Images), "splunk-ai-operator", "the inventory agrees")
	}
}

// ---- finding 4: refresh pairs the images of a shared component correctly ----

func twoTagSnapshot(t *testing.T) (src, dst *testRegistry, inv *Inventory, prev *Snapshot, digests map[string]string) {
	src, dst = newTestRegistry(t), newTestRegistry(t)
	digests = map[string]string{}
	for _, tag := range []string{"v1", "v2", "v3"} {
		digests[tag] = src.pushImage("monitoring/prom", tag, "linux", "amd64", nil)
	}
	digests["alert"] = src.pushImage("monitoring/alertmanager", "v1", "linux", "amd64", nil)
	inv = inventoryOf(
		imageOf("monitoring-stack", src.ref("monitoring/prom", "v1")),
		imageOf("monitoring-stack", src.ref("monitoring/prom", "v2")),
		imageOf("monitoring-stack", src.ref("monitoring/alertmanager", "v1")),
	)
	var err error
	prev, err = Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "run-1"})
	require.NoError(t, err)
	return
}

func TestRefresh_TwoTagsOfOneRepositoryUnderOneComponentAreNotCollapsed(t *testing.T) {
	src, _, inv, prev, d := twoTagSnapshot(t)
	require.Len(t, prev.Spec.Entries, 3)

	t.Run("an unchanged inventory is no change, not a spurious one", func(t *testing.T) {
		reg := newCounting()
		_, err := Refresh(context.Background(), reg, prev, inv, RefreshOptions{ID: "run-2"})
		assert.True(t, errors.Is(err, ErrNoChange), "%v", err)
		assert.Empty(t, reg.Describes)
	})

	t.Run("replacing one tag changes only that image and records its old digest", func(t *testing.T) {
		next := inventoryOf(
			imageOf("monitoring-stack", src.ref("monitoring/prom", "v1")),
			imageOf("monitoring-stack", src.ref("monitoring/prom", "v3")), // v2 -> v3
			imageOf("monitoring-stack", src.ref("monitoring/alertmanager", "v1")),
		)
		next.Candidate.Checksum = strings.Repeat("e", 64)
		sum, _ := next.computeChecksum()
		next.Checksum = sum
		res, err := Refresh(context.Background(), newCounting(), prev, next, RefreshOptions{ID: "run-2"})
		require.NoError(t, err)
		require.Len(t, res.Changes, 1, "v1 and alertmanager are carried; v2 -> v3 is one tag change")
		c := res.Changes[0]
		assert.Equal(t, ChangeSource, c.Reason)
		assert.Equal(t, d["v2"], c.PreviousDigest, "the replaced image's own digest, not v1's")
		assert.Equal(t, d["v3"], c.Digest)
		for _, e := range res.Snapshot.Spec.Entries {
			if strings.HasSuffix(e.Source, "prom:v1") {
				assert.Equal(t, d["v1"], e.Digest, "v1 is carried unchanged")
				assert.Empty(t, e.PreviousDigest)
			}
		}
	})
}

// A component with a single image whose source changes is a source change, with the
// previous digest; and two images moving at once are paired by repository.
func TestRefresh_PairingByRepositoryAndByLoneComponent(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	a1 := src.pushImage("m/a", "1", "linux", "amd64", nil)
	b1 := src.pushImage("m/b", "1", "linux", "amd64", nil)
	a2 := src.pushImage("m/a", "2", "linux", "amd64", nil)
	b2 := src.pushImage("m/b", "2", "linux", "amd64", nil)
	solo1 := src.pushImage("solo/old", "1", "linux", "amd64", nil)
	solo2 := src.pushImage("solo/new", "1", "linux", "amd64", nil)
	inv := inventoryOf(
		imageOf("stack", src.ref("m/a", "1")), imageOf("stack", src.ref("m/b", "1")), imageOf("solo", src.ref("solo/old", "1")))
	prev, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "run-1"})
	require.NoError(t, err)

	next := inventoryOf(
		imageOf("stack", src.ref("m/a", "2")), imageOf("stack", src.ref("m/b", "2")), imageOf("solo", src.ref("solo/new", "1")))
	next.Candidate.Checksum = strings.Repeat("e", 64)
	sum, _ := next.computeChecksum()
	next.Checksum = sum
	res, err := Refresh(context.Background(), newCounting(), prev, next, RefreshOptions{ID: "run-2"})
	require.NoError(t, err)

	old := map[string]string{}
	for _, c := range res.Changes {
		assert.Equal(t, ChangeSource, c.Reason, "%+v", c)
		old[c.Digest] = c.PreviousDigest
	}
	assert.Equal(t, map[string]string{a2: a1, b2: b1, solo2: solo1}, old, "each image is paired with its own predecessor")
}

// Ambiguity must not guess: two new tags of one repository replacing two old ones
// is reported as new and removed rather than cross-paired.
func TestRefresh_AmbiguousPairingIsReportedAsNewAndRemoved(t *testing.T) {
	pairs := pairEntries(
		[]Entry{{Image: Image{Component: "c", Source: "r.io/x/p:1"}}, {Image: Image{Component: "c", Source: "r.io/x/p:2"}}},
		[]Image{{Component: "c", Source: "r.io/x/p:3"}, {Component: "c", Source: "r.io/x/p:4"}})
	assert.Equal(t, []int{-1, -1}, pairs)

	pairs = pairEntries(
		[]Entry{{Image: Image{Component: "c", Source: "r.io/x/p:1"}}, {Image: Image{Component: "c", Source: "r.io/x/p:2"}}},
		[]Image{{Component: "c", Source: "r.io/x/p:3"}})
	assert.Equal(t, []int{-1}, pairs, "one new tag cannot tell which of two old tags it replaces")

	// A component with several images is never paired by "the only one left": q -> r is
	// not known to be a replacement, so it is a removal and an addition.
	pairs = pairEntries(
		[]Entry{{Image: Image{Component: "c", Source: "r.io/x/p:1"}}, {Image: Image{Component: "c", Source: "r.io/x/q:1"}}},
		[]Image{{Component: "c", Source: "r.io/x/p:1"}, {Component: "c", Source: "r.io/x/r:1"}})
	assert.Equal(t, []int{0, -1}, pairs)

	pairs = pairEntries(
		[]Entry{{Image: Image{Component: "c", Source: "r.io/x/p:1"}}, {Image: Image{Component: "c", Source: "r.io/x/q:1"}}},
		[]Image{{Component: "c", Source: "r.io/x/q:2"}, {Component: "c", Source: "r.io/x/p:2"}})
	assert.Equal(t, []int{1, 0}, pairs, "distinct repositories pair unambiguously, whatever the order")

	pairs = pairEntries(
		[]Entry{{Image: Image{Component: "c", Source: "r.io/x/p:1"}}},
		[]Image{{Component: "c", Source: "r.io/x/p:1"}, {Component: "c", Source: "r.io/x/p:2"}})
	assert.Equal(t, []int{0, -1}, pairs, "an exact match is taken before any inference")
}

// ---- finding 5: a platform variant of a single-manifest image ----

func pushVariantImage(t *testing.T, r *testRegistry, repo, tag, arch, variant string) string {
	t.Helper()
	img := platformImage(t, "linux", arch, nil)
	cfg, err := img.ConfigFile()
	require.NoError(t, err)
	cfg = cfg.DeepCopy()
	cfg.Variant = variant
	img, err = mutate.ConfigFile(img, cfg)
	require.NoError(t, err)
	ref, err := name.NewTag(r.ref(repo, tag))
	require.NoError(t, err)
	require.NoError(t, remote.Write(ref, img))
	d, err := img.Digest()
	require.NoError(t, err)
	return d.String()
}

func TestDescribe_ASingleManifestKeepsItsPlatformVariant(t *testing.T) {
	src := newTestRegistry(t)
	pushVariantImage(t, src, "t/v3", "v1", "amd64", "v3")
	plain := pushVariantImage(t, src, "t/plain", "v1", "amd64", "")
	arm := pushVariantImage(t, src, "t/arm", "v1", "arm", "v7")

	d, err := (&Remote{}).Describe(context.Background(), src.ref("t/v3", "v1"))
	require.NoError(t, err)
	assert.Contains(t, d.PlatformDigests, "linux/amd64/v3")
	assert.NotContains(t, d.PlatformDigests, "linux/amd64")

	d, err = (&Remote{}).Describe(context.Background(), src.ref("t/plain", "v1"))
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"linux/amd64": plain}, d.PlatformDigests, "no variant: unchanged")

	d, err = (&Remote{}).Describe(context.Background(), src.ref("t/arm", "v1"))
	require.NoError(t, err)
	assert.Equal(t, map[string]string{"linux/arm/v7": arm}, d.PlatformDigests)
}

func TestCreate_ASingleManifestOfAVariantIsIncompatibleNotLinuxAmd64(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	pushVariantImage(t, src, "t/v3", "v1", "amd64", "v3")
	reg := newCounting()
	_, err := Create(context.Background(), reg, inventoryOf(imageOf("v3", src.ref("t/v3", "v1"))), Options{Mirror: dst.Host})
	var blocked *BlockedError
	require.ErrorAs(t, err, &blocked)
	assert.Contains(t, blocked.Blockers[0].Reason, "incompatible: no linux/amd64 image (available: linux/amd64/v3)")
	assert.Empty(t, reg.Copies)
}

func TestInventory_NoInstallerConfigurationMeansNoInstallerDefaults(t *testing.T) {
	in := inputWith(t, func(c *InstallerConfig) {}, true)
	in.NoInstallerDefaults = true
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	for _, c := range []string{"fluent-bit", "otel-collector", "nginx", "splunk-operator"} {
		assert.NotContains(t, components(inv.Images), c)
	}
	assert.Empty(t, InstallRefs(ProfileFullFeature, InventoryInput{NoInstallerDefaults: true}))
}

// The in-cluster Splunk Operator and Standalone exist only in the installer's "internal"
// Splunk mode: splunk.enabled true and no external endpoint.
func TestInventory_SplunkImagesFollowTheInstallersSplunkMode(t *testing.T) {
	for name, tc := range map[string]struct {
		set  func(*InstallerConfig)
		want bool
	}{
		"omitted splunk block":     {func(c *InstallerConfig) {}, false},
		"enabled false":            {func(c *InstallerConfig) { c.Splunk.Enabled = false }, false},
		"enabled as a string true": {func(c *InstallerConfig) { c.Splunk.Enabled = "true" }, true},
		"enabled as a string yes":  {func(c *InstallerConfig) { c.Splunk.Enabled = "yes" }, false},
		"internal":                 {func(c *InstallerConfig) { c.Splunk.Enabled = true }, true},
		"external endpoint": {func(c *InstallerConfig) {
			c.Splunk.Enabled = true
			c.Splunk.External.Endpoint = "https://splunk.example.com:8088"
		}, false},
		"null external endpoint": {func(c *InstallerConfig) { c.Splunk.Enabled = true; c.Splunk.External.Endpoint = "null" }, true},
		"enabled but switches off": {func(c *InstallerConfig) {
			c.Splunk.Enabled = true
			c.Components = map[string]any{"splunkOperator": false, "splunkStandalone": false}
		}, false},
	} {
		for _, withValues := range []bool{true, false} {
			in := inputWith(t, func(c *InstallerConfig) {
				tc.set(c)
				c.Images.Splunk.Image = "docker.io/splunk/splunk:9.4"
			}, withValues)
			inv, err := BuildInventory(in)
			require.NoError(t, err)
			for _, p := range Profiles {
				s := sources(inv.Images, p)
				refs := refMap(InstallRefs(p, in))
				for _, c := range []string{"splunk-operator", "splunk-standalone"} {
					_, inInv := s[c]
					_, inRefs := refs[c]
					assert.Equal(t, tc.want, inInv, "%s: %s in inventory (values=%v %s)", name, c, withValues, p)
					assert.Equal(t, tc.want, inRefs, "%s: %s in install refs (values=%v %s)", name, c, withValues, p)
				}
			}
		}
	}
}

// The default constants are the installer's own literals.
func TestInstallerDefaults_AreTheInstallersLiterals(t *testing.T) {
	script, err := os.ReadFile("../../tools/ai-tier-cluster-setup/k0s_cluster_with_stack.sh")
	require.NoError(t, err)
	for variable, want := range map[string]string{
		"SPLUNK_OPERATOR_IMAGE": DefaultSplunkOperatorImage,
		"FLUENT_BIT_IMAGE":      DefaultFluentBitImage,
		"OTEL_COLLECTOR_IMAGE":  DefaultOtelCollectorImage,
		"NGINX_IMAGE":           DefaultNginxImage,
	} {
		assert.Contains(t, string(script), "\n    "+variable+"=\""+want+"\"\n", variable)
	}
}

// With no rendered values the profile gating of the install references still applies.
func TestInstallRefs_ConfigPathKeepsProfileGating(t *testing.T) {
	in := inputWith(t, func(c *InstallerConfig) {
		c.Images.Ray.HeadImage = "docker.io/rayproject/ray:2.44.0"
		c.Images.Weaviate.Image = "docker.io/semitechnologies/weaviate:1"
	}, false)
	cpu, full := refMap(InstallRefs(ProfileCPUOnly, in)), refMap(InstallRefs(ProfileFullFeature, in))
	for _, c := range []string{"ray-head", "weaviate", "nginx"} {
		assert.NotContains(t, cpu, c)
		assert.Contains(t, full, c)
	}
}

// A configuration that omits images, read with NoInstallerDefaults, names no defaults.
func TestInventory_NoInstallerDefaultsAlsoAppliesToAConfigurationThatOmitsImages(t *testing.T) {
	in := inputWith(t, func(c *InstallerConfig) { c.Splunk.Enabled = true }, true)
	in.NoInstallerDefaults = true
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	assert.NotContains(t, components(inv.Images), "splunk-operator")
	assert.NotContains(t, refMap(InstallRefs(ProfileFullFeature, in)), "fluent-bit")
}

// ---- ERD FR-16 / §14.4.4: versioned base pins and providers beyond the candidate ----

func pinsInput(t *testing.T, values bool) InventoryInput {
	return inputWith(t, func(c *InstallerConfig) {
		c.Images.Registry = "registry.airgap.local"
		c.Images.AgentRuntime.BaseImages = map[string]string{
			"v1.9.0": "docker.io/splunk/agent-runtime:v1.9.0", // an older supported pin
			"v2.0.0": "docker.io/splunk/agent-runtime:v2.0.0", // the candidate's runtimeVersion
			"v3-rc":  "splunk/agent-runtime:v3-rc",            // relative: images.registry applies
			"blank":  "null",
		}
		c.Images.AgentRuntime.ProviderImages = map[string]string{
			"mltk": "docker.io/splunk/agent-runtime-provider-mltk:0.1.0", // the candidate's provider
			"seca": "docker.io/splunk/agent-runtime-provider-seca:0.2.0", // not in the candidate
		}
	}, values)
}

func TestInventory_VersionedBasePinsAndExtraProvidersAreInventoried(t *testing.T) {
	for _, withValues := range []bool{true, false} {
		in := pinsInput(t, withValues)
		require.Equal(t, "v2.0.0", in.Candidate.Spec.RuntimeVersion, "fixture assumption")
		inv, err := BuildInventory(in)
		require.NoError(t, err)
		c := components(inv.Images)

		assert.Equal(t, "docker.io/splunk/agent-runtime:v1.9.0", c["agent-runtime-base-v1-9-0"].Source, "values=%v", withValues)
		assert.Equal(t, "registry.airgap.local/splunk/agent-runtime:v3-rc", c["agent-runtime-base-v3-rc"].Source)
		assert.Equal(t, Profiles, c["agent-runtime-base-v1-9-0"].Profiles, "the operator may select a pin in either profile")
		assert.Equal(t, "installer-config:images.agentRuntime.baseImages.v1.9.0", c["agent-runtime-base-v1-9-0"].Origin)
		assert.NotContains(t, c, "agent-runtime-base-v2-0-0", "the candidate's own runtimeVersion is the candidate base image")
		assert.NotContains(t, c, "agent-runtime-base-blank")

		assert.Equal(t, "docker.io/splunk/agent-runtime-provider-seca:0.2.0", c["agent-runtime-provider-seca"].Source)
		assert.Equal(t, "candidate-manifest:components.launchpadCarrier", c["agent-runtime-provider-mltk"].Origin,
			"the candidate stays authoritative for its own provider")
	}
}

func TestInstallRefs_VersionedBasePinsAreCheckedAndTheCandidatePinIsTheCandidateBase(t *testing.T) {
	for _, withValues := range []bool{true, false} {
		in := pinsInput(t, withValues)
		for _, p := range Profiles {
			refs := InstallRefs(p, in)
			got := map[string][]string{}
			for _, r := range refs {
				got[r.Component] = append(got[r.Component], r.Ref)
			}
			assert.Equal(t, []string{"docker.io/splunk/agent-runtime:v1.9.0"}, got["agent-runtime-base-v1-9-0"], "values=%v %s", withValues, p)
			assert.Contains(t, got["agent-runtime-base"], "docker.io/splunk/agent-runtime:v2.0.0",
				"the v2.0.0 pin is checked as the candidate base, so a pin to another image is caught")
			assert.Equal(t, []string{"docker.io/splunk/agent-runtime-provider-seca:0.2.0"}, got["agent-runtime-provider-seca"],
				"a configured provider without a feature is still set on the operator")
		}
	}
}

func TestInventory_PinsFollowTheAIOperator(t *testing.T) {
	in := pinsInput(t, false)
	in.Installer.Components = map[string]any{"aiOperator": false}
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	assert.NotContains(t, components(inv.Images), "agent-runtime-base-v1-9-0")
	assert.NotContains(t, components(inv.Images), "agent-runtime-provider-seca")
	assert.NotContains(t, refMap(InstallRefs(ProfileCPUOnly, in)), "agent-runtime-base-v1-9-0")
}

// The pin for the candidate's runtimeVersion pointing at a different image (or at the
// public registry) is a finding, not a pass.
func TestCompare_ACandidatePinToAnotherImageIsAFinding(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("ml/agent-runtime", "c1", "linux", "amd64", nil)
	src.pushImage("ml/agent-runtime", "old", "linux", "amd64", nil)
	inv := inventoryOf(imageOf("agent-runtime-base", src.ref("ml/agent-runtime", "c1")))
	snap, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "pins"})
	require.NoError(t, err)
	mirror := snap.Spec.Entries[0].MirrorRef

	assert.Empty(t, Compare(snap, ProfileCPUOnly, []InstallRef{{"agent-runtime-base", mirror}}))
	got := Compare(snap, ProfileCPUOnly, []InstallRef{{"agent-runtime-base", src.ref("ml/agent-runtime", "old")}})
	require.Len(t, got, 1)
	assert.Equal(t, FindingSourceRegistry, got[0].Code)
}

func TestEnvSegment_MatchesTheOperatorsNormalisation(t *testing.T) {
	for in, want := range map[string]string{"v2.0.0": "V2_0_0", "v1.9.0-rc.1": "V1_9_0_RC_1", "--x..y--": "X_Y", "mltk": "MLTK", "a__b": "A_B"} {
		assert.Equal(t, want, envSegment(in), in)
	}
	assert.Equal(t, "agent-runtime-base-v2-0-0", baseVersionComponent("v2.0.0"))
}

// PR #283 review (262eaa4): configuration-only providers feed only the operator's
// environment, so with the operator off they are not install references, matching the
// inventory; otherwise compare reports a correctly mirrored install as unaccounted.
func TestInstallRefs_ConfigurationOnlyProvidersFollowTheAIOperator(t *testing.T) {
	for _, withValues := range []bool{true, false} {
		in := pinsInput(t, withValues)
		if withValues {
			for _, p := range Profiles {
				in.Values[p].Components["aiOperator"] = false
			}
		} else {
			in.Installer.Components = map[string]any{"aiOperator": false}
		}
		inv, err := BuildInventory(in)
		require.NoError(t, err)
		require.NotContains(t, components(inv.Images), "agent-runtime-provider-seca", "values=%v", withValues)
		for _, p := range Profiles {
			refs := refMap(InstallRefs(p, in))
			assert.NotContains(t, refs, "agent-runtime-provider-seca", "values=%v %s", withValues, p)
			assert.NotContains(t, refs, "agent-runtime-base-v1-9-0", "values=%v %s", withValues, p)
			if !withValues {
				// The candidate's own provider is a candidate image, checked like the
				// candidate base, schema setup and SLIM references whatever the operator.
				assert.Equal(t, "docker.io/splunk/agent-runtime-provider-mltk:0.1.0", refs["agent-runtime-provider-mltk"], p)
			}
		}
	}
	// With the operator on they are references, as before.
	on := pinsInput(t, false)
	assert.Contains(t, refMap(InstallRefs(ProfileCPUOnly, on)), "agent-runtime-provider-seca")
}
