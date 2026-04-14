package slim

import (
	"context"
	"fmt"

	"github.com/go-logr/logr"
	manager "github.com/splunk/splunk-ai-operator/pkg/service"
)

type slimManagerFactory struct {
	log logr.Logger
}

// NewManagerFactory creates a new manager factory to create manager interface.
func NewManagerFactory() manager.Factory {
	factory := slimManagerFactory{}
	err := factory.init()
	if err != nil {
		panic(fmt.Sprintf("failed to initialize SLIM manager factory: %v", err))
	}
	return &factory
}

func (f *slimManagerFactory) init() error {
	return nil
}

func (f *slimManagerFactory) newManager(ctx context.Context) (manager.Manager, error) {
	newManager := &slimManager{
		log: f.log,
	}
	return newManager, nil
}

// NewService implements the Factory interface.
func (f *slimManagerFactory) NewService(ctx context.Context) (manager.Manager, error) {
	return f.newManager(ctx)
}
