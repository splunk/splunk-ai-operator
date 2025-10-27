# Reference Architecture

To set up the Splunk AI Operator, follow the steps in this document to verify everything in your setup exists as expected.

- [Reference Architecture](#reference-architecture)
  - [Cluster Setup](#cluster-setup)
    - [AWS EKS Setup](#aws-eks-setup)
      - [Create a Cluster Config](#create-a-cluster-config)
      - [Deploy the Cluster Config](#deploy-the-cluster-config)
      - [Ensure OIDC Provider](#ensure-oidc-provider)
      - [Install Cluster Add Ons](#install-cluster-add-ons)
      - [EBS Pod Identity Role and Association](#ebs-pod-identity-role-and-association)
      - [Create gp3 Storage Class](#create-gp3-storage-class)
    - [Azure AKS Setup](#azure-aks-setup)
      - [Create Resource Group](#create-resource-group)
      - [Create the AKS Cluster](#create-the-aks-cluster)
      - [Configure kubectl Access](#configure-kubectl-access)
      - [Enable OIDC Issuer and Workload Identity](#enable-oidc-issuer-and-workload-identity)
      - [Install Azure Disk CSI Driver](#install-azure-disk-csi-driver)
      - [Create Managed Identities and Federated Credentials](#create-managed-identities-and-federated-credentials)
      - [Create Premium SSD Storage Class](#create-premium-ssd-storage-class)
    - [Google Cloud GKE Setup](#google-cloud-gke-setup)
      - [Set Project and Region](#set-project-and-region)
      - [Enable Required APIs](#enable-required-apis)
      - [Create the GKE Cluster](#create-the-gke-cluster)
      - [Configure kubectl Access](#configure-kubectl-access-1)
      - [Enable Workload Identity](#enable-workload-identity)
      - [Verify GKE CSI Driver](#verify-gke-csi-driver)
      - [Create Service Accounts and Workload Identity Bindings](#create-service-accounts-and-workload-identity-bindings)
      - [Create pd-balanced Storage Class](#create-pd-balanced-storage-class)
  - [Prerequisite App Installation](#prerequisite-app-installation)
    - [Cluster Autoscaler](#cluster-autoscaler)
    - [NVIDIA Device Plugin](#nvidia-device-plugin)
    - [Uncordon Ready Nodes](#uncordon-ready-nodes)
    - [Kube Prometheus Stack](#kube-prometheus-stack)
    - [Cert Manager](#cert-manager)
    - [OpenTelemetry Operator](#opentelemtry-operator)
    - [Ray Operator](#ray-operator)
  - [Splunk Setup](#splunk-setup)
    - [Splunk Operator Installation (Optional)](#splunk-operator-installation-optional)
    - [Splunk AI Operator Installation](#splunk-ai-operator-installation)
    - [AWS S3 Bucket Setup](#aws-s3-bucket-setup)
      - [IAM Policy for S3 Bucket](#iam-policy-for-s3-bucket)
      - [IRSA for Service Accounts](#irsa-for-service-accounts)
    - [Azure Blob Storage Setup](#azure-blob-storage-setup)
      - [Role Assignments for Managed Identities](#role-assignments-for-managed-identities)
      - [Create Azure Storage Secret](#create-azure-storage-secret)
    - [Google Cloud Storage Setup](#google-cloud-storage-setup)
      - [IAM Policy Bindings for Service Accounts](#iam-policy-bindings-for-service-accounts)
      - [Create GCS Secret](#create-gcs-secret)
    - [Splunk Standalone Installation](#splunk-standalone-installation)
      - [Option 1: Splunk Already Installed](#option-1-splunk-already-installed)
      - [Option 2: Install Splunk Standalone](#option-2-install-splunk-standalone-using-the-splunk-operator-for-kubernetes)
    - [Splunk AI Platform CR Installation](#splunk-ai-platform-cr-installation)
      - [Option 1](#option-1-splunk-instance-deployed-through-other-avenues)
      - [Option 2](#option-2-splunk-instance-deployed-through-splunk-operator-for-kubernetes)

## Cluster Setup
The first step is creating a Kubernetes cluster that the Splunk AI operator and Splunk AI Operator CRs will run on.

### AWS EKS Setup

#### Create a Cluster Config
The cluster config should include the following:
 - name
 - region
 - service account for the ebs csi controller
 - vpcs
 - managed node groups

The cluster config should be saved to a file. In the following examples, the file name is `eks-cluster-config.yaml`. An example of a cluster config is:
```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: cluster-name
  region: us-west-2

iam:
  withOIDC: true
  serviceAccounts:
    - metadata:
        name: ebs-csi-controller-sa
        namespace: kube-system
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
      roleName: AmazonEKS_EBS_CSI_DriverRole
      wellKnownPolicies:
        ebsCSIController: true

vpc:
  subnets:
    private:
      ...
    public:
      ...

managedNodeGroups:

  - name: cpu-nodes
    instanceType: m5.xlarge
    desiredCapacity: 4
    minSize: 2
    maxSize: 8
    volumeSize: 500
    volumeType: gp3
    tags:
      Name: cluster-name-cpu
      Environment: prod
      kubernetes.io/cluster/cluster-name: owned
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/cluster-name: owned
  - name: gpu-nodes
    instanceType: g6e.24xlarge
    desiredCapacity: 1
    minSize: 0
    maxSize: 3
    volumeSize: 1000
    volumeType: gp3
    tags:
      Name: cluster-name-gpu
      Environment: prod
      kubernetes.io/cluster/cluster-name: owned
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/cluster-name: owned
    taints:
      - key: "dedicated"
        value: "gpu"
        effect: "NoSchedule"
```

#### Deploy the Cluster Config
Now that the cluster config is created, next is to deploy the cluster config using the following command:
```bash
eksctl create cluster -f eks-cluster-config.yaml
```

The cluster creation will take a few minutes. When the command completes, verify that the kubeconfig has been updated to point to the newly created cluster to continue with the deployments.

#### Ensure OIDC Provider
An OIDC Provider is required to create pvcs and other storage requirements during dpeloyment. Verify the OIDC provider is active with the following command:
```bash
aws eks describe-cluster --name "cluster-name" --query 'cluster.identity.oidc.issuer' --output text
```

If there is no output, or the output is None, then run the following command to associate the oidc provider with the cluster:
```bash
eksctl utils associate-iam-oidc-provider --region "us-west-2" --cluster "cluster-name" --approve
```

#### Install Cluster Add Ons
The eks-pod-identity-agent and aws-ebs-csi-driver add ons are required for the cluster. Create them with the following commands:
```bash
eksctl create addon --cluster "cluster-name" --name eks-pod-identity-agent --force
eksctl create addon --cluster "cluster-name" --name aws-ebs-csi-driver --force 
```

#### EBS Pod Identity Role and Association
For the eks-pod-identity-agent and aws-ebs-csi-driver add ons to work, they need roles and associations created.

1. Create the policy file. Update the `__REGION__` and `__ACCOUNT_ID__` fields with the information for your cluster.
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSPodIdentityTrust",
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": [ "sts:AssumeRole", "sts:TagSession" ],
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "__ACCOUNT_ID__" },
        "StringLike":   { "aws:SourceArn": "arn:aws:eks:__REGION__:__ACCOUNT_ID__:podidentityassociation/*" }
      }
    }
  ]
}
```
2. Create the pod identity role with the following command:
```bash
aws iam create-role --role-name "role-name" --assume-role-policy-document "path/to/policy/file"
```
3. Attach the AmazonEBSCSIDriverPolicy with the following command:
```bash
aws iam attach-role-policy --role-name "role-name" --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
```
4. Create a pod identity association for the service account for the ebs csi controller with the following command:
```bash
aws eks create-pod-identity-association --cluster-name "cluster-name" --namespace "kube-system" --service-account "ebs-csi-controller-sa" --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/role-name"
```

#### Create gp3 Storage Class
Create the storage class file to apply. In the following examples, the file name is `storageclass.yaml`.
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
```

Apply the storage class with the following command:
```bash
kubectl apply -f storageclass.yaml
```

### Azure AKS Setup

#### Create Resource Group
Create a resource group to contain the AKS cluster and related resources. Update the `--name` and `--location` fields with your desired values.
```bash
az group create --name "aks-resource-group" --location "eastus"
```

#### Create the AKS Cluster
Create the AKS cluster with the required configuration including:
- name
- resource group
- location
- node pools (system and user node pools with CPU and GPU nodes)
- enable managed identity
- network configuration

Create the cluster with the following command:
```bash
az aks create \
  --resource-group "aks-resource-group" \
  --name "cluster-name" \
  --location "eastus" \
  --node-count 4 \
  --node-vm-size "Standard_D4s_v3" \
  --nodepool-name "cpunodes" \
  --node-osdisk-size 500 \
  --node-osdisk-type "Managed" \
  --enable-managed-identity \
  --enable-addons monitoring \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 8 \
  --network-plugin azure \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys \
  --tags "Environment=prod" "Name=cluster-name-cpu"
```

Add a GPU node pool with the following command:
```bash
az aks nodepool add \
  --resource-group "aks-resource-group" \
  --cluster-name "cluster-name" \
  --name "gpunodes" \
  --node-count 1 \
  --node-vm-size "Standard_NC24ads_A100_v4" \
  --node-osdisk-size 1000 \
  --min-count 0 \
  --max-count 3 \
  --enable-cluster-autoscaler \
  --node-taints "dedicated=gpu:NoSchedule" \
  --tags "Environment=prod" "Name=cluster-name-gpu"
```

#### Configure kubectl Access
Get credentials for the newly created cluster to configure kubectl access:
```bash
az aks get-credentials --resource-group "aks-resource-group" --name "cluster-name" --overwrite-existing
```

Verify the connection to the cluster:
```bash
kubectl get nodes
```

#### Enable OIDC Issuer and Workload Identity
If not enabled during cluster creation, enable the OIDC issuer and workload identity with the following commands:
```bash
az aks update --resource-group "aks-resource-group" --name "cluster-name" --enable-oidc-issuer --enable-workload-identity
```

Get the OIDC issuer URL for later use:
```bash
az aks show --resource-group "aks-resource-group" --name "cluster-name" --query "oidcIssuerProfile.issuerUrl" -o tsv
```

Save this OIDC issuer URL as it will be needed for creating federated credentials.

#### Install Azure Disk CSI Driver
The Azure Disk CSI driver is required for dynamic provisioning of persistent volumes. Verify if it is already installed:
```bash
kubectl get pods -n kube-system | grep csi
```

If not present, install the Azure Disk CSI driver:
```bash
az aks update --resource-group "aks-resource-group" --name "cluster-name" --enable-disk-driver
```

Verify the CSI driver pods are running:
```bash
kubectl get pods -n kube-system -l app=csi-azuredisk-node
kubectl get pods -n kube-system -l app=csi-azuredisk-controller
```

#### Create Managed Identities and Federated Credentials
Create managed identities for the service accounts that will access Azure resources.

1. Get the AKS cluster's OIDC issuer URL (from the previous step):
```bash
export OIDC_ISSUER=$(az aks show --resource-group "aks-resource-group" --name "cluster-name" --query "oidcIssuerProfile.issuerUrl" -o tsv)
```

2. Create a namespace for the AI platform if it doesn't exist:
```bash
kubectl create ns ai-platform
```

3. Create managed identity for Ray Head service account:
```bash
az identity create --resource-group "aks-resource-group" --name "ray-head-identity"
```

4. Get the managed identity client ID:
```bash
export RAY_HEAD_CLIENT_ID=$(az identity show --resource-group "aks-resource-group" --name "ray-head-identity" --query "clientId" -o tsv)
```

5. Create federated credential for Ray Head service account:
```bash
az identity federated-credential create \
  --name "ray-head-federated-credential" \
  --identity-name "ray-head-identity" \
  --resource-group "aks-resource-group" \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:ai-platform:ray-head-sa" \
  --audience "api://AzureADTokenExchange"
```

6. Repeat the process for Ray Worker and SAIA service accounts:
```bash
# Ray Worker Identity
az identity create --resource-group "aks-resource-group" --name "ray-worker-identity"
export RAY_WORKER_CLIENT_ID=$(az identity show --resource-group "aks-resource-group" --name "ray-worker-identity" --query "clientId" -o tsv)
az identity federated-credential create \
  --name "ray-worker-federated-credential" \
  --identity-name "ray-worker-identity" \
  --resource-group "aks-resource-group" \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:ai-platform:ray-worker-sa" \
  --audience "api://AzureADTokenExchange"

# SAIA Service Identity
az identity create --resource-group "aks-resource-group" --name "saia-service-identity"
export SAIA_CLIENT_ID=$(az identity show --resource-group "aks-resource-group" --name "saia-service-identity" --query "clientId" -o tsv)
az identity federated-credential create \
  --name "saia-service-federated-credential" \
  --identity-name "saia-service-identity" \
  --resource-group "aks-resource-group" \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:ai-platform:saia-service-sa" \
  --audience "api://AzureADTokenExchange"
```

#### Create Premium SSD Storage Class
Create the storage class file for Azure Premium SSD. In the following examples, the file name is `storageclass.yaml`.
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-premium-ssd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
  kind: Managed
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

Apply the storage class with the following command:
```bash
kubectl apply -f storageclass.yaml
```

### Google Cloud GKE Setup

#### Set Project and Region
Set the default project and region for your GKE cluster. Update the `PROJECT_ID` and `REGION` values with your desired configuration.
```bash
export PROJECT_ID="your-project-id"
export REGION="us-central1"
export ZONE="us-central1-a"

gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
gcloud config set compute/zone "${ZONE}"
```

#### Enable Required APIs
Enable the required Google Cloud APIs for GKE, including container, compute, and IAM APIs:
```bash
gcloud services enable container.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
```

#### Create the GKE Cluster
Create the GKE cluster with the required configuration including:
- name
- zone/region
- node pools (default pool for CPU nodes)
- enable Workload Identity
- enable cluster autoscaling
- release channel

Create the cluster with CPU nodes:
```bash
gcloud container clusters create "cluster-name" \
  --region "${REGION}" \
  --machine-type "n2-standard-4" \
  --disk-size "500" \
  --disk-type "pd-balanced" \
  --num-nodes 2 \
  --min-nodes 2 \
  --max-nodes 8 \
  --enable-autoscaling \
  --enable-autorepair \
  --enable-autoupgrade \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver \
  --release-channel regular \
  --labels "environment=prod,name=cluster-name-cpu"
```

Add a GPU node pool to the cluster:
```bash
gcloud container node-pools create "gpu-pool" \
  --cluster "cluster-name" \
  --region "${REGION}" \
  --machine-type "a2-highgpu-1g" \
  --accelerator "type=nvidia-tesla-a100,count=1" \
  --disk-size "1000" \
  --disk-type "pd-balanced" \
  --num-nodes 0 \
  --min-nodes 0 \
  --max-nodes 3 \
  --enable-autoscaling \
  --enable-autorepair \
  --enable-autoupgrade \
  --node-taints "dedicated=gpu:NoSchedule" \
  --labels "environment=prod,name=cluster-name-gpu"
```

Install the NVIDIA GPU device drivers on the GPU nodes:
```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded-latest.yaml
```

#### Configure kubectl Access
Get credentials for the newly created cluster to configure kubectl access:
```bash
gcloud container clusters get-credentials "cluster-name" --region "${REGION}"
```

Verify the connection to the cluster:
```bash
kubectl get nodes
```

#### Enable Workload Identity
Workload Identity should already be enabled if the `--workload-pool` flag was used during cluster creation. Verify Workload Identity is enabled:
```bash
gcloud container clusters describe "cluster-name" --region "${REGION}" --format="value(workloadIdentityConfig.workloadPool)"
```

The output should show `${PROJECT_ID}.svc.id.goog`. If Workload Identity is not enabled, enable it with:
```bash
gcloud container clusters update "cluster-name" --region "${REGION}" --workload-pool="${PROJECT_ID}.svc.id.goog"
```

Update existing node pools to use Workload Identity:
```bash
gcloud container node-pools update "default-pool" \
  --cluster "cluster-name" \
  --region "${REGION}" \
  --workload-metadata=GKE_METADATA

gcloud container node-pools update "gpu-pool" \
  --cluster "cluster-name" \
  --region "${REGION}" \
  --workload-metadata=GKE_METADATA
```

#### Verify GKE CSI Driver
The GKE CSI driver (GcePersistentDiskCsiDriver) should be enabled by default or was enabled during cluster creation. Verify the CSI driver is running:
```bash
kubectl get pods -n kube-system | grep csi
```

If not present, you can enable it with:
```bash
gcloud container clusters update "cluster-name" --region "${REGION}" --update-addons=GcePersistentDiskCsiDriver=ENABLED
```

Verify the CSI driver pods are running:
```bash
kubectl get pods -n kube-system -l k8s-app=gcp-compute-persistent-disk-csi-driver
```

#### Create Service Accounts and Workload Identity Bindings
Create Google Service Accounts (GSAs) and bind them to Kubernetes Service Accounts (KSAs) for Workload Identity.

1. Set the cluster namespace:
```bash
export NAMESPACE="ai-platform"
kubectl create ns "${NAMESPACE}"
```

2. Create Google Service Account for Ray Head:
```bash
gcloud iam service-accounts create ray-head-sa \
  --display-name="Ray Head Service Account" \
  --project="${PROJECT_ID}"
```

3. Create the Kubernetes service account and annotate it for Workload Identity:
```bash
kubectl create serviceaccount ray-head-sa --namespace="${NAMESPACE}"

kubectl annotate serviceaccount ray-head-sa \
  --namespace="${NAMESPACE}" \
  iam.gke.io/gcp-service-account="ray-head-sa@${PROJECT_ID}.iam.gserviceaccount.com"
```

4. Bind the Google Service Account to the Kubernetes Service Account:
```bash
gcloud iam service-accounts add-iam-policy-binding \
  "ray-head-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/ray-head-sa]"
```

5. Repeat the process for Ray Worker service account:
```bash
# Create GSA
gcloud iam service-accounts create ray-worker-sa \
  --display-name="Ray Worker Service Account" \
  --project="${PROJECT_ID}"

# Create KSA and annotate
kubectl create serviceaccount ray-worker-sa --namespace="${NAMESPACE}"
kubectl annotate serviceaccount ray-worker-sa \
  --namespace="${NAMESPACE}" \
  iam.gke.io/gcp-service-account="ray-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Bind GSA to KSA
gcloud iam service-accounts add-iam-policy-binding \
  "ray-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/ray-worker-sa]"
```

6. Repeat the process for SAIA service account:
```bash
# Create GSA
gcloud iam service-accounts create saia-service-sa \
  --display-name="SAIA Service Account" \
  --project="${PROJECT_ID}"

# Create KSA and annotate
kubectl create serviceaccount saia-service-sa --namespace="${NAMESPACE}"
kubectl annotate serviceaccount saia-service-sa \
  --namespace="${NAMESPACE}" \
  iam.gke.io/gcp-service-account="saia-service-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Bind GSA to KSA
gcloud iam service-accounts add-iam-policy-binding \
  "saia-service-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/saia-service-sa]"
```

#### Create pd-balanced Storage Class
Create the storage class file for Google Cloud Persistent Disk. In the following examples, the file name is `storageclass.yaml`.
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: pd-balanced
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-balanced
  fstype: ext4
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

Apply the storage class with the following command:
```bash
kubectl apply -f storageclass.yaml
```

## Prerequisite App Installation
There are a few deployments that have to be available in order for the Splunk AI Operator to work correctly. Install the following to continue with the setup.

### Cluster Autoscaler
The cluster autoscaler requires an iamserviceaccount to be created. Start by running the following command:
```bash
eksctl create iamserviceaccount  --cluster "cluster-name" \
    --name "cluster-autoscaler" \
    --namespace "kube-system" \
    --role-name "ClusterAutoscalerRole-cluster-name" \
    --attach-policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess \
    --approve \
    --override-existing-serviceaccounts
```

Next, verify the helm chart is up to date.
```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
```

Finally, install the cluster-autoscaler helm chart with the following command:
```bash
helm_retry 5 upgrade --install "cluster-autoscaler" autoscaler/cluster-autoscaler \
    --namespace "kube-system" \
    --set autoDiscovery.clusterName="cluster-name" \
    --set awsRegion="us-west-2" \
    --set rbac.serviceAccount.create=false \
    --set rbac.serviceAccount.name="cluster-autoscaler" \
    --set image.repository=registry.k8s.io/autoscaling/cluster-autoscaler \
    --set image.tag="v1.31.2" \
    --set extraArgs.balance-similar-node-groups=true \
    --set extraArgs.skip-nodes-with-system-pods=false \
    --set extraArgs.expander=least-waste \
    --wait --timeout 15m
```

### NVIDIA Device Plugin
The NVIDIA device plugin allows for managing the GPUs on the cluster. Install it with the following commands:
```bash
kubectl apply -n kube-system -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.3/deployments/static/nvidia-device-plugin.yml"
kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=10m
```

### Uncordon Ready Nodes
Some of the processes can leave nodes on the cluster unschedulable. Set them back to a good state with the following steps.
1. Get the list of nodes that are marked as SchedulingDisabled
```bash
kubectl get nodes --no-headers | awk '/SchedulingDisabled/ {print $1}'
```
2. For each of the nodes in the output from Step 1, check if they are in the Ready state
```bash
kubectl get node "<node-name>" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```
3. For each node in the Ready state, uncordon the node
```bash
kubectl uncordon "<node-name>"
```

### Kube Prometheus Stack
Set up Kubernetes cluster monitoring with the kube prometheus stack deployment.

First, verify the helm chart is up to date.
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Then, install the kube-prometheus-stack helm chart with the following command:
```bash
helm_retry 5 upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace --wait --timeout 15m
```

### Cert Manager
Cert manager is required to create and manage TLS certificates on the cluster.

First, verify the helm chart is up to date.
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

Then, install the cert-manager helm chart with the following command:
```bash
helm_retry 5 upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true --wait --timeout 15m
```

### OpenTelemtry Operator
OpenTelemetry facilitates the generation, export, and collection of telemetry data.

First, verify the helm chart is up to date.
```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

Then, install the ope helm chart with the following command:
```bash
helm_retry 5 upgrade --install otel-operator open-telemetry/opentelemetry-operator --namespace observability --create-namespace --set admissionWebhooks.certManager.enabled=true --wait --timeout 15m
```

Installing the OpenTelemetry Collector depends on the apiversion of the OTel api version. In the following two examples, the config file should be named otel_collector_config.yaml.
If the OTel api version is v1beta1, use:
```yaml
apiVersion: ${apiversion}
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: observability
spec:
  image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest
  mode: deployment
  replicas: 1
  config:
    receivers:
      otlp:
        protocols: { grpc: {}, http: {} }
    processors: { batch: {} }
    exporters: { debug: {} }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [batch], exporters: [debug] }
        metrics: { receivers: [otlp], processors: [batch], exporters: [debug] }
        logs:    { receivers: [otlp], processors: [batch], exporters: [debug] }
```

Otherwise, use:
```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: observability
spec:
  image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest
  mode: deployment
  replicas: 1
  config: |
    receivers:
      otlp:
        protocols:
          grpc: {}
          http: {}
    processors:
      batch: {}
    exporters:
      debug: {}
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
```

Install the OpenTelemetry Collector with the following command:
```bash
kubectl apply --server-side --force-conflicts -f otel_collector_config.yaml
```

### Ray Operator
The Ray Operator aides in managing Ray services for scaling the AI application.

Install the Ray Operator with the following command:
```bash
kubectl apply -k "github.com/ray-project/kuberay/ray-operator/config/default?ref=v1.2.2" --server-side --force-conflicts
```

## Splunk Setup

### Splunk Operator Installation (Optional)
The Splunk Operator creates and manages Splunk custom resources. A Splunk instance is requried to run the Splunk AI Assitant app. **If you do not have a Splunk instance running**, use these steps to deploy one using the Splunk Operator for Kubernetes.

Install the Splunk Operator with the following command:
```bash
kubectl apply -f https://github.com/splunk/splunk-operator/releases/download/3.0.0/splunk-operator-cluster.yaml --server-side --force-conflicts
```

Verify that the Splunk Operator and Splunk Enterprise versions used support the Splunk AI Assistant app.

### Splunk AI Operator Installation
The Splunk AI Operator handles the Ray Services, and AI Platform and AI Service custom resources to install the Splunk AI Assistant app on the deployed splunk instance.

TODO: explain where to get artifacts.yaml. Will it be on VOC or add a link to the github repo?
First, download the artifacts.yaml file for the Splunk AI Operator. 

Next, create the namespace if it does not exist yet with the following command:
```bash
kubectl create ns splunk-ai-operator-system
```

Install the Splunk AI Operator with the following command:
```bash
kubectl apply -f artifacts.yaml --server-side --force-conflicts
```

### AWS S3 Bucket Setup
The AI Platform expects the S3 compatible bucket to have specific prefixes for the folders, and apps uploaded.

Create an S3 compatible bucket with a unique name that will be used in the CRs. In the bucket, create three folders, with the exact names `artifacts/`, `apps/`, and `tasks/`. Upload the Splunk_AI_Assistant_Cloud.tgz app into the `apps/` folder.

Next, create the namespace where the Splunk and Splunk IA Platform deployment will be created with the following command:
```bash
kubectl create ns ai-platform
```

#### IAM Policy for S3 Bucket
Create an IAM policy for the S3 bucket by first creating the following policy file:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid":"ListBucket","Effect":"Allow","Action":["s3:ListBucket"],"Resource":"arn:aws:s3:::${bucket}" },
    { "Sid":"ObjectRW","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts","s3:ListBucketMultipartUploads"],"Resource":"arn:aws:s3:::${bucket-name}/*" }
  ]
}
```

Then, create the policy with the following command:
```bash
aws iam create-policy --policy-name S3Access-cluster-name-ai-platform --policy-document "file://policy_document.json" --query 'Policy.Arn' --output text
```

Save the output policy arn for the following IRSA for Service Accounts steps.

#### IRSA for Service Accounts
Create an IRSA role for the Ray Head Service Account with the following command:
```bash
eksctl create iamserviceaccount \
    --cluster cluster-name \
    --namespace ai-platform \
    --name ray-head-sa \
    --role-name IRSA-cluster-name-ray-head-sa \
    --attach-policy-arn <policy arn from s3 bucket policy> \
    --approve \
    --override-existing-serviceaccounts
```

Create an IRSA role for the Ray Worker Service Account with the following command:
```bash
eksctl create iamserviceaccount \
    --cluster cluster-name \
    --namespace ai-platform \
    --name ray-worker-sa \
    --role-name IRSA-cluster-name-ray-worker-sa \
    --attach-policy-arn <policy arn from s3 bucket policy> \
    --approve \
    --override-existing-serviceaccounts
```

Create an IRSA role for the SAIA Service Account with the following command:
```bash
eksctl create iamserviceaccount \
    --cluster cluster-name \
    --namespace ai-platform \
    --name saia-service-sa \
    --role-name IRSA-cluster-name-saia-service-sa \
    --attach-policy-arn <policy arn from s3 bucket policy> \
    --approve \
    --override-existing-serviceaccounts
```

### Azure Blob Storage Setup
The AI Platform expects the Azure Blob Storage container to have specific prefixes for the folders, and apps uploaded.

Create an Azure Storage Account and Blob container with a unique name that will be used in the CRs. In the container, create three folders with the exact names `artifacts/`, `apps/`, and `tasks/`. Upload the Splunk_AI_Assistant_Cloud.tgz app into the `apps/` folder.

First, create the storage account:
```bash
export STORAGE_ACCOUNT_NAME="splunkaistorage"
export RESOURCE_GROUP="aks-resource-group"
export LOCATION="eastus"
export CONTAINER_NAME="ai-platform-data"

az storage account create \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2
```

Create the blob container:
```bash
az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --auth-mode login
```

Upload the folder structure and app:
```bash
# Create folder structure (using empty blobs as markers)
az storage blob upload \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --container-name "${CONTAINER_NAME}" \
  --name "artifacts/.keep" \
  --file /dev/null \
  --auth-mode login

az storage blob upload \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --container-name "${CONTAINER_NAME}" \
  --name "apps/.keep" \
  --file /dev/null \
  --auth-mode login

az storage blob upload \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --container-name "${CONTAINER_NAME}" \
  --name "tasks/.keep" \
  --file /dev/null \
  --auth-mode login

# Upload the Splunk AI Assistant app
az storage blob upload \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --container-name "${CONTAINER_NAME}" \
  --name "apps/Splunk_AI_Assistant_Cloud.tgz" \
  --file "path/to/Splunk_AI_Assistant_Cloud.tgz" \
  --auth-mode login
```

Next, create the namespace where the Splunk and Splunk AI Platform deployment will be created with the following command (if not already created):
```bash
kubectl create ns ai-platform
```

#### Role Assignments for Managed Identities
Grant the managed identities permissions to access the Azure Blob Storage container.

1. Get the storage account resource ID:
```bash
export STORAGE_ACCOUNT_ID=$(az storage account show \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query "id" -o tsv)
```

2. Assign the "Storage Blob Data Contributor" role to Ray Head managed identity:
```bash
export RAY_HEAD_PRINCIPAL_ID=$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "ray-head-identity" \
  --query "principalId" -o tsv)

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${RAY_HEAD_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STORAGE_ACCOUNT_ID}"
```

3. Assign the role to Ray Worker managed identity:
```bash
export RAY_WORKER_PRINCIPAL_ID=$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "ray-worker-identity" \
  --query "principalId" -o tsv)

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${RAY_WORKER_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STORAGE_ACCOUNT_ID}"
```

4. Assign the role to SAIA Service managed identity:
```bash
export SAIA_PRINCIPAL_ID=$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "saia-service-identity" \
  --query "principalId" -o tsv)

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${SAIA_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STORAGE_ACCOUNT_ID}"
```

#### Create Azure Storage Secret
Create a Kubernetes secret with the Azure Storage account credentials:
```bash
export STORAGE_ACCOUNT_KEY=$(az storage account keys list \
  --resource-group "${RESOURCE_GROUP}" \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --query "[0].value" -o tsv)

kubectl -n ai-platform create secret generic azure-storage-secret \
  --from-literal=azure_storage_account="${STORAGE_ACCOUNT_NAME}" \
  --from-literal=azure_storage_key="${STORAGE_ACCOUNT_KEY}"
```

### Google Cloud Storage Setup
The AI Platform expects the Google Cloud Storage bucket to have specific prefixes for the folders, and apps uploaded.

Create a Google Cloud Storage bucket with a unique name that will be used in the CRs. In the bucket, create three folders with the exact names `artifacts/`, `apps/`, and `tasks/`. Upload the Splunk_AI_Assistant_Cloud.tgz app into the `apps/` folder.

First, create the GCS bucket:
```bash
export BUCKET_NAME="splunk-ai-platform-${PROJECT_ID}"
export REGION="us-central1"

gsutil mb -p "${PROJECT_ID}" -c STANDARD -l "${REGION}" "gs://${BUCKET_NAME}"
```

Create the folder structure and upload the app:
```bash
# Create folder structure (using empty objects as markers)
echo "" | gsutil cp - "gs://${BUCKET_NAME}/artifacts/.keep"
echo "" | gsutil cp - "gs://${BUCKET_NAME}/apps/.keep"
echo "" | gsutil cp - "gs://${BUCKET_NAME}/tasks/.keep"

# Upload the Splunk AI Assistant app
gsutil cp "path/to/Splunk_AI_Assistant_Cloud.tgz" "gs://${BUCKET_NAME}/apps/"
```

Next, create the namespace where the Splunk and Splunk AI Platform deployment will be created with the following command (if not already created):
```bash
kubectl create ns ai-platform
```

#### IAM Policy Bindings for Service Accounts
Grant the Google Service Accounts permissions to access the GCS bucket.

1. Assign the "Storage Object Admin" role to Ray Head service account:
```bash
gsutil iam ch "serviceAccount:ray-head-sa@${PROJECT_ID}.iam.gserviceaccount.com:roles/storage.objectAdmin" "gs://${BUCKET_NAME}"
```

Alternatively, use gcloud to grant project-level access:
```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:ray-head-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" \
  --condition=None
```

2. Assign the role to Ray Worker service account:
```bash
gsutil iam ch "serviceAccount:ray-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com:roles/storage.objectAdmin" "gs://${BUCKET_NAME}"
```

Or with gcloud:
```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:ray-worker-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" \
  --condition=None
```

3. Assign the role to SAIA service account:
```bash
gsutil iam ch "serviceAccount:saia-service-sa@${PROJECT_ID}.iam.gserviceaccount.com:roles/storage.objectAdmin" "gs://${BUCKET_NAME}"
```

Or with gcloud:
```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:saia-service-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" \
  --condition=None
```

#### Create GCS Secret
Create a Kubernetes secret with the GCS bucket information:
```bash
# For Workload Identity, the service accounts use their annotations
# But if you need explicit credentials, create a service account key:
gcloud iam service-accounts keys create gcs-key.json \
  --iam-account="saia-service-sa@${PROJECT_ID}.iam.gserviceaccount.com"

kubectl -n ai-platform create secret generic gcs-secret \
  --from-file=gcs-key.json=gcs-key.json

# Clean up the local key file
rm gcs-key.json
```

Note: With Workload Identity properly configured, explicit credentials may not be necessary as the service accounts will automatically authenticate using their annotated identities.

### Splunk Standalone Installation
A Splunk Standalone instance is needed to install and use the Splunk AI Assistant app.

#### Option 1: Splunk Already Installed
If a Splunk instance is already deployed, you can use the existing instance to connect to the AI tier. 

First, update the /opt/splunk/etc/system/local/authentication.conf file to include the following contents
```
[oauth2_settings]
issuer_uri=https://splunk-splunk-standalone-standalone-service:8089
certFile=$SPLUNK_HOME/etc/auth/server.pem
sslPassword=password
```

Then, install the Splunk AI Assistant App on your splunk instance.

#### Option 2: Install Splunk Standalone Using the Splunk Operator for Kubernetes
The instructions here are specific to an AWS EKS cluster. Please follow the instructions in the [App Framework documentation](https://github.com/splunk/splunk-operator/blob/main/docs/AppFramework.md) from the Splunk Operator for Kubernetes for other storage types regarding the secret and app framework configuration.

First, create an s3 secret to connect to the s3 bucket with the following command:
```bash
kubectl -n ai-platform create secret generic s3-secret --from-literal=s3_access_key="$AWS_ACCESS_KEY_ID" --from-literal=s3_secret_key="$AWS_SECRET_ACCESS_KEY"
```

Next, create a configmap for the Splunk defaults:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: splunk-defaults
data:
  default.yml: |
    splunk:
      conf:
        - key: authentication
          value:
            directory: /opt/splunk/etc/system/local
            content:
              oauth2_settings:
                issuer_uri: https://splunk-splunk-standalone-standalone-service:8089
                certFile: $SPLUNK_HOME/etc/auth/server.pem
                sslPassword: password
```
```bash
kubectl -n ai-platform apply -f configmap.yaml
```

Then, create a standalone instance with appRepo sources pointing to the s3 bucket.
```yaml
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: splunk-standalone
  namespace: ai-platform
spec:
  serviceAccount: saia-service-sa
  etcVolumeStorageConfig:
    storageClassName: gp3
  varVolumeStorageConfig:
    storageClassName: gp3
  volumes:
    - name: defaults
      configMap:
        name: splunk-defaults
  defaultsUrl: /mnt/defaults/default.yml
  appRepo:
    appInstallPeriodSeconds: 90
    appSources:
      - name: apps
        scope: local
        location: apps
    appsRepoPollIntervalSeconds: 60
    defaults:
      scope: local
      volumeName: volume_app_repo
    installMaxRetries: 2
    volumes:
      - name: volume_app_repo
        provider: aws
        storageType: s3
        endpoint: https://s3.amazonaws.com
        region: us-west-2
        path: bucket-name
        secretRef: s3-secret
```
```bash
kubectl apply -f standalone.yaml --server-side --force-conflicts
```

### Splunk AI Platform CR Installation
Start by finding the latest Splunk standlone secret. Run the following command, and choose the version with the highest number:
```bash
kubectl get secrets -n ai-platform
```
The correct secret is the secret with the name `splunk-splunk-standalone-standalone-secret-v1`, or that of the highest version.

Apply the cert-manager CR with the following spec:
```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: platform-issuer
spec:
  isCA: true
  commonName: my-selfsigned-ca
  secretName: root-secret
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: selfsigned-issuer, kind: Issuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: my-ca-issuer
spec:
  ca: { secretName: root-secret }
```
```bash
kubectl -n ai-platform apply --server-side --force-conflicts -f cert_manager.yaml
```

The `splunkConfiguration` section in the following spec should point to your Splunk instance. The example includes the splunkConfiguration deployed by the Splunk Operator for Kubernetes in earlier steps.
Apply the AI Platform CR with the following spec:
```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: splunk-ai-stack
spec:
  objectStorage:
    path: s3://bucket-name
    region: us-west-2
  serviceAccountName: ray-head-sa
  defaultAcceleratorType: L40S
  features:
    - name: saia
      version: "1.1.0"
      serviceAccountName: saia-service-sa
  storage:
    vectorDB:
      size: 50Gi
      storageClassName: gp3
  workerGroupSpec:
    serviceAccountName: ray-worker-sa
    gpuConfigs:
      - tier: g6e.12xlarge-0-gpu
        minReplicas: 0
        maxReplicas: 10
        gpusPerPod: 0
        resources:
          limits: { cpu: "16", memory: "32Gi", ephemeral-storage: "10Gi", nvidia.com/gpu: "0" }
          requests: { cpu: "4" }
      - tier: g6e.12xlarge-1-gpu
        minReplicas: 0
        maxReplicas: 10
        gpusPerPod: 1
        resources:
          requests: { cpu: "4" }
          limits: { cpu: "16", memory: "16Gi", ephemeral-storage: "50Gi", nvidia.com/gpu: "1" }
      - tier: g6e.12xlarge-2-gpu
        minReplicas: 0
        maxReplicas: 10
        gpusPerPod: 2
        resources:
          requests: { cpu: "1" }
          limits: { cpu: "2", memory: "48Gi", ephemeral-storage: "100Gi", nvidia.com/gpu: "2" }
      - tier: g6e.12xlarge-4-gpu
        minReplicas: 0
        maxReplicas: 10
        gpusPerPod: 4
        resources:
          requests: { cpu: "1" }
          limits: { cpu: "4", memory: "64Gi", ephemeral-storage: "200Gi", nvidia.com/gpu: "4" }
  cpuScheduler: {}
  gpuScheduler:
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
  ingress:
    className: nginx
    hosts:
      - host: ai.example.com
        paths: [ { path: "/", pathType: Prefix } ]
    tls:
      - hosts: [ ai.example.com ]
        secretName: ai-platform-tls
  splunkConfiguration:
    endpoint: splunk-standalone-standalone-service
    secretRef: { name: ${secret_name} }
  certificateRef: platform-issuer
```
```bash
kubectl -n ai-platform apply --server-side --force-conflicts -f ai_platform.yaml
```

TODO: Is it required to add the saia_sok_url? Or will that be done by the app? If it is done by the app, we need to change this section on how to get the url and walk through setting it up in the app.
#### Option 1: Splunk Instance Deployed through Other Avenues
Verify that the Splunk AI Assistant app is deployed on the standalone instance.

Edit the splunkaiassistant.conf file on the standalone pod to set the configurations. Find the splunkaiassistant.conf file on the pod.
```bash
cd /opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/default
cat splunkaiassistant.conf
```
If the file does not exist, create it.

Edit the contents of splunkaiassistant.conf to be the following:
```
[splunk_ai_assistant]
feedback_enabled=true

[cloud_connected_configurations]

[cloud_connected_configurations:proxy_settings]

[saia_sok_configurations]
saia_sok_enabled=true
saia_sok_url=<url to splunk instance>
```

Restart the Splunk instance with the following command:
```bash
/opt/bin/splunk restart
```

Wait for the instance to come up, connect to it, and start using the Splunk AI Assistant app!

#### Option 2: Splunk Instance Deployed through Splunk Operator for Kubernetes
Verify that the Splunk AI Assistant app is deployed on the standalone instance. Run the following command and see that the deploy status is complete:
```bash
kubectl get standalone splunk-standalone -n ai-platform -o yaml
```

Finally, edit the splunkaiassistant.conf file on the standalone pod to set the configurations.
Exec into the pod using the following command:
```bash
kubectl exec -it splunk-splunk-standalone-standalone-0 -n ai-platform -- bash
```

Find the splunkaiassistant.conf file on the pod.
```bash
cd /opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/default
cat splunkaiassistant.conf
```
If the file does not exist, create it.

Edit the contents of splunkaiassistant.conf to be the following:
```
[splunk_ai_assistant]
feedback_enabled=true

[cloud_connected_configurations]

[cloud_connected_configurations:proxy_settings]

[saia_sok_configurations]
saia_sok_enabled=true
saia_sok_url=http://splunk-ai-stack-saia-saia-service:8080
```

Restart the Splunk instance with the following command:
```bash
/opt/bin/splunk restart
```

Wait for the pod to come up, connect to it, and start using the Splunk AI Assistant app!