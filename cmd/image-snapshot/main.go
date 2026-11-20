// Command image-snapshot builds, verifies and refreshes the snapshot of the container
// images an AI Tier install needs.
//
//	image-snapshot inventory --candidate FILE [--config FILE] ...
//	image-snapshot create    --mirror HOST[/PREFIX] --store DIR ...
//	image-snapshot verify    --store DIR --id ID --profile cpuOnly|fullfeature ...
//	image-snapshot compare   --store DIR --id ID --profile ... ...
//	image-snapshot refresh   --store DIR --previous ID --id ID ...
//
// It reads registry credentials only from the local Docker configuration, never
// writes one, and exits 0 when everything is in order, 1 when a snapshot is blocked
// or a check finds a problem, and 2 on a usage or input error.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/splunk/splunk-ai-operator/internal/candidatecontract"
	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

const defaultCandidate = "config/agent-runtime/candidate-manifest.yaml"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, func(insecure bool) imagesnapshot.Registry {
		return &imagesnapshot.Remote{Insecure: insecure}
	}))
}

type registryFactory func(insecure bool) imagesnapshot.Registry

const usage = `usage: image-snapshot <command> [flags]

commands:
  inventory   list every image each profile needs, derived from the candidate record
  create      resolve, mirror and verify the inventory and store a snapshot
  verify      preflight: check the mirror against a stored snapshot for one profile
  compare     check the images an install will use against a stored snapshot
  refresh     derive a new snapshot from a stored one, redoing only what changed

Run "image-snapshot <command> -h" for the flags of a command.`

func run(args []string, stdout, stderr io.Writer, newRegistry registryFactory) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	ctx := context.Background()
	var err error
	switch args[0] {
	case "inventory":
		err = cmdInventory(ctx, args[1:], stdout, stderr)
	case "create":
		err = cmdCreate(ctx, args[1:], stdout, stderr, newRegistry)
	case "verify":
		err = cmdVerify(ctx, args[1:], stdout, stderr, newRegistry)
	case "compare":
		err = cmdCompare(args[1:], stdout, stderr)
	case "refresh":
		err = cmdRefresh(ctx, args[1:], stdout, stderr, newRegistry)
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
	fmt.Fprintln(stderr, "error:", err)
	return 2
}

// inputFlags are the inputs every command derives the inventory from.
type inputFlags struct {
	candidate, config, cpuOnlyValues, fullFeatureValues, addonList, k0sList, owners string
}

func (f *inputFlags) register(fs *flag.FlagSet) {
	fs.StringVar(&f.candidate, "candidate", defaultCandidate, "agent-runtime candidate manifest")
	fs.StringVar(&f.config, "config", "", "installer configuration file (images outside the candidate set)")
	fs.StringVar(&f.cpuOnlyValues, "values-cpuonly", "", "render-profile output for cpuOnly")
	fs.StringVar(&f.fullFeatureValues, "values-fullfeature", "", "render-profile output for fullfeature")
	fs.StringVar(&f.addonList, "addon-list", "", "add-on image list (addon-images.list from the air-gap bundle)")
	fs.StringVar(&f.k0sList, "k0s-list", "", "k0s system image list (k0s airgap list-images)")
	fs.StringVar(&f.owners, "owners", "", "YAML map of component to owner")
}

func (f *inputFlags) load() (imagesnapshot.InventoryInput, error) {
	var in imagesnapshot.InventoryInput
	var m candidatecontract.Manifest
	if err := candidatecontract.Read(f.candidate, &m); err != nil {
		return in, fmt.Errorf("candidate manifest: %w", err)
	}
	if err := m.Validate(); err != nil {
		return in, fmt.Errorf("candidate manifest %s is not a valid candidate record: %w", f.candidate, err)
	}
	raw, err := os.ReadFile(f.candidate)
	if err != nil {
		return in, err
	}
	in.Candidate, in.CandidateChecksum = &m, imagesnapshot.Checksum(raw)

	if f.config != "" {
		if err := imagesnapshot.ReadFile(f.config, &in.Installer); err != nil {
			return in, fmt.Errorf("installer config: %w", err)
		}
	} else {
		// With no installer configuration there is no installer whose defaults apply.
		in.NoInstallerDefaults = true
	}
	in.Values = map[string]*imagesnapshot.RenderedValues{}
	for profile, path := range map[string]string{imagesnapshot.ProfileCPUOnly: f.cpuOnlyValues, imagesnapshot.ProfileFullFeature: f.fullFeatureValues} {
		if path == "" {
			continue
		}
		var v imagesnapshot.RenderedValues
		if err := imagesnapshot.ReadFile(path, &v); err != nil {
			return in, fmt.Errorf("rendered values for %s: %w", profile, err)
		}
		if v.Profile.Effective != "" && v.Profile.Effective != profile {
			return in, fmt.Errorf("%s is the rendered profile %q, not %q", path, v.Profile.Effective, profile)
		}
		in.Values[profile] = &v
	}
	if in.AddonRefs, err = readLines(f.addonList); err != nil {
		return in, err
	}
	if in.K0sRefs, err = readLines(f.k0sList); err != nil {
		return in, err
	}
	if f.owners != "" {
		if err := imagesnapshot.ReadFile(f.owners, &in.Owners); err != nil {
			return in, fmt.Errorf("owners: %w", err)
		}
	}
	return in, nil
}

func readLines(path string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return strings.Split(string(b), "\n"), nil
}

func parse(fs *flag.FlagSet, args []string, stderr io.Writer) error {
	fs.SetOutput(stderr)
	return fs.Parse(args)
}

func writeJSON(w io.Writer, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "%s\n", b)
	return err
}

func cmdInventory(_ context.Context, args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("inventory", flag.ContinueOnError)
	var in inputFlags
	in.register(fs)
	profile := fs.String("profile", "", "list only the images this profile needs (default: both)")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	input, err := in.load()
	if err != nil {
		return err
	}
	inv, err := imagesnapshot.BuildInventory(input)
	if err != nil {
		return err
	}
	if *profile != "" {
		if !validProfile(*profile) {
			return fmt.Errorf("unknown profile %q", *profile)
		}
		inv.Images = inv.ForProfile(*profile)
	}
	return writeJSON(stdout, inv)
}

// checkNewID fails before any registry work when the snapshot ID is unusable or already
// taken, so an existing ID cannot waste a long mirror run.
func checkNewID(store imagesnapshot.Store, id string, inv *imagesnapshot.Inventory) error {
	if id == "" {
		id = imagesnapshot.DefaultID(inv)
	}
	if err := imagesnapshot.ValidateID(id); err != nil {
		return err
	}
	if store.Exists(id) {
		return fmt.Errorf("snapshot %q already exists in %s: snapshots are never rewritten, choose a new --id", id, store.Dir)
	}
	return nil
}

func validProfile(p string) bool {
	return p == imagesnapshot.ProfileCPUOnly || p == imagesnapshot.ProfileFullFeature
}

func cmdCreate(ctx context.Context, args []string, stdout, stderr io.Writer, newRegistry registryFactory) error {
	fs := flag.NewFlagSet("create", flag.ContinueOnError)
	var in inputFlags
	in.register(fs)
	mirror := fs.String("mirror", "", "private registry to copy images to, host[:port][/prefix] (required)")
	store := fs.String("store", "snapshots", "directory holding snapshots")
	id := fs.String("id", "", "snapshot ID (default: derived from the candidate revision and inventory)")
	resolveOnly := fs.Bool("resolve-only", false, "resolve digests and platforms but copy nothing, and store nothing")
	insecure := fs.Bool("insecure", false, "allow plain HTTP to registries")
	report := fs.String("report", "", "write the blocker report here when the snapshot is blocked")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	input, err := in.load()
	if err != nil {
		return err
	}
	inv, err := imagesnapshot.BuildInventory(input)
	if err != nil {
		return err
	}
	if !*resolveOnly {
		if err := checkNewID(imagesnapshot.Store{Dir: *store}, *id, inv); err != nil {
			return err
		}
	}
	snap, err := imagesnapshot.Create(ctx, newRegistry(*insecure), inv, imagesnapshot.Options{ID: *id, Mirror: *mirror, ResolveOnly: *resolveOnly})
	if err != nil {
		return reportBlocked(snap, err, *report, stderr)
	}
	logEntries(stdout, snap)
	if *resolveOnly {
		fmt.Fprintf(stdout, "resolved %d images for snapshot %s (nothing copied, nothing stored)\n", len(snap.Spec.Entries), snap.Metadata.ID)
		return nil
	}
	path, sum, err := (imagesnapshot.Store{Dir: *store}).Put(snap)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "snapshot %s: %d images mirrored and verified\nmanifest: %s\nsha256:   %s\n", snap.Metadata.ID, len(snap.Spec.Entries), path, sum)
	return nil
}

// logEntries prints the mirror verification log: for each image its status, the source
// reference, the digest that is pinned, the index digest when it differs, the
// platforms, the build ID and the mirror reference. Only references, digests and
// platforms appear, so it is safe to attach as evidence.
func logEntries(w io.Writer, snap *imagesnapshot.Snapshot) {
	for _, e := range snap.Spec.Entries {
		fmt.Fprintf(w, "%-9s %-30s %s\n", e.Status, e.Component, e.Source)
		digest := e.Digest
		if e.SourceDigest != "" && e.SourceDigest != e.Digest {
			digest += "  (index " + e.SourceDigest + ")"
		}
		fmt.Fprintf(w, "          digest    %s\n", orDash(digest))
		fmt.Fprintf(w, "          platforms %s\n", orDash(strings.Join(e.Platforms, ",")))
		if e.BuildID != "" {
			fmt.Fprintf(w, "          build     %s\n", e.BuildID)
		}
		if e.MirrorRef != "" {
			fmt.Fprintf(w, "          mirror    %s\n", e.MirrorRef)
		}
	}
}

func reportBlocked(snap *imagesnapshot.Snapshot, err error, reportPath string, stderr io.Writer) error {
	var blocked *imagesnapshot.BlockedError
	if !errors.As(err, &blocked) {
		return err
	}
	fmt.Fprintf(stderr, "snapshot blocked: %d image(s) are external blockers, nothing was stored:\n", len(blocked.Blockers))
	for _, b := range blocked.Blockers {
		fmt.Fprintf(stderr, "  %s  %s\n      %s\n", b.Component, b.Source, b.Reason)
	}
	if reportPath != "" {
		if werr := writeReport(reportPath, map[string]any{"blockers": blocked.Blockers, "entries": snap.Spec.Entries}); werr != nil {
			fmt.Fprintf(stderr, "warning: could not write the report: %v\n", werr)
		}
	}
	return problem{fmt.Sprintf("%d image(s) could not be resolved or mirrored", len(blocked.Blockers))}
}

// writeReport writes a JSON report. It refuses content that looks like a credential, and
// a failure to write it is reported by the caller as a warning: it must never change the
// outcome of the command that produced it.
func writeReport(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	if err := imagesnapshot.CheckNoCredentials(b); err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

// snapshotFlags locate a stored snapshot.
type snapshotFlags struct{ store, id, file string }

func (f *snapshotFlags) register(fs *flag.FlagSet, idName string) {
	fs.StringVar(&f.store, "store", "snapshots", "directory holding snapshots")
	fs.StringVar(&f.id, idName, "", "snapshot ID")
	fs.StringVar(&f.file, "snapshot", "", "path to a manifest.json (instead of --store and --"+idName+")")
}

func (f *snapshotFlags) read() (*imagesnapshot.Snapshot, error) {
	var snap *imagesnapshot.Snapshot
	var err error
	switch {
	case f.file != "":
		snap, err = imagesnapshot.ReadSnapshot(f.file)
	case f.id == "":
		return nil, errors.New("give --snapshot, or --store and the snapshot ID")
	default:
		snap, err = (imagesnapshot.Store{Dir: f.store}).Get(f.id)
	}
	if err != nil {
		return nil, err
	}
	if err := imagesnapshot.Validate(snap); err != nil {
		return nil, fmt.Errorf("snapshot %s: %w", snap.Metadata.ID, err)
	}
	return snap, nil
}

func cmdVerify(ctx context.Context, args []string, stdout, stderr io.Writer, newRegistry registryFactory) error {
	fs := flag.NewFlagSet("verify", flag.ContinueOnError)
	var in inputFlags
	in.register(fs)
	var sf snapshotFlags
	sf.register(fs, "id")
	profile := fs.String("profile", "", "cpuOnly or fullfeature (required)")
	insecure := fs.Bool("insecure", false, "allow plain HTTP to registries")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	if !validProfile(*profile) {
		return fmt.Errorf("--profile must be cpuOnly or fullfeature")
	}
	snap, err := sf.read()
	if err != nil {
		return err
	}
	input, err := in.load()
	if err != nil {
		return err
	}
	inv, err := imagesnapshot.BuildInventory(input)
	if err != nil {
		return err
	}
	findings := imagesnapshot.Preflight(ctx, newRegistry(*insecure), snap, inv, *profile)
	return reportFindings(stdout, stderr, fmt.Sprintf("preflight for %s from snapshot %s", *profile, snap.Metadata.ID), findings)
}

func cmdCompare(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("compare", flag.ContinueOnError)
	var in inputFlags
	in.register(fs)
	var sf snapshotFlags
	sf.register(fs, "id")
	profile := fs.String("profile", "", "cpuOnly or fullfeature (required)")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	if !validProfile(*profile) {
		return fmt.Errorf("--profile must be cpuOnly or fullfeature")
	}
	snap, err := sf.read()
	if err != nil {
		return err
	}
	input, err := in.load()
	if err != nil {
		return err
	}
	refs := imagesnapshot.InstallRefs(*profile, input)
	if len(refs) == 0 {
		return fmt.Errorf("no install references to check for %s: give the installer --config and the rendered --values-%s the install will use",
			*profile, strings.ToLower(*profile))
	}
	findings := imagesnapshot.Compare(snap, *profile, refs)
	return reportFindings(stdout, stderr, fmt.Sprintf("%d install references for %s against snapshot %s", len(refs), *profile, snap.Metadata.ID), findings)
}

func reportFindings(stdout, stderr io.Writer, what string, findings []imagesnapshot.Finding) error {
	if len(findings) == 0 {
		fmt.Fprintf(stdout, "OK: %s: no problems found\n", what)
		return nil
	}
	for _, f := range findings {
		fmt.Fprintln(stderr, f.String())
	}
	return problem{fmt.Sprintf("%s: %d problem(s) found", what, len(findings))}
}

func cmdRefresh(ctx context.Context, args []string, stdout, stderr io.Writer, newRegistry registryFactory) error {
	fs := flag.NewFlagSet("refresh", flag.ContinueOnError)
	var in inputFlags
	in.register(fs)
	var sf snapshotFlags
	sf.register(fs, "previous")
	id := fs.String("id", "", "ID of the new snapshot (required)")
	recheck := fs.Bool("recheck-tags", false, "re-resolve every source to catch a tag that moved")
	insecure := fs.Bool("insecure", false, "allow plain HTTP to registries")
	report := fs.String("report", "", "write the change report here")
	if err := parse(fs, args, stderr); err != nil {
		return err
	}
	prev, err := sf.read()
	if err != nil {
		return err
	}
	input, err := in.load()
	if err != nil {
		return err
	}
	inv, err := imagesnapshot.BuildInventory(input)
	if err != nil {
		return err
	}
	if err := checkNewID(imagesnapshot.Store{Dir: sf.store}, *id, inv); err != nil {
		return err
	}
	res, err := imagesnapshot.Refresh(ctx, newRegistry(*insecure), prev, inv, imagesnapshot.RefreshOptions{ID: *id, RecheckTags: *recheck})
	switch {
	case errors.Is(err, imagesnapshot.ErrNoChange):
		fmt.Fprintln(stdout, "no change:", err)
		return nil
	case err != nil:
		var blocked *imagesnapshot.BlockedError
		if errors.As(err, &blocked) && res != nil {
			return reportBlocked(res.Snapshot, err, *report, stderr)
		}
		return err
	}
	logChanges(stdout, res)
	path, sum, err := (imagesnapshot.Store{Dir: sf.store}).Put(res.Snapshot)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "snapshot %s refreshes %s\nmanifest: %s\nsha256:   %s\n", res.Snapshot.Metadata.ID, prev.Metadata.ID, path, sum)
	if *report != "" {
		if werr := writeReport(*report, res); werr != nil {
			fmt.Fprintf(stderr, "warning: could not write the report: %v\n", werr)
		}
	}
	return nil
}

func logChanges(w io.Writer, res *imagesnapshot.RefreshResult) {
	for _, c := range res.Changes {
		fmt.Fprintf(w, "changed   %-32s %s", c.Component, c.Reason)
		if c.PreviousDigest != "" || c.Digest != "" {
			fmt.Fprintf(w, "  %s -> %s", orDash(c.PreviousDigest), orDash(c.Digest))
		}
		fmt.Fprintln(w)
	}
	if len(res.Rerun) > 0 {
		fmt.Fprintln(w, "rerun:")
		for _, r := range res.Rerun {
			fmt.Fprintln(w, "  ", r)
		}
	}
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
