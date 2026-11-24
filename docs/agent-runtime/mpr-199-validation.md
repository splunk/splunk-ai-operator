# Managed AgentRuntime route validation

On 24 November 2026, focused checks used the selected MPR-188 images and the exact AITK 6.2.0 candidate package. Each profile ran in a separate disposable namespace on its existing development cluster.

## Local checks

| Check | Result |
| --- | --- |
| Non-E2E Go suite | 24 packages passed |
| Both-profile route tests | Passed. Covered namespace and domain selection, service selectors and ports, endpoint and path rendering, missing dependencies, readiness loss and recovery, supported overrides, and issuer trust validation. |
| Controller integration | Passed. A local API server exercised CPU-only status propagation and CA updates. |
| SLIM Deployment revision | Passed. The reconciler preserves the Kubernetes Deployment revision outside the pod template and leaves the Deployment untouched on repeated reconciliation. |
| Installer and generated resources | Eight focused installer assertions passed across the profiles. Generated CRD schemas matched Helm and the embedded installer. The broader installer harness reproduced baseline image-warning failures. |
| Static checks | Go vet and whitespace checks passed. Helm lint passed with dependency warnings. |

## Focused live checks

| Case | `cpuOnly` | `fullfeature` |
| --- | --- | --- |
| TLS gateway with trusted CA and matching hostname | Passed | Passed |
| Untrusted CA and incorrect hostname | Rejected | Rejected |
| AITK save and readback | HTTP 200. The saved URL stayed identical before, during, and after Runtime loss. | HTTP 200. The saved URL stayed identical before, during, and after Runtime loss. |
| SLIM caller authorization | Missing and invalid tokens returned 401. An interactive token continued to authorize the model-list GET throughout the outage. | Missing and invalid tokens returned 401. An interactive token continued to authorize the model-list GET throughout the outage. |
| Authenticated Runtime status through SLIM | `200 READY → 500 → 200 READY` | `200 READY → 500 → 200 READY` |
| Availability and SLIM workload during the Runtime selector fault | `True → False → True`. Deployment generation and Pod identity stayed stable. | `True → False → True`. Deployment generation and Pod identity stayed stable. |
| Cleanup | Shared workload and configuration baselines matched after fixture removal. | Shared workload and configuration baselines matched after fixture removal. |

The CPU-only fixture ran the production platform and service reconcilers. The fullfeature fixture used the production service reconciler with the existing Ray prerequisites. These checks compare separate installations of the canonical profiles. MPR-194 owns product invocation and streaming. The live status check called Runtime `/service/ready` through SLIM. The Runtime API prefix was checked against the candidate contract and rendered configuration.

## Installer bundle

Kustomize uses the same public image defaults as the installer examples. Supply private images through `images.ray.headImage`, `images.ray.workerImage`, `images.saia.apiImage`, `images.saia.dataLoaderImage`, and `images.slim.apiImage`. Set `images.registry` to qualify relative image references or supply fully qualified references directly.

The regenerated bundle includes the managed route schema and the read/watch permissions needed for Runtime ReplicaSets and EndpointSlices. The `cpuOnly` and `fullfeature` installer profile renders matched their checked-in expectations. All 17 focused bundle assertions passed, including config-driven image overrides in both profiles and preservation of a fully qualified Runtime schema image digest.

## Acceptance gaps

- The Runtime and SLIM Service reconcilers must check ownership of an existing Service after loading it and before mutating it.
- An invalid issuer-trust update withdraws route availability while previously configured SLIM Pods can still serve saved callers. Data-plane fail-closed enforcement for this case needs coverage.
- Route publication can precede completion of the SLIM rollout. One authorization probe during an issuer change received a response from a Pod with the previous configuration.
- The managed path activates for explicit canonical profiles. Route configuration supplied with an omitted or legacy profile needs an explicit compatibility policy.
