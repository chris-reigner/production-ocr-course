# ☁️ Cloud Provider Architecture Comparison: AKS vs. GKE vs. EKS

This document provides an architecture and operational comparison between the **Azure Kubernetes Service (AKS)**, **Google Kubernetes Engine (GKE)**, and **Amazon Elastic Kubernetes Service (EKS)** implementations for this SLM-Powered OCR repository.

---

## 🎯 Architectural Overview: Shared Foundation

Both cloud deployments share an identical core application stack and metric-driven scaling philosophy:

* **Ingest Gateway**: High-concurrency Rust Producer API (`ocr-api-rust`) running on CPU-optimized nodes (`apinp`).
* **State Store**: High-memory Redis instance (`ocr-redis`) acting as a temporary document store and task queue.
* **Layout Engine**: Asynchronous Python Consumer Worker (`ocr-worker-rt`) running layout analysis (**PP-DocLayoutV3**) on T4 GPUs (`gpunpt4`) with dynamic collector batching.
* **SLM Inference Engine**: **vLLM** serving **Qwen 3.5 (4B)** on A100 80GB GPUs (`gpunpa100`) with Multi-Token Prediction (MTP) and continuous batching.
* **Autoscaling Mechanics**: **KEDA** scaled objects monitoring Redis list length (`ocr_tasks`) and Prometheus metrics (`vllm:num_requests_waiting`).
* **Zero-Copy Handoff**: Document buffers rasterized directly into `/dev/shm` Linux shared memory.

---

## 📊 Technical Discrepancies Matrix

The following table summarizes the provider-specific infrastructure configurations and manifest differences:

| Architectural Component | Azure Kubernetes Service (AKS) | Google Kubernetes Engine (GKE) | Amazon Elastic Kubernetes Service (EKS) | Technical Rationale & Impact |
| :--- | :--- | :--- | :--- | :--- |
| **CLI & Auth** | `az cli` / `az login` | `gcloud sdk` / `gcloud auth login` | `aws cli` / `aws configure` | Cloud-native CLI commands for cluster management and credential fetching. |
| **Container Registry** | **Azure Container Registry (ACR)**<br>`acrocrinference.azurecr.io` | **Google Artifact Registry (AR)**<br>`us-central1-docker.pkg.dev/...` | **Elastic Container Registry (ECR)**<br>`<acct>.dkr.ecr.eu-central-1.amazonaws.com/...` | Regional image repository host per cloud ecosystem. |
| **GPU Driver Lifecycle** | Helm-installed **NVIDIA GPU Operator** (`k8s/aks/infra/gpu-operator-values.yaml`) | **Natively Managed GPU Drivers** (`gpu-driver-version=default` node pool flag) | **GPU-optimized AMI** (`AL2023_x86_64_NVIDIA`) ships drivers + Helm **NVIDIA device plugin** (`k8s/eks/infra/nvidia-device-plugin-values.yaml`) | The EKS GPU AMI pre-bundles drivers, so only the device plugin is needed — no driver compilation as on AKS. |
| **A100-class GPU Machine Type** | `Standard_NC24ads_A100_v4` (24 vCPU, 220GB RAM, 1x A100 80GB) | `a2-ultragpu-1g` (12 vCPU, 170GB RAM, 1x A100 80GB) | `g6e.4xlarge` (16 vCPU, 128GB RAM, 1x **L40S 48GB**) | AWS has no single-A100 node (A100 only ships as 8-GPU `p4d`/`p4de`); L40S preserves the 1-GPU-per-pod model. |
| **T4 GPU Machine Type** | `Standard_NC16as_T4_v3` (16 vCPU, 64GB RAM, 1x T4 16GB) | `n1-standard-4` + `--accelerator type=nvidia-tesla-t4,count=1` | `g4dn.4xlarge` (16 vCPU, 64GB RAM, 1x T4 16GB) | Fixed GPU SKU on AKS/EKS vs modular accelerator attachment on GKE. |
| **GPU Node Selection** | `kubernetes.azure.com/agentpool` | `cloud.google.com/gke-nodepool` | `eks.amazonaws.com/nodegroup` | Cloud controller manager node labeling conventions. |
| **GPU Node Taints & Tolerations** | Custom taints: `sku=gpunpa100:NoSchedule` / `sku=gpunpt4:NoSchedule` | Standard GKE GPU taint: `nvidia.com/gpu=present:NoSchedule` | Manual taint at node-group creation: `nvidia.com/gpu=present:NoSchedule` | EKS does not auto-taint GPU nodes, so the taint is set explicitly on `create-nodegroup` (GKE-style scheme reused). |
| **Shared Storage Class (RWX)** | **Azure Blob CSI Driver**<br>`storageClassName: azureblob-fuse-premium` | **Google Cloud Filestore CSI Driver**<br>`storageClassName: standard-rwx` | **Amazon EFS CSI Driver**<br>`storageClassName: efs-sc` | EBS is RWO-only, so the shared model-weights volume must use EFS for `ReadWriteMany`. |
| **Internal Load Balancer** | `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` | `networking.gke.io/load-balancer-type: "Internal"` | `service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"` (+ `-type: external`, `-nlb-target-type: ip`) | Provider-specific cloud controller manager annotations for private IP provisioning. |
| **Enterprise Exposure & Gateway** | **Azure API Management (APIM)** in Internal VNet Mode with XML policies (`apim-policy.xml`) | **Google Cloud API Gateway** / **Cloud Armor** + Private Service Connect | **Amazon API Gateway** + VPC Link (PrivateLink) + usage plans/API keys + **AWS WAF** | Cloud-native API gateway, token validation (JWT), and rate-limiting at the network boundary. |

---

## 🔍 Deep-Dive Audit: Verification of GKE Implementation

### 1. Storage Provisioning (`pvc.yaml`)
* **AKS (`k8s/aks/infra/provisioning/pvc.yaml`)**:
  ```yaml
  storageClassName: azureblob-fuse-premium
  resources:
    requests:
      storage: 300Gi
  ```
* **GKE (`k8s/gke/infra/provisioning/pvc.yaml`)**:
  ```yaml
  storageClassName: standard-rwx
  resources:
    requests:
      storage: 1Ti
  ```
* **Audit Finding**: Correctly updated. GCP Filestore basic-hdd instances require a minimum capacity of 1Ti. The GKE PVC reflects this requirement while preserving `ReadWriteMany` (RWX) support.

### 2. Node Selection & GPU Tolerations (`deployment-vlm.yml` & `deployment-api.yml`)
* **AKS Target**: Uses `kubernetes.azure.com/agentpool: gpunpa100` and tolerates `sku=gpunpa100:NoSchedule`.
* **GKE Target**: Uses `cloud.google.com/gke-nodepool: gpunpa100` and tolerates GKE's default `nvidia.com/gpu=present:NoSchedule` taint.
* **Audit Finding**: Correctly updated. GKE worker pods schedule seamlessly onto tainted GPU node pools without scheduling deadlocks.

### 3. Service Exposure (`service.yml`)
* **AKS (`k8s/aks/networking/service.yml`)**:
  ```yaml
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
  ```
* **GKE (`k8s/gke/networking/service.yml`)**:
  ```yaml
  annotations:
    networking.gke.io/load-balancer-type: "Internal"
  ```
* **Audit Finding**: Correctly updated. Both services provision internal private IP addresses within their respective cloud virtual networks (VNet / VPC).

### 4. GPU Driver Management
* **AKS**: Requires declarative configuration of the NVIDIA GPU Operator via `k8s/aks/infra/gpu-operator-values.yaml` to handle kernel module compilation and driver loading on tainted nodes.
* **GKE**: Utilizes GKE's native managed driver installation (`gpu-driver-version=default`). The driver installer daemonsets are managed by Google Cloud, eliminating `gpu-operator-values.yaml` in the GKE manifests.

---

## 📁 Repository Manifest Mapping

```text
k8s/
├── aks/                         # Azure-Specific Manifest Overlays
│   ├── apps/
│   │   ├── deployment-api.yml   # AKS image tags & agentpool nodeSelectors
│   │   ├── deployment-vlm.yml   # AKS image tags & A100 agentpool nodeSelectors
│   │   ├── keda-scaler.yml      # KEDA autoscaling rules
│   │   └── redis-deployment.yml # Redis state store deployment
│   ├── infra/
│   │   ├── gpu-operator-values.yaml # NVIDIA GPU Operator tolerations for AKS
│   │   └── provisioning/
│   │       ├── ingest-job.yaml  # Model downloader job
│   │       └── pvc.yaml         # azureblob-fuse-premium PVC (300Gi)
│   ├── networking/
│   │   ├── apim-policy.xml      # Azure APIM JWT & rate-limit policies
│   │   └── service.yml          # Azure Internal Load Balancer service
│   └── kustomization.yml        # AKS Kustomize entrypoint
│
├── gke/                         # GCP-Specific Manifest Overlays
│   ├── apps/
│   │   ├── deployment-api.yml   # Artifact Registry tags & gke-nodepool selectors
│   │   ├── deployment-vlm.yml   # Artifact Registry tags & gke-nodepool selectors
│   │   ├── keda-scaler.yml      # KEDA autoscaling rules
│   │   └── redis-deployment.yml # Redis state store deployment
│   ├── infra/
│   │   └── provisioning/
│   │       ├── ingest-job.yaml  # Model downloader job
│   │       └── pvc.yaml         # standard-rwx Filestore PVC (1Ti)
│   ├── networking/
│   │   └── service.yml          # GKE Internal Load Balancer service
│   └── kustomization.yml        # GKE Kustomize entrypoint
│
└── eks/                         # AWS-Specific Manifest Overlays
    ├── apps/
    │   ├── deployment-api.yml   # ECR tags & eks-nodegroup selectors
    │   ├── deployment-vlm.yml   # ECR tags & L40S eks-nodegroup selectors
    │   ├── keda-scaler.yml      # KEDA autoscaling rules
    │   └── redis-deployment.yml # Redis state store deployment
    ├── infra/
    │   ├── efs-storageclass.yaml        # EFS CSI RWX StorageClass (efs-sc)
    │   ├── nvidia-device-plugin-values.yaml # NVIDIA device-plugin tolerations for EKS
    │   └── provisioning/
    │       ├── ingest-job.yaml  # Model downloader job
    │       └── pvc.yaml         # efs-sc EFS PVC (300Gi)
    ├── networking/
    │   └── service.yml          # AWS internal NLB service
    └── kustomization.yml        # EKS Kustomize entrypoint
```

---

## 📚 Deployment Guides Reference

* 📘 [Azure Kubernetes Service (AKS) Deployment Lifecycle](aks_deployment.md)
* 📗 [Google Kubernetes Engine (GKE) Deployment Lifecycle](gke_deployment.md)
* 📙 [Amazon Elastic Kubernetes Service (EKS) Deployment Lifecycle](eks_deployment.md)
