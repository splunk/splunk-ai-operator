package features

import (
	"strings"

	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/saia"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/seca"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/weaviateservice"
)

var FeatureFactories = map[string]common.FeatureFactory{
	"saia":             &saia.SaiaFactory{},
	"seca":             &seca.SecaFactory{},
	"weaviate-service": &weaviateservice.WeaviateServiceFactory{},
}

type rayAwareFactory interface {
	RequiresRay() bool
}

// RequiresRay reports whether the named feature requires Ray infrastructure.
// Unknown features default to requiring Ray to preserve existing behavior.
func RequiresRay(name string) bool {
	normalized := strings.ToLower(strings.TrimSpace(name))
	factory, ok := FeatureFactories[normalized]
	if !ok {
		return true
	}
	if rf, ok := factory.(rayAwareFactory); ok {
		return rf.RequiresRay()
	}
	return true
}
