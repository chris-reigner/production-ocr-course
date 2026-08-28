# GPU Deployment on AWS (EKS)

This guide takes you from zero to a GPU-ready AWS account for the OCR pipeline.
Same **asymmetric hardware** idea as the Azure/GCP guides: cheap **T4** nodes for
orchestration and layout extraction, a premium single-GPU node for the heavy VLM
generation. Read this fully before spending money.

> **A note on GPUs:** unlike Azure and GCP, AWS does **not** offer a single-A100
> instance — the A100 only ships as the 8-GPU `p4d`/`p4de` nodes. To preserve the
> *one-GPU-per-pod* model this course uses, the vLLM inference tier runs on
> **`g6e.4xlarge`** (1× NVIDIA **L40S 48GB**) instead. See
> [`cloud_comparison.md`](cloud_comparison.md) for the full instance mapping.

> Unlike `az aks create` / `gcloud container clusters create`, raw `aws eks`
> makes you bring your own **IAM roles**, **VPC/subnets**, **OIDC provider**, and
> storage/networking add-ons. This doc covers the account-level prerequisites
> (tooling, quota, permissions, capacity); the cluster itself is built in
> [`eks_deployment.md`](eks_deployment.md).

---

## 1. Target instance types (SKUs)

The full stack uses five EC2 instance types across five managed node groups.
Only the two GPU groups need special quota; the CPU groups run on standard
families.

| Role | Node group | Instance type | GPU | vCPUs | RAM |
|------|-----------|---------------|-----|-------|-----|
| VLM inference (vLLM) | `gpunpa100` | `g6e.4xlarge` | 1× NVIDIA **L40S 48GB** | 16 | 128 GiB |
| Layout worker (PP-DocLayout) | `gpunpt4` | `g4dn.4xlarge` | 1× NVIDIA **T4 16GB** | 16 | 64 GiB |
| Redis state store | `redisnp` | `r6i.xlarge` | — | 4 | 32 GiB |
| API gateway (Rust producer) | `apinp` | `m6i.large` | — | 2 | 8 GiB |
| Cluster add-ons (untainted) | `systemnp` | `m6i.large` | — | 2 | 8 GiB |

> Both GPU groups use the EKS **GPU-optimized AMI** (`AL2023_x86_64_NVIDIA`),
> which pre-ships the NVIDIA drivers + container toolkit — so on EKS you only
> install the **NVIDIA device plugin**, not the full GPU Operator that AKS needs.

---

## 2. Quota to request (per region)

AWS measures EC2 On-Demand quota in **vCPUs per instance-family group**, not GPU
count — the same model as Azure, but the families are grouped differently.
**All G-series GPU instances share one quota bucket**, and the CPU instances
share another. On a brand-new account the GPU bucket is often **0**.

| Service Quota (EC2) | Quota code | Request | Why |
|---------------------|-----------|---------|-----|
| **Running On-Demand G and VT instances** | `L-DB2E81BA` | **128** vCPU | Covers *both* GPU groups: `g6e.4xlarge` (4 × 16 = 64) + `g4dn.4xlarge` (4 × 16 = 64). Matches the `maxSize=4` on each GPU node group. |
| **Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances** | `L-1216C47A` | **32** vCPU | Covers the CPU groups: `m6i.large` api (5 × 2 = 10) + `m6i.large` system (2 × 2 = 4) + `r6i.xlarge` redis (3 × 4 = 12) = 26, rounded up for headroom. |
| **Running On-Demand P instances** | `L-417A185B` | *(optional)* | Only if you swap the inference tier to a real A100 (`p4d`/`p4de`, 8-GPU). **Not needed** for the default L40S build. |

> ⚠️ **`g6e` and `g4dn` both count against the single `G and VT` bucket.** You do
> not request them separately — request the *combined* vCPU total. If you only
> ever run one GPU group at a time you can request less, but 128 covers the full
> `maxSize=4 + maxSize=4` scale-out.

**Check current limits (CLI):**
```bash
export AWS_REGION="eu-central-1"

aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-DB2E81BA --region $AWS_REGION \
  --query 'Quota.{Name:QuotaName,Value:Value}' --output table   # G and VT
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-1216C47A --region $AWS_REGION \
  --query 'Quota.{Name:QuotaName,Value:Value}' --output table   # Standard
```

---

## 3. Install the required tooling

Everything `eks_deployment.md` invokes must be on your PATH. This is a superset
of the Azure/GCP tooling because raw EKS drives more moving parts.

| Tool | Used for | Notes |
|------|----------|-------|
| **AWS CLI v2** | all `aws …` commands | `aws sts get-caller-identity` must succeed |
| **kubectl** | applying manifests | match your cluster's minor (`K8S_VERSION=1.31`) |
| **helm v3** | NVIDIA device plugin, KEDA, kube-prometheus-stack, AWS LB Controller | |
| **kustomize** (standalone) | `deploy.sh` runs `kustomize edit set image` | the bundled `kubectl -k` is **not** enough — install the standalone CLI |

**macOS (Homebrew)**
```bash
brew update
brew install awscli kubectl helm kustomize
```

**Linux (Debian/Ubuntu)**
```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
# kubectl, helm, kustomize
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/kubectl
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
```

**Authenticate and confirm the account/region:**
```bash
export AWS_PROFILE=<your-profile>   # or run: aws configure
export AWS_REGION="eu-central-1"
aws sts get-caller-identity --output table
```
> Expected: the `Account` field is the account you intend to deploy into and the
> caller ARN is the IAM principal you'll use for the rest of the guide.

> On an **Apple-Silicon Mac**, `docker buildx` cross-builds the `linux/amd64`
> images under QEMU emulation and is slow for the CUDA-heavy `ocr-vlm-qwen` /
> `ocr-worker-rt` images. If that's a wall, skip Docker entirely and use the
> **AWS CodeBuild** path (Option 2 in `eks_deployment.md` §3), which builds on
> native amd64 agents in the cloud.

---

## 4. AWS account & IAM prerequisites

- **Account**: non-free-tier with fully activated billing (new accounts can take
  a few hours to activate for GPU launches) and billing alerts on (see §8).
- **Principal**: the deploying IAM user/role needs create/manage rights across
  **IAM** (roles, policies, OIDC provider, `PassRole`), **EKS**, **EC2/VPC**,
  **CloudFormation**, **EFS**, **ECR**, **CodeBuild + S3**, **ELBv2**,
  **API Gateway v2**, **Cognito**, **WAFv2**, and **CloudWatch Logs** — the guide
  creates a resource in each. Account admins already have this.

> The IAM roles this stack uses (`eksOcrClusterRole`, `eksOcrNodeRole`, plus the
> EFS-CSI and LB-controller IRSA roles) are created *inside* `eks_deployment.md`
> — you just need permission to create them.

### GPU access

New accounts often start at **0** vCPU in the `G and VT` bucket, and GPU
increases are rarely auto-approved — AWS usually opens a **support case** (this
is normal). Request it in the console (*Service Quotas → EC2*, region
`eu-central-1`) or via CLI:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-DB2E81BA \
  --desired-value 128 --region $AWS_REGION      # G and VT (GPU)
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-1216C47A \
  --desired-value 32 --region $AWS_REGION        # Standard (CPU)
```

> Submit the GPU (G/VT) and CPU (Standard) buckets as **separate cases** — the
> Standard one usually clears instantly, the GPU one can take hours to a day. If
> asked to justify: *event-driven OCR/VLM inference on EKS; `g6e.4xlarge` (L40S)
> for vLLM and `g4dn.4xlarge` (T4) for layout, autoscaling with scale-to-zero.*

---

## 5. Choose a region and verify availability

GPU quota and capacity are **per region** — pick one (`eu-central-1` here) and
stick to it.

**Confirm both GPU instance types are offered to your account, and in which AZs:**
```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=g6e.4xlarge,g4dn.4xlarge \
  --region $AWS_REGION \
  --query "InstanceTypeOfferings[].{Type:InstanceType,AZ:Location}" --output table
```

> **Quota ≠ capacity.** An instance type appearing here means it's *offered* in
> that AZ — it does not read live inventory. `g6e.4xlarge` is capacity-constrained
> in some `eu-central-1` AZs (we hit `InsufficientInstanceCapacity` in
> `eu-central-1b`); note which AZs list it so you can pin the GPU node group's
> subnet later if a launch fails. Also note the AZs so your **EFS mount targets**
> (created in `eks_deployment.md` §2) cover every AZ a GPU pod can land in.

---

## 6. Smoke test: launch one GPU instance, confirm it boots, then terminate

The only sure test of GPU capacity is to launch a single node. **GPU instances
bill by the second — terminate the moment the test passes.**

```bash
export AWS_REGION="eu-central-1"
# Latest Amazon Linux 2023 AMI (swap for a Deep Learning AMI if you want to run nvidia-smi)
AMI_ID=$(aws ssm get-parameter --region $AWS_REGION \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

# Launch one L40S node (swap Values to g4dn.4xlarge to test the T4 instead)
INSTANCE_ID=$(aws ec2 run-instances --region $AWS_REGION \
  --image-id $AMI_ID --instance-type g6e.4xlarge --count 1 \
  --query 'Instances[0].InstanceId' --output text)
echo "Launched $INSTANCE_ID"

aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $AWS_REGION
echo "GPU instance is RUNNING — capacity is real."

# TERMINATE IMMEDIATELY
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $AWS_REGION
```

- Instance reaches `running` → capacity is real; proceed.
- `InsufficientInstanceCapacity` / `Unsupported` → no free GPU in that AZ right
  now; try another AZ/subnet or region. Not your fault.
- `VcpuLimitExceeded` → the quota from §4.3 isn't approved yet — different
  problem from capacity.

---

## 7. Capacity-proof cluster (disposable — not the real deployment)

The instance smoke test in §6 proves the *SKU* boots. This step proves one level
up: that **EKS itself** can schedule GPU pods onto both GPU types via managed
node groups and the device plugin, before you invest time in the full build.
**This cluster is throwaway — delete it at the end of this section.** The real
production cluster (IAM roles, VPC, EFS ingestion, Redis, KEDA, the API gateway,
the works) is built fresh in [`eks_deployment.md`](eks_deployment.md) and does
**not** reuse anything created here.

The fastest disposable path is `eksctl` (it provisions the VPC, IAM, and OIDC in
one command — the exact plumbing you'll do by hand in the real build):

```bash
export AWS_REGION="eu-central-1"
CLUSTER=ocr-smoketest-eks

# Base cluster (no GPU) — control plane + a small system pool
eksctl create cluster --name $CLUSTER --region $AWS_REGION \
  --version 1.31 --nodegroup-name systemnp \
  --node-type m6i.large --nodes 1 --managed

# L40S inference pool (scale-to-zero), GPU AMI + GPU taint
eksctl create nodegroup --cluster $CLUSTER --region $AWS_REGION \
  --name gpunpa100 --node-type g6e.4xlarge \
  --node-ami-family AmazonLinux2023 \
  --nodes-min 0 --nodes 1 --nodes-max 4 --managed \
  --node-taints nvidia.com/gpu=present:NoSchedule

# T4 layout pool (scale-to-zero)
eksctl create nodegroup --cluster $CLUSTER --region $AWS_REGION \
  --name gpunpt4 --node-type g4dn.4xlarge \
  --node-ami-family AmazonLinux2023 \
  --nodes-min 0 --nodes 1 --nodes-max 4 --managed \
  --node-taints nvidia.com/gpu=present:NoSchedule

# Advertise nvidia.com/gpu to the scheduler
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin && helm repo update
helm install nvidia-device-plugin nvdp/nvidia-device-plugin -n kube-system \
  --set-string tolerations[0].key=nvidia.com/gpu \
  --set-string tolerations[0].operator=Exists \
  --set-string tolerations[0].effect=NoSchedule

kubectl get nodes -L eks.amazonaws.com/nodegroup
```

Schedule a pod that tolerates `nvidia.com/gpu=present:NoSchedule` and requests
`nvidia.com/gpu: 1` onto each pool to confirm both GPU types accept work.

> Both GPU pools scale to 4 (`--nodes-max 4`), matching the 128-vCPU `G and VT`
> quota from §2. Keep `--nodes-min 0` so idle GPUs cost nothing.

Once `kubectl get nodes` shows both GPU pools scheduling correctly, **tear the
whole thing down** — this cluster has done its job:

```bash
eksctl delete cluster --name $CLUSTER --region $AWS_REGION --disable-nodegroup-eviction
```

> If you built the smoke test by hand with `aws eks` instead of `eksctl`, also
> delete the VPC CloudFormation stack, the EFS filesystem, and any IAM roles you
> created so they don't collide with the real build.

---

## 8. Cost safety (before your first GPU boots)

- Set a **Budget + alerts**: *AWS Billing → Budgets* → thresholds at 50/80/100 %.
- Keep **scale-to-zero** (`minSize=0`) on both GPU node groups — GPU nodes
  dominate the cost of this stack.
- Delete the §6 smoke-test instance and the §7 smoke-test cluster the moment
  they've served their purpose.
- For interruptible batch OCR, consider **EC2 Spot** capacity on the GPU node
  groups (`--capacity-type SPOT` on `create-nodegroup`) — much cheaper, but
  reclaimed with a 2-minute warning, so only for checkpoint-safe work.
