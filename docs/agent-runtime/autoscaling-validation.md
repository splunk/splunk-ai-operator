# AgentRuntime autoscaling validation

The API-backed [replica regression](../../pkg/ai/features/agentruntime/autoscaling_envtest_test.go)
starts a standalone Deployment at its requested count of two. It uses the
Kubernetes `/scale` endpoint to simulate HPA decisions, then reconciles
repeatedly and after a spec or checkpoint Secret change. On the base code,
the first reconcile resets the selected count from four to two. The
candidate preserves it and lets the HPA act on subsequent bounds changes.
The test also verifies that invalid effective bounds leave the last applied
policy in place.

The Go suites for the runtime, platform reconciliation, API types, admission,
and controllers passed, as did Go vet. The installer rendered both profiles
to their expected values and rejected a minimum of five with the maximum
omitted.

The broader installer suite reported the same 19 failures on the base tree
and candidate in the restricted local shell (568 and 569 passes,
respectively). Direct profile rendering and partial-override validation
passed with the shell access the installer requires.

## Focused cluster smoke

The smoke test ran on 23 November 2026 in a disposable `cpuOnly` namespace on
`agentruntime-dev`. It used both production reconcilers and admission
handlers from a namespace-scoped Linux/amd64 binary. The binary was built
from base `4d32d410741f05dea81a1a27141870ddd4e1b52e` with this change and had
SHA-256 `a1724798f917c1f2aff630c321c3fa5f75d61d58d19018d3e4a2db40abd31497`.
The final policy type includes a marker that excludes it from API copy
generation.

| Check | Observation |
| --- | --- |
| Invalid partial override | Admission rejected a floor of five with the default ceiling of four |
| Default policy and metrics | Correct Deployment target, one ready replica, `500m` CPU request, and CPU utilization reported against a 60% target |
| Bounds updates | The Kubernetes HPA scaled from one to three, then from three to two and back to one |
| Ordinary reconciliation | An unrelated pod template change rolled out at two replicas, and a checkpoint Secret metadata update reran schema setup at two replicas |
| Replica field ownership | Deployment managed fields identified `kube-controller-manager` on the `scale` subresource after both scale directions and both unrelated changes |
| Feature removal and re-addition | Removal pruned the AIService, Deployment, and HPA. Re-adding the feature created a new Deployment at two replicas with the original checkpoint Secret |

Cleanup removed the test namespace, scoped controller and admission
resources, remote files, and temporary private access rule. Readback
matched the original cluster configuration, shared workloads, checkpoint
Secret identity and resource version, and network rules.

Scaling was driven by controlled changes to the HPA bounds. Product traffic
under load remains part of pipeline qualification.
