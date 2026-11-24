# Connect AI Toolkit to Agent Runtime through SLIM

Set the platform profile explicitly to `cpuOnly` or `fullfeature` to use the managed route. The operator derives the SLIM-to-Runtime origin from the platform's native AgentRuntime Service. SLIM uses that origin in `AI_TIER_AGENT_RUNTIME_URL` and uses the Runtime API prefix `/system/ai-agent-runtime/v1`. AI Toolkit connects to the SLIM API and sends a Splunk interactive bearer token. SLIM calls the internal Runtime Service using the network trust boundary described in the [candidate contract](candidate-contract-review.md).

## Configure the AI Toolkit connection

1. Find the SLIM AIService owned by the target AIPlatform. Read its route status with `kubectl -n <namespace> get aiservice <slim-aiservice> -o yaml`.
2. Find the `AgentRouteAvailable` entry under `status.conditions`. Copy `status.featureStatus.slim.aitkEndpoint` when that condition is `True` and its `observedGeneration` equals `metadata.generation`. The URL ends in `/tenant/slim-api/v1alpha1`. An in-cluster AI Toolkit deployment uses the SLIM Service address. If Splunk uses an existing HTTPS gateway, set `spec.splunkConfiguration.aitkSlimOrigin` on the AIPlatform to the gateway origin (for example, `https://slim.example.com`). The gateway must preserve the path and use a certificate that Splunk trusts for that hostname.
3. In Splunk, open **AI Toolkit → Connections → AI Tier** and save the copied URL with an account that can edit AI Toolkit configuration. Reopen the setting to confirm it was saved. For a REST check, use `GET` or `POST` on `/servicesNS/<caller>/Splunk_ML_Toolkit/mltk/ai_tier_settings` in the authenticated caller's namespace. AI Toolkit adds `/agent/agent_runtime` when it uses the agent route.

Configure the approved Splunk JWT issuer and set `spec.splunkConfiguration.caCertRef.name` to a Secret in the SLIM namespace. Use `spec.splunkConfiguration.trustedIssuers` for a standalone issuer when the platform does not need Splunk HEC credentials. Store the valid PEM CA bundle in the Secret's `ca.crt` key. SLIM uses this bundle when contacting the Splunk issuer. Configure the AI Toolkit caller's trust separately when it reaches SLIM through an HTTPS gateway.

In the k0s install configuration, use `splunk.caCertRef.name` and, when applicable, `splunk.aitkSlimOrigin`. The installer renders both fields into the AIPlatform. The Secret must exist in the workload namespace before the operator can make an explicitly profiled SLIM-to-Runtime route available.

## Check an unavailable route

If `AgentRouteAvailable` is absent, is `False`, or refers to an earlier generation, check the condition reason and the AgentRuntime and SLIM AIService statuses. An empty `aitkEndpoint` means no route has been published. If the Runtime becomes unready after publication, the URL may still be present while the condition reports the route unavailable. Treat the condition as the source of availability. The operator leaves the Splunk setting under the Splunk administrator's control, so a previously saved URL may still appear in AI Toolkit during an outage. If the working SLIM address changes, save the newly published URL once its condition is current and available.

## Validate the route

Local tests cover both profiles, rendering the Runtime origin and SLIM endpoint, checking Service and readiness state, and exercising route publication and degradation. The availability condition reflects the operator's configuration checks and the current Runtime readiness. Verify SLIM's listener from the AITK network before using the endpoint. Retain rendered output and condition results with credentials omitted. The [candidate render instructions](candidate-refresh.md#local-validation-and-rendering) describe running the profile fixtures.

A live route check uses the exact approved candidates from the caller's network. Verify DNS, selector, port, API prefix, and the certificate chain and hostname on each HTTPS leg. Verify the Runtime's `GET /service/ready` when the SLIM adapter requires it, and check caller authorization on an approved bounded request. The operator's Kubernetes probes use `GET /health`. Live TLS, caller authorization, and app settings behavior require the deployed candidates. Product invocation and streaming are covered separately by [MPR-194](https://splunk.atlassian.net/browse/MPR-194).
