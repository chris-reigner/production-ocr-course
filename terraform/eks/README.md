# Terraform — EKS OCR infrastructure

Provisions the **AWS infrastructure** for the OCR pipeline in one `terraform
apply`, and tears it all down with one `terraform destroy`. This replaces the
imperative `aws ...` commands in [`docs/eks_deployment.md`](../../docs/eks_deployment.md)
§1–§3 with a single dependency-ordered state.

> **Why Terraform for this:** raw EKS makes you create IAM roles, a VPC, an OIDC
> provider, node groups, EFS, and add-ons in a specific order. Terraform builds
> its own dependency graph from the resource references, so **you don't sequence
> anything by hand** — and `destroy` walks the graph in reverse, so nothing is
> orphaned.

## What this module owns (AWS infra only)

| Area | Resources | Guide section |
|------|-----------|---------------|
| Networking | VPC, 2× public + 2× private subnets, IGW, NAT gateway, route tables (DNS hostnames on) | §1.2 |
| IAM | `eksOcrClusterRole`, `eksOcrNodeRole` (3 managed policies + scoped EFS-describe inline), `eksOcrEfsCsiRole` (IRSA) | §1.1, §2.1 |
| Control plane | EKS cluster (`v1.31`) + IAM OIDC provider | §1.3, §1.4 |
| Compute | 5 managed node groups: `systemnp`, `gpunpa100`, `gpunpt4`, `redisnp`, `apinp` | §1.5 |
| Storage | EFS filesystem, per-AZ mount targets, NFS security group, EFS CSI addon | §2.1 |
| Registry | 3 ECR repositories | §3 |

## What stays manual (out of scope by design)

These are Kubernetes-layer / build / perimeter steps — run them **after**
`terraform apply`, following the deployment guide:

1. `aws eks update-kubeconfig ...` — see the `update_kubeconfig_command` output.
2. NVIDIA device plugin, KEDA, kube-prometheus-stack, AWS Load Balancer Controller (Helm) — guide §1.5, §4, §6.
3. EFS StorageClass + PVC — see the `apply_storageclass_command` output (injects the EFS ID), then the ingest Job — guide §2.
4. Build & push images to the ECR repos — guide §3.
5. Deploy the app stack (`./k8s/eks/deploy.sh`) and monitoring — guide §4, §5.
6. API Gateway + VPC Link + Cognito + WAF perimeter — guide §6.

> The AWS LB Controller IRSA role it needs later can reuse the
> `oidc_provider_arn` output.

## Usage

```bash
cd terraform/eks
export AWS_PROFILE=<your-profile>   # or configure credentials however you prefer

terraform init
terraform plan        # review — expect ~40 resources
terraform apply       # ~15 min (EKS control plane + node groups dominate)

# Point kubectl at the cluster (value is also printed as an output)
$(terraform output -raw update_kubeconfig_command)
```

Tear everything down when you're done (GPU nodes are the expensive part):

```bash
terraform destroy
```

## State

Uses **local state** (`terraform.tfstate` in this directory). It's git-ignored.
Back it up if the cluster matters — losing it means Terraform no longer tracks
the infra. To move to remote state later, add an S3 `backend` block and
`terraform init -migrate-state`.

## Notes & caveats

- **`desired_size` drift:** node group `desired_size` is under `ignore_changes`
  so KEDA / scale-to-zero adjustments don't fight the next `apply`. Change
  `min_size`/`max_size` here; leave live scaling to KEDA.
- **GPU capacity:** `g6e.4xlarge` is capacity-constrained in some `eu-central-1`
  AZs. All node groups currently span both private subnets. If a GPU group fails
  with `InsufficientInstanceCapacity`, pin its `subnet_ids` to the AZ that has
  capacity (edit `nodegroups.tf`).
- **GPU node group naming:** `gpunpa100` runs an **L40S**, not an A100 — the name
  is kept for parity with the AKS/GKE guides and the app `nodeSelector`s.
- **`bootstrap_cluster_creator_admin_permissions`:** the IAM principal that runs
  `apply` is granted cluster-admin, so `kubectl` works immediately. Other
  principals need an EKS access entry / aws-auth mapping.
- **CodeBuild** (guide §3 Option 2) is intentionally not managed here — it's a
  build-time concern with its own `k8s/eks/codebuild-setup.sh` script.

### Security hardening (applied by this module)

- **IMDSv2 + hop limit 1:** node launch templates (`nodegroups.tf`) require
  IMDSv2 (`http_tokens = required`) and set the response hop limit to 1, so a
  compromised pod on the pod network can't reach IMDS to steal node-role
  credentials. App pods don't need node-role creds; the AWS LB Controller is
  already passed `region`/`vpcId` explicitly (guide §6) precisely because it
  can't read IMDS.
- **Encrypted root volumes:** the same launch templates set `encrypted = true`
  on the gp3 root volume, independent of the account-level EBS default.
- **ECR tags are MUTABLE:** repositories use `image_tag_mutability = "MUTABLE"`
  because the build workflow (CodeBuild / local buildx) and the `k8s/eks/*`
  manifests reference a floating `:latest` tag, which must be overwritable.
  Immutable tags would reject the second `:latest` push. If you move to unique
  tags (git SHA / version) end-to-end, flip this to `IMMUTABLE` so a pushed
  digest can't silently change under a running deployment.
- **Node-role EFS perms scoped:** the node role gets only
  `elasticfilesystem:DescribeMountTargets` (inline), not the broad
  `AmazonElasticFileSystemClientReadWriteAccess` managed policy. Mount I/O is
  authorized by the EFS CSI driver's IRSA role.
- **EFS TLS enforced:** an EFS file-system policy denies any access where
  `aws:SecureTransport` is false. The `efs-sc` StorageClass
  (`k8s/eks/infra/efs-storageclass.yaml`) sets `mountOptions: [tls]` so
  CSI-provisioned mounts comply — keep that option if you edit the StorageClass.
