# Service Artifacts Storage

## Splunk AI Artifacts
The Splunk AI team has provided global artifact storage in a publicly readable S3 bucket. This bucket contains LLM model files and weaviate bootstrap data. In order to create the Splunk AI Platform and Splunk AI Service CRs, users need to have a storage bucket created to transfer the data. Include the bucket connection information in the `spec.volume` field in the [Splunk AI Platform CR](api-reference.md#ai-platform-spec-parameters) to trigger a job to transfer the data from the public bucket to the local bucket.

## Prerequisites

Utilizing the AI Platform requires one of the following remote storage providers:
   * **AWS S3** – Native Amazon S3 (use path scheme `s3://`)
   * **MinIO** – S3-compatible, in-cluster or external (use path scheme `s3compat://` or `minio://` with endpoint and credentials)
   * **SeaweedFS** – S3-compatible (use path scheme `s3compat://` or `seaweedfs://` with endpoint and credentials)
   * Any other **S3-API-compatible** storage (use `s3compat://` with endpoint and secretRef; `minio://` and `seaweedfs://` are optional aliases)
   * Azure blob storage
   * GCP Cloud Storage

### Object storage selection

The operator chooses the backend **by the path scheme** in `spec.objectStorage.path`. Use `s3://` for AWS S3 only; use `s3compat://` (or `minio://` / `seaweedfs://` as aliases) with `endpoint` and `secretRef` for MinIO, SeaweedFS, or any S3-compatible backend. See [Object Storage Selection](object-storage.md) for the full decision table, path schemes, and YAML examples.

### Prerequisites common to all remote storage providers
* Read-write access to the path used to host the files.
* Connections to the remote object storage endpoint need to be secured using a minimum version of TLS 1.2.
* Three folders are created within the bucket with the following names: `artifacts`, `tasks`, `models`
    So, the three paths should be:
    ```
    s3://bucket/artifacts
	s3://bucket/tasks
	s3://bucket/models
    ```

### Prerequisites for S3 based remote object storage
* Create role and role-binding for splunk-ai-operator service account, to provide read-write access for S3 credentials.
* The remote object storage credentials provided as a kubernetes secret, or in an IAM role.
* If you are using [interface VPC endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/create-interface-endpoint.html) with DNS enabled to access AWS S3, please update the corresponding volume endpoint URL with one of the `DNS names` from the endpoint. Please ensure that the endpoint has access to the S3 buckets using the credentials configured. Similarly other endpoint URLs with access to the S3 buckets can also be used.

### Prerequisites for Azure Blob remote object storage
* The remote object storage credentials provided as a kubernetes secret.
* OR, Use "Managed Identity" role assignment to the Azure blob container. See [Setup Azure blob access with Managed Identity](#setup-azure-blob-access-with-managed-identity)

### Prerequisites for GCP bucket based remote object storage
To use GCP storage, follow these setup requirements:

#### Role & Role Binding for Access: 
Create a role and role-binding for the splunk-ai-operator service account. This allows read-write access to the GCP bucket to retrieve Splunk AI artifacts.

#### Credentials via Kubernetes Secret or Workload Identity: 
Configure credentials through either a Kubernetes secret (e.g., storing a GCP service account key in key.json) or use Workload Identity for secure access:

* **Kubernetes Secret**: Create a Kubernetes secret using the service account JSON key file for GCP access.
* **Workload Identity**: Use Workload Identity to associate the Kubernetes service account used by the Splunk AI Operator with a GCP service account that has the Storage Object Viewer IAM role for the required bucket.

#### Example for creating the secret

```shell
kubectl create secret generic gcs-secret --from-file=key.json=path/to/your-service-account-key.json
```

## Setup Azure Blob Access with Managed Identity

Azure Managed Identities can be used to provide IAM access to the blobs. With managed identities, the AKS nodes that host the pods can retrieve an OAuth token that provides authorization for the Splunk AI Operator pod to read the app packages stored in the Azure Storage account. The key point here is that the AKS node is associated with a Managed Identity, and this managed identity is given a `role` for read and write access called `Storage Blob Data Contributor` to the Azure Storage account.

### **Assumptions:**

- Familiarize yourself with [AKS managed identity concepts](https://learn.microsoft.com/en-us/azure/aks/use-managed-identity)
- The names used below, such as resource-group name and AKS cluster name, are for example purposes only. Please change them to the values as per your setup.
- These steps cover creating a resource group and AKS cluster; you can skip them if you already have them created.

### **Steps to Assign Managed Identity:**

1. **Create an Azure Resource Group**

    ```bash
    az group create --name splunkAIOperatorResourceGroup --location westus2
    ```

2. **Create AKS Cluster with Managed Identity Enabled**

    ```bash
    az aks create -g splunkAIOperatorResourceGroup -n splunkAIOperatorCluster --enable-managed-identity
    ```

3. **Get Credentials to Access Cluster**

    ```bash
    az aks get-credentials --resource-group splunkAIOperatorResourceGroup --name splunkAIOperatorCluster
    ```

4. **Get the Kubelet User Managed Identity**

    Run:

    ```bash
    az identity list
    ```

    Find the section that has `<AKS Cluster Name>-agentpool` under `name`. For example, look for the block that contains:

    ```json
    {
      "clientId": "a5890776-24e6-4f5b-9b6c-**************",
      "id": "/subscriptions/<subscription-id>/resourceGroups/MC_splunkAIOperatorResourceGroup_splunkAIOperatorCluster_westus2/providers/Microsoft.ManagedIdentity/userAssignedIdentities/splunkAIOperatorCluster-agentpool",
      "location": "westus2",
      "name": "splunkAIOperatorCluster-agentpool",
      "principalId": "f0f0.2.0-6a36-49bc--**************",
      "resourceGroup": "MC_splunkAIOperatorResourceGroup_splunkAIOperatorCluster_westus2",
      "tags": {},
      "tenantId": "8add7810-b62a--**************",
      "type": "Microsoft.ManagedIdentity/userAssignedIdentities"
    }
    ```

    Extract the `principalId` value from the output above. Alternatively, use the following command to get the `principalId`:

    ```bash
    az identity show --name <identityName> --resource-group "<resourceGroup>" --query 'principalId' --output tsv
    ```

    **Example:**

    ```bash
    principalId=$(az identity show --name splunkAIOperatorCluster-agentpool --resource-group "MC_splunkAIOperatorResourceGroup_splunkAIOperatorCluster_westus2" --query 'principalId' --output tsv)
    echo $principalId
    ```

    Output:

    ```
    f0f0.2.0-6a36-49bc--**************
    ```

5. **Assign Read-Write Access for Kubelet User Managed Identity to the Storage Account**

    Use the `principalId` from the above section and assign it to the storage account:

    ```bash
    az role assignment create --assignee "<principalId>" --role 'Storage Blob Data Contributor' --scope /subscriptions/<subscription_id>/resourceGroups/<storageAccountResourceGroup>/providers/Microsoft.Storage/storageAccounts/<storageAccountName>
    ```

    **For Example:**

    If `<storageAccountResourceGroup>` is `splunkAIOperatorResourceGroup` and `<storageAccountName>` is `mystorageaccount`, the command would be:

    ```bash
    az role assignment create --assignee "f0f0.2.0-6a36-49bc--**************" --role 'Storage Blob Data Contributor' --scope /subscriptions/f428689e-c379-4712--**************/resourceGroups/splunkAIOperatorResourceGroup/providers/Microsoft.Storage/storageAccounts/mystorageaccount
    ```

    After this command, you can connect to Azure Blob without secrets.

### **Azure Blob Authorization Recommendations:**

- **Granular Access:** Azure allows **"Managed Identities"** assignment at the **"storage accounts"** level as well as at specific containers (buckets) levels. A managed identity assigned read permissions at a storage account level will have read access for all containers within that storage account. As a good security practice, assign the managed identity to only the specific containers it needs to access, rather than the entire storage account.
  
- **Avoid Shared Access Keys:** In contrast to **"Managed Identities"**, Azure allows **"shared access keys"** configurable only at the storage accounts level. When using the `secretRef` configuration in the CRD, the underlying secret key will allow both read and write access to the storage account (and all containers within it). Based on your security needs, consider using "Managed Identities" instead of secrets. Additionally, there's no automated way to rotate the secret key, so if you're using these keys, rotate them regularly (e.g., every 90 days).
