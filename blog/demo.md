# OCR Autoscaling Demo Runbook

## Prework

### 1. Stop KEDA rules

```bash
kubectl annotate scaledobject ocr-vlm-scaler       autoscaling.keda.sh/paused-replicas="0" --overwrite
kubectl annotate scaledobject ocr-worker-rt-scaler autoscaling.keda.sh/paused-replicas="0" --overwrite
```

kubectl annotate scaledobject ocr-vlm-scaler       autoscaling.keda.sh/paused-replicas="1" --overwrite
kubectl annotate scaledobject ocr-worker-rt-scaler autoscaling.keda.sh/paused-replicas="1" --overwrite


> Revert (set KEDA rules back):
>
> ```bash
> kubectl annotate scaledobject ocr-vlm-scaler ocr-worker-rt-scaler autoscaling.keda.sh/paused-replicas-
> ```

### 3. Get auth token

```bash
TOKEN=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \
    --client-id "$JWT_AUDIENCE" \
    --auth-parameters USERNAME=api-user,PASSWORD='ChangeMe!2026' \
    --query 'AuthenticationResult.IdToken' --output text)
```

---

## Demo

### 1. Show architecture

_(walk through the architecture diagram)_

### 2. Show pod status

```bash
kubectl get pods -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,START:.status.startTime'
```

### 3. Scale to 1 and wait for deploy

```bash
kubectl annotate scaledobject ocr-vlm-scaler       autoscaling.keda.sh/paused-replicas="1" --overwrite
kubectl annotate scaledobject ocr-worker-rt-scaler autoscaling.keda.sh/paused-replicas="1" --overwrite
```

Wait until 1 vLLM + 1 worker pod are Running and GPU nodes are up.

### 4. Tail the engines

Consumer Worker (Layout Engine on T4 GPU - gpunpt4):

```bash
kubectl logs -l app=ocr-worker-rt --tail=100 -f
```

vLLM Server (Inference Engine on L40S GPU - gpunpa100):

```bash
kubectl logs -l app=ocr-vlm --tail=100 -f
```

Redis:

```bash
kubectl exec -it deploy/ocr-redis -- redis-cli MONITOR
```

### 5. Show status again

```bash
kubectl get pods -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,START:.status.startTime'
```

### 6. Prove the API is live (0:30)

```bash
curl -sX POST "https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/ocr/process" \
    -H "Authorization: Bearer $TOKEN" -F "file=@seldon-technical-report.pdf"
```

Point at P2: `ocr_tasks` blips 0→1→0; worker picks it up; vLLM `num_requests_waiting` ticks. Clean, traceable path.

### 7. Burst / concurrency (1:30) — the money shot

Fire N in parallel:

```bash
seq 1 20 | xargs -P 20 -I{} curl -sX POST \
    "https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/ocr/process" \
    -H "Authorization: Bearer $TOKEN" -F "file=@seldon-technical-report.pdf" >/dev/null &
```

- **P2**: Redis `ocr_tasks` spikes → queue absorbs the burst (nothing dropped).
- **P1**: worker pods scale 1→N (1-per-task), each landing on T4 GPU nodes as they come up.
- **P2**: vLLM HPA climbs as `num_requests_waiting` rises → new L40S pods.
- **P3**: GPU utilization jumps across multiple GPUs = real parallel throughput.

One-liner to make queuing explicit on screen:

```bash
watch -n1 'kubectl exec deploy/ocr-redis-deployment -- redis-cli llen ocr_tasks'
```

### 8. Drain (2:30)

Stop sending; queue empties, workers finish in parallel, pods settle back. "Elastic down as well as up."

### 9. Scale to zero (3:00) — cost story

```bash
kubectl annotate scaledobject ocr-vlm-scaler       autoscaling.keda.sh/paused-replicas="0" --overwrite
kubectl annotate scaledobject ocr-worker-rt-scaler autoscaling.keda.sh/paused-replicas="0" --overwrite
```
