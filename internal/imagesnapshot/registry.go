package imagesnapshot

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

// Described is what a registry says about a reference.
type Described struct {
	// Digest is what the reference resolved to: the index digest for a multi-platform
	// image, the manifest digest otherwise.
	Digest string
	// PlatformDigests maps "os/arch" to the digest of that platform's manifest. A
	// single-platform image has one entry whose digest equals Digest.
	PlatformDigests map[string]string
	// Labels are the OCI labels of the linux/amd64 image, when it has one.
	Labels map[string]string
}

// Platforms lists the described platforms in a stable order.
func (d *Described) Platforms() []string { return sortedKeys(d.PlatformDigests) }

// Registry is the part of a container registry this package needs.
type Registry interface {
	// Describe resolves ref (a tag or a digest reference) without copying anything.
	Describe(ctx context.Context, ref string) (*Described, error)
	// Copy copies the manifest and blobs behind srcRef, a digest reference, to dstRef,
	// a digest reference with the same digest.
	Copy(ctx context.Context, srcRef, dstRef string) error
}

// Remote talks to real registries using the credentials in the local Docker
// configuration, the same way `docker pull` does. Credentials are never read into,
// or written to, a snapshot.
type Remote struct {
	// Insecure allows plain HTTP, for a mirror on an isolated network without TLS.
	Insecure bool
}

func (r *Remote) nameOpts() []name.Option {
	if r.Insecure {
		return []name.Option{name.Insecure}
	}
	return nil
}

func (r *Remote) remoteOpts(ctx context.Context) []remote.Option {
	return []remote.Option{remote.WithContext(ctx), remote.WithAuthFromKeychain(authn.DefaultKeychain)}
}

// Describe implements Registry.
func (r *Remote) Describe(ctx context.Context, ref string) (*Described, error) {
	parsed, err := name.ParseReference(ref, r.nameOpts()...)
	if err != nil {
		return nil, fmt.Errorf("invalid image reference: %w", err)
	}
	desc, err := remote.Get(parsed, r.remoteOpts(ctx)...)
	if err != nil {
		return nil, err
	}
	out := &Described{Digest: desc.Digest.String(), PlatformDigests: map[string]string{}}

	switch {
	case desc.MediaType.IsIndex():
		idx, err := desc.ImageIndex()
		if err != nil {
			return nil, err
		}
		manifest, err := idx.IndexManifest()
		if err != nil {
			return nil, err
		}
		for _, m := range manifest.Manifests {
			// Skip attestation and other non-runnable entries (platform unknown/unknown).
			if m.Platform == nil || m.Platform.OS == "" || m.Platform.OS == "unknown" || m.Platform.Architecture == "unknown" {
				continue
			}
			p := m.Platform.OS + "/" + m.Platform.Architecture
			if m.Platform.Variant != "" {
				p += "/" + m.Platform.Variant // linux/arm/v7 and linux/amd64/v3 are not linux/arm64 or linux/amd64
			}
			if _, seen := out.PlatformDigests[p]; !seen {
				out.PlatformDigests[p] = m.Digest.String()
			}
		}
		if d, ok := out.PlatformDigests[Platform]; ok {
			if h, err := v1.NewHash(d); err == nil {
				if img, err := idx.Image(h); err == nil {
					out.Labels = labelsOf(img)
				}
			}
		}
	case desc.MediaType.IsImage():
		img, err := desc.Image()
		if err != nil {
			return nil, err
		}
		cfg, err := img.ConfigFile()
		if err != nil {
			return nil, err
		}
		if cfg.OS != "" && cfg.Architecture != "" {
			key := cfg.OS + "/" + cfg.Architecture
			if cfg.Variant != "" {
				key += "/" + cfg.Variant // a linux/amd64/v3 image is not a linux/amd64 image
			}
			out.PlatformDigests[key] = desc.Digest.String()
		}
		out.Labels = cfg.Config.Labels
	default:
		return nil, fmt.Errorf("unsupported manifest type %q", desc.MediaType)
	}
	return out, nil
}

func labelsOf(img v1.Image) map[string]string {
	cfg, err := img.ConfigFile()
	if err != nil || cfg == nil {
		return nil
	}
	return cfg.Config.Labels
}

// Copy implements Registry.
func (r *Remote) Copy(ctx context.Context, srcRef, dstRef string) error {
	src, err := name.NewDigest(srcRef, r.nameOpts()...)
	if err != nil {
		return fmt.Errorf("source must be a digest reference: %w", err)
	}
	dst, err := name.NewDigest(dstRef, r.nameOpts()...)
	if err != nil {
		return fmt.Errorf("destination must be a digest reference: %w", err)
	}
	img, err := remote.Image(src, r.remoteOpts(ctx)...)
	if err != nil {
		return err
	}
	return remote.Write(dst, img, r.remoteOpts(ctx)...)
}

// ParsedRef is an image reference split into its parts, with Docker Hub spelled
// the way a person writes it.
type ParsedRef struct {
	Registry   string // "docker.io", "quay.io", "127.0.0.1:5000"
	Repository string // "splunk/ai-tier-slim-service", "library/nginx"
	Tag        string
	Digest     string
}

// ParseRef splits a reference. A bare name such as "nginx:1.27" is Docker Hub's
// library/nginx.
func ParseRef(ref string) (ParsedRef, error) {
	parsed, err := name.ParseReference(strings.TrimSpace(ref))
	if err != nil {
		return ParsedRef{}, fmt.Errorf("invalid image reference %q: %w", ref, err)
	}
	p := ParsedRef{Registry: parsed.Context().RegistryStr(), Repository: parsed.Context().RepositoryStr()}
	if p.Registry == "index.docker.io" {
		p.Registry = "docker.io"
	}
	switch v := parsed.(type) {
	case name.Tag:
		p.Tag = v.TagStr()
	case name.Digest:
		p.Digest = v.DigestStr()
	}
	return p, nil
}

// String renders the reference, preferring a digest.
func (p ParsedRef) String() string {
	base := p.Registry + "/" + p.Repository
	switch {
	case p.Digest != "":
		return base + "@" + p.Digest
	case p.Tag != "":
		return base + ":" + p.Tag
	}
	return base
}

var unsafePathChars = regexp.MustCompile(`[^a-z0-9._/-]+`)

// MirrorRepository returns the repository in the mirror that a source repository is
// copied to: the mirror prefix, then the source registry host, then the source
// repository path. Keeping the host stops docker.io/splunk/x and quay.io/splunk/x from
// colliding; the path is lower-cased and a port's colon becomes a dash.
func MirrorRepository(mirror string, p ParsedRef) string {
	host := strings.ReplaceAll(strings.ToLower(p.Registry), ":", "-")
	return strings.TrimSuffix(mirror, "/") + "/" + unsafePathChars.ReplaceAllString(host+"/"+strings.ToLower(p.Repository), "-")
}

// credentialPatterns match the shapes a credential takes in an error message. They run in
// order: a whole Authorization header first, so the scheme word and the token after it
// are removed together; then a bare Basic or Bearer token; then userinfo in a URL; then
// a credential-looking key with its value, in key=value, key: value and JSON forms.
var credentialPatterns = []struct {
	re   *regexp.Regexp
	with string
}{
	{regexp.MustCompile(`(?i)\b(?:proxy-)?authorization\b["']?\s*[:=]\s*["']?(?:(?:basic|bearer|digest|negotiate)\s+)?[^\s"',}]+`), "[redacted]"},
	{regexp.MustCompile(`(?i)\b(?:basic|bearer)\s+[A-Za-z0-9._~+/=-]{4,}`), "[redacted]"},
	{regexp.MustCompile(`://[^/\s"'@]+@`), "://[redacted]@"},
	{regexp.MustCompile(`(?i)["']?\b(?:password|passwd|pwd|token|secret|apikey|api_key|auth|credentials?|identitytoken|registrytoken)\b["']?\s*[:=]\s*["']?[^\s"',}]+`), "[redacted]"},
}

// Sanitize removes anything credential-shaped from an error message and bounds its
// length, so a registry error can be recorded in a snapshot without leaking.
func Sanitize(msg string) string {
	for _, p := range credentialPatterns {
		msg = p.re.ReplaceAllString(msg, p.with)
	}
	msg = strings.Join(strings.Fields(msg), " ")
	if len(msg) > 300 {
		msg = msg[:300] + "..."
	}
	return msg
}
