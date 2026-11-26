/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1

// AIServiceFeatureStatus holds status owned by individual AIService features.
type AIServiceFeatureStatus struct {
	AgentRuntime *AgentRuntimeStatus `json:"agentRuntime,omitempty"`
	Slim         *SlimRouteStatus    `json:"slim,omitempty"`
}

// SlimRouteStatus describes the endpoint a Splunk administrator can save in AITK.
type SlimRouteStatus struct {
	// AITKEndpoint is the last published URL. Check AgentRouteAvailable before using it.
	AITKEndpoint string `json:"aitkEndpoint,omitempty"`
}

// AgentRuntimeStatus holds AgentRuntime-specific observed state.
type AgentRuntimeStatus struct {
	Schema *AgentRuntimeSchemaStatus `json:"schema,omitempty"`
}

// AgentRuntimeSchemaStatus tracks the current schema Job attempt and its result.
type AgentRuntimeSchemaStatus struct {
	JobName       string `json:"jobName,omitempty"`
	AppliedHash   string `json:"appliedHash,omitempty"`
	FailedHash    string `json:"failedHash,omitempty"`
	FailureReason string `json:"failureReason,omitempty"`
	ImageDigest   string `json:"imageDigest,omitempty"`
}
