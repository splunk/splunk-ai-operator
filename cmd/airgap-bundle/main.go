// Command airgap-bundle describes, verifies and imports the offline bundle of an
// air-gapped AI Tier install.
//
//	airgap-bundle manifest --bundle DIR --snapshot FILE [--model-config FILE] [--id ID]
//	airgap-bundle verify   --bundle DIR --profile cpuOnly|fullfeature [--scope bundle|install] ...
//	airgap-bundle import   --from DIR --to DIR
//
// verify is the preflight an install runs before it changes cluster state. It changes
// nothing, names every missing or altered artifact and unmet host prerequisite, and has
// no download fallback. Exit status: 0 everything is in order, 1 a check found a problem
// or an import was refused, 2 a usage or input error.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/splunk/splunk-ai-operator/internal/airgapbundle"
	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

const defaultCandidate = "config/agent-runtime/candidate-manifest.yaml"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, func(insecure bool) imagesnapshot.Registry {
		return &imagesnapshot.Remote{Insecure: insecure}
	}))
}

type registryFactory func(insecure bool) imagesnapshot.Registry

const usage = `usage: airgap-bundle <command> [flags]

commands:
  manifest   describe a staged bundle: every file with its role and checksum, the
             image archive digests, the model artifacts and the image snapshot
  verify     preflight: check a bundle and the target before an install changes anything
  import     copy a verified bundle into place; safe to retry, a no-op when already done

Run "airgap-bundle <command> -h" for the flags of a command.`

func run(args []string, stdout, stderr io.Writer, newRegistry registryFactory) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	var err error
	switch args[0] {
	case "manifest":
		err = cmdManifest(args[1:], stdout, stderr)
	case "verify":
		err = cmdVerify(context.Background(), args[1:], stdout, stderr, newRegistry)
	case "import":
		err = cmdImport(args[1:], stdout, stderr)
	case "-h", "--help", "help":
		fmt.Fprintln(stdout, usage)
		return 0
	default:
		fmt.Fprintf(stderr, "unknown command %q\n%s\n", args[0], usage)
		return 2
	}
	return exitCode(err, stderr)
}

// problem is an outcome that is not a usage error: the command ran and found something
// wrong. It maps to exit status 1 and has already been reported.
type problem struct{ msg string }

func (p problem) Error() string { return p.msg }

func exitCode(err error, stderr io.Writer) int {
	if err == nil {
		return 0
	}
	var p problem
	if errors.As(err, &p) {
		fmt.Fprintln(stderr, "FAILED:", p.msg)
		return 1
	}
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	fmt.Fprintln(stderr, "error:", imagesnapshot.Sanitize(err.Error()))
	return 2
}

func parse(fs *flag.FlagSet, args []string, stderr io.Writer) error {
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	return nil
}

func cmdManifest(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("manifest", flag.ContinueOnError)
	bundle := fs.String("bundle", "", "staged bundle directory (airgap_install.sh --download-only output)")
	snapshot := fs.String("snapshot", "", "image snapshot manifest.json the install pulls from (default: the bundle's "+airgapbundle.SnapshotFile+")")
	modelConfig := fs.String("model-config", "", "model artifact configuration fullfeature loads (model_artifacts_configs_*.yaml)")
	id := fs.String("id", "", "bundle ID (default: <snapshot id>-<content checksum>)")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	if *bundle == "" {
		return errors.New("--bundle is required")
	}
	if *snapshot == "" {
		*snapshot = filepath.Join(*bundle, filepath.FromSlash(airgapbundle.SnapshotFile))
		if !fileExists(*snapshot) {
			return fmt.Errorf("--snapshot is required, or the bundle must carry its snapshot at %s", airgapbundle.SnapshotFile)
		}
	}
	var models []airgapbundle.Model
	if *modelConfig != "" {
		var err error
		if models, err = airgapbundle.ReadModelConfig(*modelConfig); err != nil {
			return err
		}
	}
	m, err := airgapbundle.Build(*bundle, airgapbundle.BuildOptions{ID: *id, SnapshotPath: *snapshot, Models: models})
	if err != nil {
		return err
	}
	sum, err := airgapbundle.Write(*bundle, m)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "bundle %s: %d files, %d archive images, %d model artifacts, snapshot %s\n",
		m.Metadata.ID, len(m.Spec.Files), len(m.Spec.ArchiveImages), len(m.Spec.Models), m.Spec.Snapshot.ID)
	fmt.Fprintf(stdout, "manifest: %s\nsha256:   %s\n", filepath.Join(*bundle, airgapbundle.ManifestFile), sum)
	return nil
}

func cmdVerify(ctx context.Context, args []string, stdout, stderr io.Writer, newRegistry registryFactory) error {
	fs := flag.NewFlagSet("verify", flag.ContinueOnError)
	bundle := fs.String("bundle", "", "bundle directory")
	profile := fs.String("profile", "", "cpuOnly or fullfeature")
	scope := fs.String("scope", airgapbundle.ScopeInstall, "bundle: the bundle alone (staging host); install: also the snapshot, mirror and target")
	snapshot := fs.String("snapshot", "", "image snapshot manifest.json (install scope; default: the bundle's "+airgapbundle.SnapshotFile+")")
	factsPath := fs.String("facts", "", "host facts JSON the installer collected (install scope)")
	gpus := fs.Int("gpus", 0, "schedulable GPUs fullfeature needs (default 1)")
	insecure := fs.Bool("insecure", false, "allow plain HTTP to the mirror on an isolated network")
	report := fs.String("report", "", "also write the findings as JSON to this file")
	var in imagesnapshot.InputFiles
	fs.StringVar(&in.Candidate, "candidate", defaultCandidate, "agent-runtime candidate manifest")
	fs.StringVar(&in.Config, "config", "", "installer configuration")
	fs.StringVar(&in.CPUOnlyValues, "values-cpuonly", "", "render-profile output for cpuOnly")
	fs.StringVar(&in.FullFeatureValues, "values-fullfeature", "", "render-profile output for fullfeature")
	fs.StringVar(&in.AddonList, "addon-list", "", "add-on image list (default: the bundle's images/addon-images.list)")
	fs.StringVar(&in.K0sList, "k0s-list", "", "k0s image list (default: the bundle's images/k0s-images.list)")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	if *bundle == "" {
		return errors.New("--bundle is required")
	}
	if *profile != imagesnapshot.ProfileCPUOnly && *profile != imagesnapshot.ProfileFullFeature {
		return fmt.Errorf("--profile must be %s or %s", imagesnapshot.ProfileCPUOnly, imagesnapshot.ProfileFullFeature)
	}
	if *scope != airgapbundle.ScopeBundle && *scope != airgapbundle.ScopeInstall {
		return fmt.Errorf("--scope must be %s or %s", airgapbundle.ScopeBundle, airgapbundle.ScopeInstall)
	}
	if *snapshot == "" {
		if p := filepath.Join(*bundle, filepath.FromSlash(airgapbundle.SnapshotFile)); fileExists(p) {
			*snapshot = p
		}
	}
	// The inventory is derived from the bundle's own image lists unless told otherwise,
	// so it is the inventory the snapshot was made from.
	for _, l := range []struct {
		flag *string
		file string
	}{{&in.AddonList, "addon-images.list"}, {&in.K0sList, "k0s-images.list"}} {
		if *l.flag == "" {
			if p := filepath.Join(*bundle, "images", l.file); fileExists(p) {
				*l.flag = p
			}
		}
	}
	// The bundle scope needs only the component switches; it reads a candidate only when
	// one is named, so it runs on a staging host without the repository.
	candidateSet := false
	fs.Visit(func(fl *flag.Flag) { candidateSet = candidateSet || fl.Name == "candidate" })
	if *scope == airgapbundle.ScopeBundle && !candidateSet {
		in.Candidate = ""
	}
	opts := airgapbundle.VerifyOptions{Scope: *scope, Profile: *profile, SnapshotPath: *snapshot, GPUs: *gpus,
		Registry: newRegistry(*insecure)}
	if *factsPath != "" {
		var f airgapbundle.HostFacts
		if err := readJSON(*factsPath, &f); err != nil {
			return fmt.Errorf("host facts: %w", err)
		}
		opts.Facts = &f
	}
	var err error
	if opts.Input, err = imagesnapshot.LoadInput(in); err != nil {
		return err
	}
	if in.Config != "" {
		if opts.MetalLB, err = metallbInstall(in.Config); err != nil {
			return err
		}
	}
	findings := airgapbundle.Verify(ctx, *bundle, opts)
	for _, f := range findings {
		fmt.Fprintln(stderr, imagesnapshot.Sanitize(f.String()))
	}
	if *report != "" {
		if err := writeReport(*report, findings); err != nil {
			fmt.Fprintln(stderr, "warning: could not write the report:", imagesnapshot.Sanitize(err.Error()))
		}
	}
	if len(findings) > 0 {
		return problem{fmt.Sprintf("bundle %s for %s (%s scope): %d problem(s) found; nothing was changed", *bundle, *profile, *scope, len(findings))}
	}
	fmt.Fprintf(stdout, "OK: bundle %s is complete for %s (%s scope)\n", *bundle, *profile, *scope)
	return nil
}

func cmdImport(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	from := fs.String("from", "", "bundle directory to import (as transferred)")
	to := fs.String("to", "", "directory the bundle is imported into, as <to>/<bundle id>")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	if *from == "" || *to == "" {
		return errors.New("--from and --to are required")
	}
	res, err := airgapbundle.Import(*from, *to)
	var blocked *airgapbundle.BlockedError
	if errors.As(err, &blocked) {
		for _, f := range blocked.Findings {
			fmt.Fprintln(stderr, imagesnapshot.Sanitize(f.String()))
		}
		return problem{fmt.Sprintf("import of %s refused: %d problem(s); nothing was accepted", *from, len(blocked.Findings))}
	}
	if err != nil {
		return err
	}
	if res.AlreadyImported {
		fmt.Fprintf(stdout, "OK: bundle %s is already imported at %s; nothing changed\n", res.ID, res.Path)
		return nil
	}
	fmt.Fprintf(stdout, "OK: bundle %s imported at %s (%d files copied, %d reused from an interrupted import)\n", res.ID, res.Path, res.Copied, res.Reused)
	return nil
}

// metallbInstall reads the installer's metallb.install setting (false when absent).
func metallbInstall(config string) (bool, error) {
	var c struct {
		MetalLB struct {
			Install any `json:"install"`
		} `json:"metallb"`
	}
	if err := imagesnapshot.ReadFile(config, &c); err != nil {
		return false, fmt.Errorf("installer config: %w", err)
	}
	switch v := c.MetalLB.Install.(type) {
	case bool:
		return v, nil
	case string:
		return v == "true", nil
	}
	return false, nil
}

func readJSON(p string, v any) error {
	b, err := os.ReadFile(p)
	if err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func writeReport(p string, findings []airgapbundle.Finding) error {
	if findings == nil {
		findings = []airgapbundle.Finding{}
	}
	for i := range findings {
		findings[i].Message = imagesnapshot.Sanitize(findings[i].Message)
	}
	b, err := json.MarshalIndent(struct {
		Findings []airgapbundle.Finding `json:"findings"`
	}{findings}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(p, append(b, '\n'), 0o644)
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}
