#!/usr/bin/env bash
# Package the repo working tree into a zip and upload it to the S3 source bucket
# that CodeBuild pulls from (SOURCE_TYPE=S3). Run this before each build so the
# cloud build sees your latest code.
#
# We zip the WORKING TREE (not `git archive HEAD`) on purpose: buildspec.yml and
# these scripts may still be uncommitted, and the build needs buildspec.yml at
# the archive root plus the three build contexts.
#
#   ./k8s/eks/codebuild-upload-source.sh
#   S3_BUCKET=my-bucket S3_KEY=ocr-source.zip ./k8s/eks/codebuild-upload-source.sh
set -euo pipefail

: "${AWS_REGION:=eu-central-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
: "${S3_BUCKET:=ocr-codebuild-src-${ACCOUNT_ID}}"
: "${S3_KEY:=ocr-source.zip}"

# Repo root = two levels up from this script (k8s/eks/).
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

ZIP=/tmp/ocr-source.zip
rm -f "$ZIP"

# Exclude VCS, IDE, local build artifacts, caches, and secrets. -x patterns are
# matched against the paths as stored (relative to repo root).
zip -r -q "$ZIP" . \
  -x '.git/*' \
  -x '.idea/*' \
  -x '*/target/*' \
  -x '*/__pycache__/*' \
  -x '*.pyc' \
  -x '.venv/*' \
  -x '*/.venv/*' \
  -x 'node_modules/*' \
  -x '*.env' \
  -x '.env'

echo "Packaged $(du -h "$ZIP" | cut -f1) → s3://${S3_BUCKET}/${S3_KEY}"
aws s3 cp "$ZIP" "s3://${S3_BUCKET}/${S3_KEY}" --region "$AWS_REGION"
echo "Uploaded. Launch a build:"
echo "  aws codebuild start-build --project-name ocr-image-build --region ${AWS_REGION} --query 'build.id' --output text"
