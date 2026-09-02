9733b3d Merge pull request #105 from splunk/make_customers_exp_better
f4e389a chore: fix reviewer username to vavarshn
82abca2 ci: fix prerelease-update-versions to declare inputs on workflow_call and use inputs.*
1331f40 chore: add vvarshney-splunk to release PR reviewers
bca7f10 Merge pull request #104 from splunk/airgap-enhancements
5f002d0 ci: add workflow_dispatch trigger to prerelease-update-versions
413cf13 fix: address PR 104 review comments
74c60a2 docs: document k0s & add-on image bundles in air-gap deployment guide
93a8c31 Merge pull request #103 from splunk/vavarshn/config_update
27b2002 fix: timeout issue
c0ddd3f Merge branch 'vavarshn/config_update' of https://github.com/splunk/splunk-ai-operator into vavarshn/config_update
b70a1d6 codex review change
3df9bfc Potential fix for pull request finding
0b8bb95 final changes for the config
05a7bae feat: moved detailed info for airgap from deployment_guide to k0s_readme
145282d feat: pre-install gpu drivers offline
ded5af0 feat: introduce k0s & add-on image bundles, pyyaml wheel fix
e64973e Config string changes
5be2d0e Merge pull request #100 from splunk/make_customers_exp_better
dee3d7d docs: collapse air-gapped scenarios into one row in DEPLOYMENT_GUIDE
728a1cc docs: scope T3-16 to GPU install step only; add scenario links in DEPLOYMENT_GUIDE
294b4c0 fix: address Copilot review issues and doc/test improvements
c539254 docs: address customer/PM/support feedback on DEPLOYMENT_GUIDE
19d6e16 docs: restore config sections table in DEPLOYMENT_GUIDE with reference link to K0S_README
33992d1 docs: consolidate to 3 docs, absorb AIRGAP.md and K0S_QUICKSTART.md
537e6bd docs: remove unsupported 'Only GPU nodes blocked' scenario from deployment guide
124b832 docs: move SAIA app install guide into K0S_README; add summary to DEPLOYMENT_GUIDE
cfed7eb docs: add SAIA_APP_INSTALL.md — Splunk AI Assistant app install guide
9671f23 docs: remove Rocky Linux 9 and AlmaLinux 9 as supported OS
e39ea2c docs: add troubleshooting.md for k0s installer
415fc48 docs: correct model weight download size from ~60 GB to >120 GB
191831c docs: update TEST_PLAN with session changes; fix DEPLOYMENT_GUIDE diagram colors
2b2ad3b docs: clarify total GPU count as 8 × L40S across 2 nodes (384 GB total GPU memory)
de9283b docs: update GPU worker spec to 2×g6e.12xlarge (4×L40S, 48 vCPU, 384 GiB RAM, 100 Gbps per node)
3e49b86 docs: remove VOC Portal references; fix defaultAcceleratorType to L40S only
655d938 chore: restrict supported OS to RHEL 9; gate other OS families in scripts
372d4f5 docs: add staging machine system requirements (250GB disk, 16GB RAM)
d0d01bd docs: add deployment-guide.md with Mermaid diagrams for standard and air-gapped deployments
703ed22 feat: air-gap support for GPU node OS package installs
1ccba4a feat: make air-gap mode configurable via cluster.airgap in YAML (+ env var override)
b0b7fc1 feat: wire wait_for_dependency() into all three external dependency touch-points
1c30132 docs: add TEST_PLAN.md with implementation chart, all test tiers, and EC2 guide
9007dba feat: UX improvements — timestamps, step tracker, install plan, confirm prompt, validate/diagnose subcommands
c76f7f5 docs: add AIRGAP.md and --help flags for air-gap bundle scripts
8137f1f feat: add air-gap bundle scripts and env-var URL overrides in installer
85917ed docs: remove H100 references from k0s docs and add Gemma model list
44595a6 Merge pull request #101 from splunk/k0s-script-fixes
799f32c fix(k0s): use minio:// scheme for seaweedfs/minio object storage path
8b51a49 Merge pull request #98 from splunk/AIP-4064
3f23847 fix: phase2 log filename mismatch and modelStaging boolean parse
4ab84b6 Merge pull request #97 from splunk/AIP-4009
d4e3f95 feat: update md files accordingly
45fcbc1 fix: copilot issues
c0ab4df AIP-4009 : Merge download+upload scripts with bare metal k0s install script
d747c20 Merge pull request #95 from splunk/exclude-metal-original-gpt-oss-20b
0b3e5e3 Fail fast with clear error when mc download fails
408dee3 Fix mc install: follow redirects and add /usr/local/bin to PATH under sudo
8b72ff4 Merge pull request #94 from splunk/exclude-metal-original-gpt-oss-20b
ac5abb7 Skip get.k0s.sh reachability check when curl is absent
f8f4885 Allow upload_to_minio_aws.sh config to be overridden via env vars
bb87c8a Address Copilot PR #94 review comments
f41c0a9 Set gemma-4-31b-it as non-gated model
f51c761 Improve dependency management in k0s setup script
9f43a80 Skip LFS download for excluded folders in download_from_huggingface.sh
48f28f5 Exclude metal and original folders for gpt-oss-20b artifact download
72f89e5 Merge pull request #90 from splunk/vvarshney/gemma4_ai_tier
4784842 Updated the ids for gemma4 and tool parser as per cloud config
a01dac7 Merge pull request #93 from splunk/AIP-3699
dd806da fix: handling copilot review comments
a223115 feat : AIP-3699 - better logging on final state of AI platform
a01e40f Adding model artifacts config changes
0306034 AIP-3699 : Extend k0s to check if the pods are healthy
f9a3c06 Merge pull request #92 from splunk/s3-storage
da63931 feat: configure Gemma 4 31B for 2-GPU L40S and add LLM defaults to SAIA operator
39cfada Changes for adding gemma model config
50a4119 Apply suggestions from code review
09af9ee codex comment fix
716a528 fix: inject static S3 credentials for SAIA v1 and Ray on AWS/s3compat stores
86c60b4 Merge pull request #91 from splunk/vvarshney/fix-vuln-scan-pin-trivy-action
1a5ed5e VULN-77430 Fix
ecc3ad5 Merge pull request #89 from splunk/ai-tier-concise-doc-after-bugbash
48b0675 fix: address review comments
38bc50d fix: addressing review comments
9f357e5 feat: Update concise doc from bug bash feedback
ce38dc7 Merge pull request #88 from splunk/ai-tier-concise-documentation
1153ca3 Merge pull request #86 from splunk/saia-gateway-changes
bfc4300 Potential fix for pull request finding
7b100b7 Potential fix for pull request finding
a225e2a Merge branch 'main' into saia-gateway-changes
293cffb metalLB changes
7ffcb9e fix: updated k0s quick start readme
375da9f feat: concise documentation for k0s setup
7d736a0 Merge pull request #87 from splunk/ai-tier-v2-k0s
5797328 fix: code review comments
85bbf82 merge ai-tier-v2-k0s into saia-gateway-changes
6433a15 WIP: pre-merge in-progress work on saia-gateway-changes
d74d9c5 fix: github copilot review comments
3d1104d feat: added initContainer for saia-vector-db-setup posthook
b137271 fix: added logging to a file
922cb4f fix: add safety gate to prevent install_k0s_cluster from wiping a live cluster
0ccde9f refactor: remove ecr credential refresher
4146385 refactor: replace NVMe auto-format with preflight storage checks, remove in-cluster MinIO install requiring customer-managed object storage
86cf822 fix: removal of aws specific usages
880f68b feature: including saia deployments helm configs
cc874b4 fix: upgrade go version due to vuln issue
7a24a4c fix: downgrade go version for fixing unit cases
9cf5cc2 fix: vulnerability issues CVE-2026-29181 and CVE-2026-39883
68068ea feat(ai-platform): SAIA service exposure to external requests
1ee8a6b fix: reverted support for rhel 10 (untested)
e51baad fix: WEAVIATE_PLATFORM_URL + support for rhel 10 (untested)
8fa59a5 fix(saia): unblock airgap v2 query path via CORS preflight, authz re-enable, and Redis no-op
824af70 feat: update images
4656c4c fix(saia): set v2 worker RUN_TASKS_DELAY_S=10 to keep heartbeat fresh
cb76b29 fix(saia): wire AWS_ACCESS_KEY_ID/SECRET on v2 pods for S3FieldDescription
7db8e01 fix(saia): wire FIELD_DESCRIPTION S3 backend on v2 API and v2 worker
6870cb8 feat(saia): expose public SAIA service via NodePort for Pattern-B v2 browser traffic
6c15036 feat: add configurable aiPlatformScheme to AIServiceSpec
f3a75d5 feat(saia): add SAIA v2 deployment + nginx path-based v1/v2 router
e5ee1eb make k0s script run fast + revisited model configs for all models
8f56527 all k0s changes + fixes
802e52f fix: upgrade grpc and cert-manager to patch CVE-2026-33186 and CVE-2026-25518
ab17c85 feat: add H100/L40S cluster setup support in eks and k0s scripts
e9bb76a feat: add H100 support with configurable gpu_types via defaultAcceleratorType
61bec1e Revert "fix: increase l40s-2-gpu memory to 128Gi and ephemeral-storage to 200Gi for gpt-oss-120b"
03ef451 fix: increase l40s-2-gpu memory to 128Gi and ephemeral-storage to 200Gi for gpt-oss-120b
c856da2 fix: use 2 GPUs and tensor_parallel_size=2 for gpt-oss-120b
9945411 fix: increase l40s-1-gpu ephemeral storage to 200Gi and memory to 64Gi
b122df7 fix: use AutoscalerOptions.IdleTimeoutSeconds instead of WorkerGroupSpec field
d056a69 fix: set IdleTimeoutSeconds=600 on worker groups to prevent autoscaler terminating nodes during model load
a1a13fd fix: reduce GptOss120b to 1 GPU / tensor_parallel_size 1 (quantized model)
0b83c1e fix: move VLLM_ATTENTION_BACKEND to top-level runtime_env to prevent env override
2d7c3b2 feat: replace llama models with gpt-oss-20b and gpt-oss-120b
977934e fix: remove model_definition from MbartTranslator app config
2d44244 fix: remove task: classify from engine_args (not supported in vllm 0.15.1)
f0b9785 fix: rename blob_storage prefix to blob_prefix to match SDK field name
11798a1 fix: use entrypoint.zip for Entrypoint app working_dir
4477cb9 fix: use file:// working_dir for all apps; use s3:// for minio working_dir base
2da6120 fix: point file:// working_dir to .zip file not directory
969a737 fix: SAIA resource defaults and preserve AIService resources on reconcile
12a8e29 fix: use file:// working_dir for bundled prompt injection models, remote URL for others
858c148 fix: bundle app code into image via file:// working_dir instead of MinIO zips
b9e10d9 fix: use MinIO HTTP endpoint for working_dir instead of broken s3:// handler
be67105 fix: path-style addressing for MinIO and rename object_storage to blob_storage
8d4f721 fix: add working_dir to Ray serve apps and wire WorkingDirBase/ModelVersion into ApplicationParams
fd6727c fix: update Ray serve import paths to remove splunkai_models_apps prefix
6bb3a60 fix: bump splunk-operator helm dependency from 3.0.0 to 3.1.0
718a31c s3object storage changes
f529ea8 vulnerability issue: version upgrade for opentelemetry-go from v1.33.0 to 1.40.0
c9b8de3 changes for s3 compatable storage in operator
17252f4 generi object storage changes
f17b874 changes for supporting minio in operator and script
64bf4cf Merge pull request #78 from splunk/VULN-63051
878a991 fix: handle copilot review comments
2c19d74 fix: handled copilot comments
210a292 vulnerability issue: version upgrade for opentelemetry-go from v1.33.0 to 1.40.0
f217b17 Merge pull request #73 from splunk/int-test
75f7ac0 Fix CI: Remove dry-run installation tests from workflow
c7a126d Fix CI: Also disable cert-manager and kuberay in dry-run tests
1cf502f Fix CI: Disable optional dependencies in dry-run tests
95ed93e Fix CI: Remove CRD pre-installation and --skip-crds flag
9906fc4 Fix CI: Disable chart-testing action due to cosign failures
9b71ecc Fix CI: Add --skip-crds flag to helm dry-run tests
55735ec Fix CI: Install Prometheus Operator CRDs for helm dry-run tests
051376e Re-trigger CI after infrastructure failures
8ee82b7 Fix CI: Add helm dependency build step before linting
301345a fix: restore builder_additional_test.go from main after merge conflict
299cef3 merge main into int-test to resolve conflicts
41abe67 remove SGT string from documentation per legal requirements
4dc92b8 remove obsolete kuttl/tests/helm/ directory per review feedback
cab7c5f address Copilot review recommendations for PR #73
6789390 add helm build artifacts to gitignore and track Chart.lock files
91646f6 add Splunk General Terms acceptance validation and documentation
94cd4cc add default otel image, unit tests, environment variable in all files
b07786b Merge pull request #75 from splunk/CSPL_4350_image_config
88fdd68 copilot review updates
110550d add default otel image, unit tests, environment variable in all files
0a73406 fixed helm chart for otel configuration
a369223 fix for helm chart and kuttl test cases
de6be53 first changes to make otel contrib image configurable
6b6a30a adding kuttl test case
ceb953e Merge pull request #72 from splunk/CSPL_4323_script_updates
4f8c963 review updates
d6ccd4f review updates
7b734a7 review updates
d779aef update eks cluster with stack script from team input
5c929fd Merge pull request #71 from splunk/download_models
b134ebe fix: docker registry
cdefbff fix: updated the splunk ai operator version
9b9f098 fix: use memory-optimized cloning to prevent OOM issues
08f2558 Merge pull request #13 from splunk/add_prodsec_workflow
adea86d use public oss scan
c6ec0e7 run fossa scan on PRs and merge to main
8654122 Merge branch 'main' of https://github.com/splunk/splunk-ai-operator into add_prodsec_workflow
013b1ab Merge branch 'develop' of https://github.com/splunk/splunk-ai-operator into add_prodsec_workflow
aa50381 try with single workflow
b3a95b2 use internal fossa scanner
9c8dd45 remove unused env vars
091920e add semgrep key
d652ce3 add prodsec workflow
