package raybuilder

import (
	"context"
	"fmt"
	"os"
	"strings"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"gopkg.in/yaml.v2"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	k8syaml "sigs.k8s.io/yaml"
)

func ReadInstanceMapFromConfigMap(ctx context.Context, cl client.Client, name, namespace string) (InstanceMap, error) {
	cm := &corev1.ConfigMap{}
	err := cl.Get(ctx, client.ObjectKey{Name: name, Namespace: namespace}, cm)
	if err != nil {
		return nil, err
	}
	val, ok := cm.Data["instance.yaml"]
	if !ok {
		return nil, fmt.Errorf("instance.yaml not found in ConfigMap %s/%s", namespace, name)
	}

	var instanceMap InstanceMap
	if err := yaml.Unmarshal([]byte(val), &instanceMap); err != nil {
		return nil, err
	}
	return instanceMap, nil
}

func (b *Builder) ReconcileInstancesConfigMap(ctx context.Context, p *aiApi.AIPlatform) error {
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{
		Name:      p.Name + "-instances",
		Namespace: p.Namespace,
	}}
	_, err := controllerutil.CreateOrUpdate(ctx, b.Client, cm, func() error {
		if cm.Data == nil {
			cm.Data = map[string]string{}
		}
		// Seed from image on first creation.
		if _, exists := cm.Data["instance.yaml"]; !exists {
			instanceFile := os.Getenv("INSTANCE_FILE")
			if instanceFile == "" {
				instanceFile = "instance.yaml"
			}
			content, err := os.ReadFile(instanceFile)
			if err != nil {
				return fmt.Errorf("failed to read instance.yaml from image: %w", err)
			}
			cm.Data["instance.yaml"] = string(content)
		}
		// Merge GPU types from spec.gpuWorkerConfig.instanceTypes — add new keys, never overwrite existing.
		if p.Spec.GPUWorkerConfig != nil && len(p.Spec.GPUWorkerConfig.InstanceTypes) > 0 {
			existing := make(WorkerConfigs)
			if err := k8syaml.Unmarshal([]byte(cm.Data["instance.yaml"]), &existing); err != nil {
				return fmt.Errorf("failed to parse instance.yaml from ConfigMap: %w", err)
			}
			updated := false
			for gpuType, tiers := range p.Spec.GPUWorkerConfig.InstanceTypes {
				if _, exists := existing[gpuType]; !exists {
					// Convert WorkerTierSpec → InstanceDetail
					details := make([]InstanceDetail, len(tiers))
					for i, t := range tiers {
						details[i] = InstanceDetail{
							Tier:       t.Tier,
							GPUsPerPod: t.GPUsPerPod,
							Env:        t.Env,
							Resources:  t.Resources,
						}
					}
					existing[gpuType] = details
					updated = true
				}
			}
			if updated {
				out, err := k8syaml.Marshal(existing)
				if err != nil {
					return fmt.Errorf("failed to marshal updated instance.yaml: %w", err)
				}
				cm.Data["instance.yaml"] = string(out)
			}
		}
		return controllerutil.SetOwnerReference(p, cm, b.Scheme)
	})
	return err
}

// ReconcileFeatureConfigMaps bootstraps one ConfigMap per feature (e.g. <name>-feature-saia)
// seeded from the image's features/<name>.yaml. New GPU type instanceScale entries from
// spec.gpuWorkerConfig.instanceScale are merged in — existing keys are never overwritten.
func (b *Builder) ReconcileFeatureConfigMaps(ctx context.Context, p *aiApi.AIPlatform) error {
	featureDir := os.Getenv("FEATURE_CONFIG_DIR")
	if featureDir == "" {
		featureDir = "features"
	}
	for _, feature := range p.Spec.Features {
		cmName := p.Name + "-feature-" + feature.Name
		cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{
			Name:      cmName,
			Namespace: p.Namespace,
		}}
		_, err := controllerutil.CreateOrUpdate(ctx, b.Client, cm, func() error {
			if cm.Data == nil {
				cm.Data = map[string]string{}
			}
			key := feature.Name + ".yaml"
			// Seed from image on first creation.
			if _, exists := cm.Data[key]; !exists {
				filePath := featureDir + "/" + key
				content, err := os.ReadFile(filePath)
				if err != nil {
					return fmt.Errorf("failed to read feature config %s from image: %w", filePath, err)
				}
				cm.Data[key] = string(content)
			}
			// Merge instanceScale from spec.gpuWorkerConfig — add new GPU type keys, never overwrite existing.
			if p.Spec.GPUWorkerConfig != nil && len(p.Spec.GPUWorkerConfig.InstanceScale) > 0 {
				var featureConfig FeatureConfig
				if err := yaml.Unmarshal([]byte(cm.Data[key]), &featureConfig); err != nil {
					return fmt.Errorf("failed to parse %s from ConfigMap: %w", key, err)
				}
				if featureConfig.InstanceScale == nil {
					featureConfig.InstanceScale = make(map[string]map[string]int32)
				}
				updated := false
				for gpuType, tierScale := range p.Spec.GPUWorkerConfig.InstanceScale {
					if _, exists := featureConfig.InstanceScale[gpuType]; !exists {
						featureConfig.InstanceScale[gpuType] = tierScale
						updated = true
					}
				}
				if updated {
					out, err := yaml.Marshal(featureConfig)
					if err != nil {
						return fmt.Errorf("failed to marshal updated %s: %w", key, err)
					}
					cm.Data[key] = string(out)
				}
			}
			return controllerutil.SetOwnerReference(p, cm, b.Scheme)
		})
		if err != nil {
			return fmt.Errorf("failed to reconcile feature ConfigMap %s: %w", cmName, err)
		}
	}
	return nil
}

func detectProvider(k8sClient client.Client, ctx context.Context) (string, error) {
	nodes := &corev1.NodeList{}
	if err := k8sClient.List(ctx, nodes); err != nil {
		return "", err
	}
	if provider, err := detectClusterProviderFromNodeLabels(k8sClient, ctx); err == nil {
		return provider, nil
	}
	return "", fmt.Errorf("could not detect cloud provider from nodes")
}

func detectClusterProviderFromNodeLabels(k8sClient client.Client, ctx context.Context) (string, error) {
	nodes := &corev1.NodeList{}
	if err := k8sClient.List(ctx, nodes); err != nil {
		return "", err
	}
	for _, node := range nodes.Items {
		labels := node.Labels
		switch {
		case labels["eks.amazonaws.com/nodegroup"] != "":
			return "aws", nil
		case labels["cloud.google.com/gke-nodepool"] != "":
			return "gcp", nil
		case labels["kubernetes.azure.com/cluster"] != "":
			return "azure", nil
		case strings.Contains(node.Name, "oke") || strings.Contains(labels["oke.oraclecloud.com/name"], "oke"):
			return "oracle", nil
		default:
			// Fallthrough case: on-prem, RKE, k3s, etc.
			return "generic", nil
		}
	}
	return "", fmt.Errorf("could not detect cluster provider from node labels")
}
