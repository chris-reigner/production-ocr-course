#!/usr/bin/env bash
# One-time setup: create the IAM service role + AWS CodeBuild project that builds
# the three OCR images on native amd64 agents and pushes them to ECR. This is the
# AWS equivalent of `az acr build` (ECR itself has no build service).
#
# Run this ONCE in your EKS account. Two source options:
#
#   SOURCE_TYPE=GITHUB (default) — build from the GitHub repo. Requires your
#     GitHub account to be connected to CodeBuild first (Console → Developer
#     Tools → Settings → Connections, or `aws codebuild import-source-credentials
#     --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN --token <PAT>`).
#
#   SOURCE_TYPE=S3 — no GitHub / OAuth needed. The build pulls a zip of the repo
#     from an S3 bucket. This script creates the bucket + grants the role read
#     access; upload the source with k8s/eks/codebuild-upload-source.sh before
#     each build. NO_SOURCE is NOT an option — the build needs the repo contents
#     (the three build contexts + buildspec.yml).
#
#   SOURCE_TYPE=GITHUB ./k8s/eks/codebuild-setup.sh
#   SOURCE_TYPE=S3     ./k8s/eks/codebuild-setup.sh
set -euo pipefail

: "${AWS_REGION:=eu-central-1}"
: "${PROJECT_NAME:=ocr-image-build}"
: "${SOURCE_TYPE:=GITHUB}"       # GITHUB | S3
: "${GITHUB_REPO:=https://github.com/chris-reigner/production-ocr-course.git}"
: "${SOURCE_BRANCH:=feat/aws}"
: "${ROLE_NAME:=codeBuildOcrImageRole}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
: "${S3_BUCKET:=ocr-codebuild-src-${ACCOUNT_ID}}"
: "${S3_KEY:=ocr-source.zip}"

echo "Account: ${ACCOUNT_ID}  Region: ${AWS_REGION}  Project: ${PROJECT_NAME}  Source: ${SOURCE_TYPE}"

# --- 1. IAM service role trusted by CodeBuild ---
cat > /tmp/codebuild-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "codebuild.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/codebuild-trust.json >/dev/null 2>&1 \
  || echo "Role ${ROLE_NAME} already exists — reusing."

# ECR push/pull, including CreateRepository (used by buildspec pre_build).
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

# CloudWatch Logs so the build output is streamable.
cat > /tmp/codebuild-logs.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "*"
    }
  ]
}
EOF
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name codebuild-logs --policy-document file:///tmp/codebuild-logs.json

# --- 1b. S3 source: bucket + read permission on the source object ---
if [ "$SOURCE_TYPE" = "S3" ]; then
  if ! aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    echo "Creating source bucket s3://${S3_BUCKET}"
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  cat > /tmp/codebuild-s3.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
    }
  ]
}
EOF
  aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name codebuild-s3-source --policy-document file:///tmp/codebuild-s3.json
fi

# IAM role propagation can lag; give it a moment before CodeBuild references it.
echo "Waiting for IAM role to propagate..."
sleep 10

# --- 2. Assemble source args ---
# LINUX_CONTAINER standard image is amd64 (EKS-compatible). privilegedMode is
# required for docker build (Docker-in-Docker). BUILD_GENERAL1_LARGE gives the
# extra disk/RAM the large vLLM image needs.
ENV_ARG="type=LINUX_CONTAINER,image=aws/codebuild/amazonlinux2-x86_64-standard:5.0,computeType=BUILD_GENERAL1_LARGE,privilegedMode=true"

SRC_VERSION_ARG=()
if [ "$SOURCE_TYPE" = "S3" ]; then
  SOURCE_ARG="type=S3,location=${S3_BUCKET}/${S3_KEY},buildspec=buildspec.yml"
else
  SOURCE_ARG="type=GITHUB,location=${GITHUB_REPO},buildspec=buildspec.yml"
  SRC_VERSION_ARG=(--source-version "$SOURCE_BRANCH")
fi

# --- 3. Create (or update) the CodeBuild project ---
aws codebuild create-project \
  --name "$PROJECT_NAME" \
  --region "$AWS_REGION" \
  --source "$SOURCE_ARG" \
  ${SRC_VERSION_ARG[@]+"${SRC_VERSION_ARG[@]}"} \
  --artifacts "type=NO_ARTIFACTS" \
  --environment "$ENV_ARG" \
  --service-role "$ROLE_ARN" \
  >/dev/null 2>&1 \
  || aws codebuild update-project \
       --name "$PROJECT_NAME" \
       --region "$AWS_REGION" \
       --source "$SOURCE_ARG" \
       ${SRC_VERSION_ARG[@]+"${SRC_VERSION_ARG[@]}"} \
       --artifacts "type=NO_ARTIFACTS" \
       --environment "$ENV_ARG" \
       --service-role "$ROLE_ARN" >/dev/null

echo "CodeBuild project '${PROJECT_NAME}' is ready (source: ${SOURCE_TYPE})."
echo
if [ "$SOURCE_TYPE" = "S3" ]; then
  echo "Upload the source, then launch a build:"
  echo "  S3_BUCKET=${S3_BUCKET} S3_KEY=${S3_KEY} ./k8s/eks/codebuild-upload-source.sh"
fi
echo "Launch a build:"
echo "  aws codebuild start-build --project-name ${PROJECT_NAME} --region ${AWS_REGION} --query 'build.id' --output text"
echo "Stream logs:"
echo "  aws logs tail /aws/codebuild/${PROJECT_NAME} --follow --region ${AWS_REGION}"
