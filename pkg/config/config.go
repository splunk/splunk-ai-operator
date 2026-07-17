package config

// OperatorMode represents the runtime mode in which the operator runs.
// It determines how the reconciler interacts with external services:
//
//   - normal:   Real behavior (in-cluster Ray/Weaviate/SAIA calls)
//   - debug:    Uses localhost endpoints (useful with kubectl port-forward for debugging)
//   - simulate: Skips real calls and pretends success for Ray/Weaviate/SAIA
type OperatorMode string

const (
	ModeNormal   OperatorMode = "normal"
	ModeDebug    OperatorMode = "debug"
	ModeSimulate OperatorMode = "simulate"
)

// OperatorConfig holds all runtime configuration needed by the operator.
// This is injected into reconcilers so they can:
//
//   - Decide whether to skip calls (simulate)
//   - Override in-cluster service endpoints with localhost endpoints (debug)
//   - Or run normally with default behavior
type OperatorConfig struct {
	Mode OperatorMode

	// DebugRayEndpoint overrides Ray head endpoint in debug mode.
	// Example: "http://localhost:8265"
	DebugRayEndpoint string

	// DebugWeaviateEndpoint overrides Weaviate DB endpoint in debug mode.
	// Example: "http://localhost:8080"
	DebugWeaviateEndpoint string

	// DebugSaiaEndpoint overrides SAIA service endpoint in debug mode.
	DebugSaiaEndpoint string

	// DebugSlimEndpoint overrides SLIM API service endpoint in debug mode.
	// Example: "http://localhost:8080"
	DebugSlimEndpoint string
}
