# Feature Comments & Security Findings

Running log of review comments, known issues, and remediation plans that are
intentionally *not* fixed in code yet (so the decision and rationale are not lost).

---

## SEC-001 — TLS verification disabled in the model-ingest Job

- **Severity:** HIGH
- **Status:** Acknowledged — intentionally left as-is (see Decision)
- **Date raised:** 2026-08-10
- **Source:** Automated security review (security-guidance plugin)

### Affected files
The same pattern exists in all three cloud overlays (identical copies):
- `k8s/eks/infra/provisioning/ingest-job.yaml`
- `k8s/gke/infra/provisioning/ingest-job.yaml`
- `k8s/aks/infra/provisioning/ingest-job.yaml`

### The finding
The in-cluster model-ingestion Job builds a deliberately insecure SSL context
before downloading model weights from Hugging Face:

```python
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
...
with urllib.request.urlopen(req, context=ctx) as response:
    ...
with urllib.request.urlopen(file_req, context=ctx) as r, open(local_path, "wb") as f:
    ...
```

Setting `check_hostname = False` and `verify_mode = ssl.CERT_NONE` disables both
certificate-chain validation and hostname verification for every HTTPS request
the Job makes.

### Why it matters
- **Man-in-the-middle (MITM) risk.** With verification off, the Job will accept
  *any* TLS certificate — including one presented by an attacker on the network
  path — and download whatever content is returned.
- **Supply-chain impact.** The downloaded artifacts are model weights
  (`.safetensors`) that are subsequently loaded and executed by the vLLM server
  and the layout worker. Tampered weights = arbitrary/poisoned model behavior in
  the inference path.
- **No legitimate need.** `huggingface.co` serves valid, publicly-trusted TLS
  certificates. The default verified context works out of the box; the insecure
  override provides no functional benefit.

### Remediation plan
When we decide to fix (repo-wide, to keep the three overlays consistent):

1. **Preferred — drop the custom context entirely.** Remove the three
   `ctx` lines and the `context=ctx` argument from both `urlopen` calls; let
   `urllib` use its default *verified* context.

2. **Minimal — keep the variable but stop disabling checks.** Replace the block
   with:
   ```python
   ctx = ssl.create_default_context()  # verifies cert chain and hostname by default
   ```

3. **If a corporate CA / proxy is genuinely required**, do *not* disable
   verification — add the CA instead:
   ```python
   ctx = ssl.create_default_context()
   ctx.load_verify_locations(cafile="/etc/ssl/corp-ca.pem")
   ```

Apply the same change to all three files (`eks`, `gke`, `aks`) in one pass so the
ingest Jobs stay identical across clouds.



### Infrastructure provisioning

EKS requires you to provision your infrastructure as opposed to AKS/GKE


### Slim the worker image (`ocr-worker-rt` ~22 GB → ~4–5 GB)

Root cause: CUDA is shipped twice. The `nvidia/cuda:12.1.1-cudnn8-devel` base
carries the full dev toolkit (~6.4 GB) + static `.a` libs (3.7 GB), while
`torch` pip wheels bundle their own CUDA runtime (2.9 GB) and use *that*.

Actions (biggest win first):

1. **Drop the devel base.** `FROM python:3.10-slim` — torch wheels supply CUDA
   at runtime; the host driver comes from the GPU node + device plugin.
   → removes ~9 GB (base toolkit + static libs).
2. **Or conservative:** `nvidia/cuda:12.1.1-cudnn8-runtime` instead of `-devel`
   → removes ~6 GB.
3. **Multi-stage** if anything needs `nvcc` to compile: build in `-devel`, copy
   only `dist-packages` + app into a slim/runtime final stage.
4. **If keeping devel:** `RUN find / -name '*.a' -delete` → reclaims 3.7 GB.

Reachable size estimate (slim base): torch 0.9 GB + triton 0.65 GB + nvidia
wheels 2.9 GB + libs/app ~0.4 GB ≈ **~4–5 GB**. Apply the same base change to
`./server` and `./client_rt_producer`.

#### Squash vs multi-stage

`docker images` counts every layer, including files written then deleted/replaced
in a later layer (those bytes stay in the lower layer). For `ocr-vlm-qwen` this is
~14 GB of cruft (34.9 GB reported vs ~21 GB merged content).

- **Multi-stage — preferred, use where we own the layers (`ocr-worker-rt`).**
  Build in a `-devel` stage, `COPY --from=` only `dist-packages` + app into a
  slim/runtime final stage. The cruft never enters the final image, and base-layer
  caching/sharing is preserved. Risk: a missed runtime path fails at run time → test.
- **Squash — last resort, only where the base is vendored (`ocr-vlm-qwen`,**
  **`vllm/vllm-openai`).** Flatten to a single layer (`docker-squash`, or
  `docker export | docker import`); reclaims the ~14 GB on node disk. Cost: loses
  layer caching + base-layer sharing across pulls, and the *compressed* pull stays
  ~11 GB regardless — so often not worth it.

Rule: multi-stage when we build the layers, squash only when we can't.

### Building in the cloud: ACR (build + registry) vs ECR (registry only)

A key asymmetry between Azure and AWS shows up in the "build the images" step:

- **Azure ACR does both build *and* registry.** `az acr build --registry $ACR_NAME
  --image ocr-vlm-qwen:latest ./server` uploads the build context and runs the
  `docker build` **on Azure** (ACR Tasks), on native amd64 agents, then stores the
  result — one command, one service, nothing builds on your laptop.

- **AWS ECR is a registry *only*.** There is no `aws ecr build`. ECR only stores
  and serves images; you must produce the image somewhere else and `docker push`
  it. The build-in-the-cloud equivalent is a **separate service, AWS CodeBuild**
  (managed amd64 build agents, `privilegedMode` for Docker-in-Docker, pushes to
  ECR). See [`eks_deployment.md`](eks_deployment.md) Section 3, Option 2, plus
  `buildspec.yml` and `k8s/eks/codebuild-setup.sh`.

Why this matters here: on an Apple-Silicon Mac the local `docker build` defaults
to `arm64` and won't run on the x86_64 EKS GPU nodes — you'd have to cross-build
under QEMU (slow). CodeBuild sidesteps both problems (native amd64, off your
machine), which is what makes it the true `az acr build` analogue on AWS.
Alternatives if you don't want a CodeBuild project: remote `buildx` against an
amd64 EC2 builder, or Docker Build Cloud.

### Terraform for AWS infra — cloud only, k8s kept separate (Option A)

- **Status:** Planned — not implemented
- **Date raised:** 2026-08-14
- **Goal:** Make AWS infra reproducible and cleanly destroyable (full resource
  removal, not just scale-to-zero). The manual EKS path (VPC/subnets/API
  Gateway/EKS/CodeBuild) is far less straightforward than AKS/GKE.

**Chosen approach: keep Terraform and the Kubernetes deployment separate.**
Terraform owns only the AWS/cloud layer. The existing `k8s/eks/` kustomize + Helm
flow (`deploy.sh` / `kubectl` / `helm`) stays exactly as-is; Terraform never learns
about pods, charts, PVCs, or ScaledObjects. The two layers talk **one way only**:
Terraform *outputs* feed the k8s layer (cluster name for `update-kubeconfig`, EFS id
for the StorageClass, ECR URLs for the kustomize `images:` block). Nothing flows back.

#### Ownership split

| Terraform owns (cloud) | Stays in k8s (kubectl/helm), untouched by TF |
|---|---|
| VPC, subnets, NAT/IGW, SG rules (incl. NFS 2049 → cluster SG) | kube-prometheus-stack, KEDA, DCGM, NVIDIA device plugin |
| EKS control plane + 5 node groups (`systemnp`, `gpunpa100`, `gpunpt4`, `redisnp`, `apinp`) + OIDC | StorageClass, PVC, ingestion Job |
| IAM roles/policies, EFS-CSI IRSA | app kustomize (api / vlm / worker / redis) |
| EFS filesystem + mount targets | `ocr-api-service` (LoadBalancer → NLB) |
| ECR (3 repos), CodeBuild + GitHub creds | KEDA ScaledObjects |
| API Gateway v2 + VPC link + Cognito | — |

#### Suggested layout

```
infra/                # Terraform — cloud only
  vpc.tf eks.tf ecr.tf efs.tf iam.tf codebuild.tf apigw.tf cognito.tf
  outputs.tf          # cluster name, OIDC, subnet/SG ids, EFS id, ECR urls
  backend.tf          # S3 + DynamoDB remote state
k8s/eks/              # unchanged — current deploy path
```

Use the official `terraform-aws-modules/{vpc,eks}` modules — they encode the subnet
tagging, OIDC/IRSA, and node-group wiring that made the manual path painful.

#### Destroy story (the main cost of keeping the layers separate)

Because k8s creates AWS resources **outside** Terraform state, `terraform destroy`
alone will hang. Teardown is a two-phase handshake, **k8s first**:

```bash
# Phase 1 — remove what k8s created in AWS (do NOT skip)
kubectl delete svc ocr-api-service     # deletes the NLB + its ENIs/SGs
kubectl delete pvc --all -n <ns>       # releases dynamically-provisioned EBS
# wait until the NLB is actually gone (elbv2 describe-load-balancers returns empty)

# Phase 2 — VPC is now unblocked
terraform destroy
```

Bake Phase 1 into a `teardown.sh` (or a TF `null_resource` with a destroy-time
`local-exec` that runs the `kubectl delete` before the VPC is removed). The
orphaned-NLB-blocks-subnet-deletion trap is *the* failure mode here; everything else
destroys cleanly. On the TF side also set the destroy-enablers: ECR
`force_delete = true`, Cognito deletion-protection off, and put the EKS/CloudWatch
log groups + OIDC provider in state so they go too.

#### Stateful data to protect

The only stateful volume is the **model-weights EFS** (populated by the ingestion
Job, backing `model-weights-pvc`). Guard it with `lifecycle { prevent_destroy = true }`
(or snapshot before a full wipe) so a routine teardown removes compute + edge but
never the weights. Redis is in-cluster and ephemeral — no special handling. (There is
no Langfuse in this project.)

Net trade-off: "clean up everything" becomes `kubectl delete svc/pvc` →
`terraform destroy` rather than a single command — the accepted price of keeping the
k8s deployment independent of Terraform.

### TODO

- Pre-requisites for AWS EKS
- Add cloud formation/terraform for AWS infrastructure (to easily create and destroy)
- OIDC connector ? 
- The VPC template is amazon-eks-vpc-private-subnets.yaml, and its SubnetIds output includes both public and private subnets. GPU worker nodes should sit in the private subnets only (no public IPs on your expensive L40S/T4 boxes)
- Add pre-requisites for helm and different CLIs
- is nvidia-device-plugin really necessary ? compared to what I had before ? 
- remove model from docker images (32GB is too big) and find a way to store it on S3/EFS under the VPC
- add usage of T4 GPU almost 0% usage so possible to switch to a CPU?