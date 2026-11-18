// candidate-contract is an offline development tool. It never loads kubeconfig.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/splunk/splunk-ai-operator/internal/candidatecontract"
	"sigs.k8s.io/yaml"
)

func main() {
	manifest := flag.String("manifest", "config/agent-runtime/candidate-manifest.yaml", "selected candidate record")
	matrix := flag.String("matrix", "config/agent-runtime/compatibility-matrix.yaml", "compatibility matrix")
	profile := flag.String("profile", "cpuOnly", "cpuOnly or fullfeature")
	previous := flag.String("previous", "", "optional preceding candidate record for refresh validation")
	flag.Parse()
	if err := run(*manifest, *matrix, *profile, *previous); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(manifestPath, matrixPath, profile, previousPath string) error {
	var m candidatecontract.Manifest
	var matrix candidatecontract.Matrix
	if err := candidatecontract.Read(manifestPath, &m); err != nil {
		return err
	}
	if err := candidatecontract.Read(matrixPath, &matrix); err != nil {
		return err
	}
	if previousPath != "" {
		var previous candidatecontract.Manifest
		if err := candidatecontract.Read(previousPath, &previous); err != nil {
			return err
		}
		if _, err := candidatecontract.ValidateRefresh(&previous, &m); err != nil {
			return err
		}
	}
	snapshot, err := candidatecontract.Render(&m, profile, &matrix)
	if err != nil {
		return err
	}
	data, err := yaml.Marshal(snapshot)
	if err != nil {
		return fmt.Errorf("render: cannot serialize snapshot")
	}
	_, err = os.Stdout.Write(data)
	return err
}
