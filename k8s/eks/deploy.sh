#!/usr/bin/env bash
# Deploy the EKS OCR stack, injecting the ECR registry from the caller's AWS
# account so no account ID is ever committed. Requires the `kustomize` CLI
# (for `kustomize edit`), `kubectl`, and an authenticated AWS session.
set -euo pipefail

: "${AWS_REGION:=eu-central-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

cd "$(dirname "$0")"

# Restore the committed PLACEHOLDER on exit so the account ID never lands in git.
trap 'git checkout -- kustomization.yml 2>/dev/null || true' EXIT

kustomize edit set image \
  "ocr-api-rust=${REGISTRY}/ocr-api-rust:latest" \
  "ocr-worker-rt=${REGISTRY}/ocr-worker-rt:latest" \
  "ocr-vlm-qwen=${REGISTRY}/ocr-vlm-qwen:latest"

kubectl apply -k .
