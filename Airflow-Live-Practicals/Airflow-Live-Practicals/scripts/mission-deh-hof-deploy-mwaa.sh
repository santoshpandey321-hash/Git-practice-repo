#!/bin/bash

# Copyright © Sachin Chandrashekhar - Data Engineering Hub. All Rights Reserved.
#
# This code is provided as part of a paid training program.
# Unauthorized copying, distribution, or
# publication of this code—either in whole or in part—
# is strictly prohibited.
#
# This code may NOT be:
# - Uploaded to public repositories (GitHub, GitLab, etc.)
# - Shared with third parties
# - Used for commercial purposes
#
# Licensed for personal educational use only.
#
# If this code is found on a public repository or distributed without
# authorization, please notify: legal@dataengineeringhub.in

set -e

STACK_NAME="mission-deh-hof-stack"
REGION="us-east-1"
TEMPLATE_FILE="mission-deh-hof-mwaa-stack.yaml"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="mission-deh-hof-airflow-${ACCOUNT_ID}"

cleanup() {
    echo ""
    echo "[ERROR] Deployment failed. Initiating cleanup..."
    echo "[INFO] Deleting stack: $STACK_NAME"
    aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION 2>/dev/null || true
    echo "[INFO] Waiting for stack deletion..."
    aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION 2>/dev/null || true
    echo "[INFO] Cleanup completed"
    exit 1
}

trap cleanup ERR

# =========================================================
# REGION CHECK — This lab must run in us-east-1
# =========================================================
BOLD="$(tput bold 2>/dev/null || echo '')"
RESET="$(tput sgr0 2>/dev/null || echo '')"
DETECTED_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "")}}"

if [ -n "$DETECTED_REGION" ] && [ "$DETECTED_REGION" != "us-east-1" ]; then
    echo ""
    echo "${BOLD}[WARNING] Your environment is NOT set to us-east-1 (detected: ${DETECTED_REGION}).${RESET}"
    echo "${BOLD}[WARNING] This lab is designed for us-east-1 (N. Virginia).${RESET}"
    echo ""
    echo "[INFO] How to set your region to us-east-1 in CloudShell, then re-run this script:"
    echo "       export AWS_REGION=us-east-1"
    echo "       export AWS_DEFAULT_REGION=us-east-1"
    echo ""
    echo "[INFO] This script forces every AWS call to us-east-1 regardless, so it will"
    echo "       continue — but set the region above to avoid confusion when viewing resources."
    echo ""
elif [ -z "$DETECTED_REGION" ]; then
    echo ""
    echo "${BOLD}[WARNING] No AWS region detected in your environment.${RESET}"
    echo "[INFO] Set it before continuing to avoid confusion:"
    echo "       export AWS_REGION=us-east-1"
    echo "       export AWS_DEFAULT_REGION=us-east-1"
    echo ""
    echo "[INFO] This script forces us-east-1 on every call, so it will continue."
    echo ""
else
    echo "[INFO] Region check passed: us-east-1"
fi

echo "[INFO] Starting MWAA deployment"
echo "[INFO] Stack Name: $STACK_NAME"
echo "[INFO] Region: $REGION"
echo "[INFO] Template: $TEMPLATE_FILE"
echo ""

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "[ERROR] Template file $TEMPLATE_FILE not found"
    exit 1
fi

echo "[INFO] Checking if stack already exists..."
if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION &>/dev/null; then
    echo "[INFO] Stack $STACK_NAME already exists, skipping stack creation"
    STACK_EXISTS=true
else
    STACK_EXISTS=false
    echo "[INFO] Creating CloudFormation stack..."
    STACK_ID=$(aws cloudformation create-stack \
      --stack-name $STACK_NAME \
      --template-body file://$TEMPLATE_FILE \
      --capabilities CAPABILITY_NAMED_IAM \
      --region $REGION \
      --parameters ParameterKey=BucketName,ParameterValue=$BUCKET_NAME \
      --output text)

    echo "[INFO] Stack ID: $STACK_ID"
    echo "[INFO] Waiting for stack creation (this takes ~20-30 minutes)..."
    echo ""

    while true; do
        STATUS=$(aws cloudformation describe-stacks \
            --stack-name $STACK_NAME \
            --region $REGION \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "UNKNOWN")
        
        echo "[INFO] Current status: $STATUS ($(date '+%Y-%m-%d %H:%M:%S'))"
        
        if [[ "$STATUS" == "CREATE_COMPLETE" ]]; then
            break
        elif [[ "$STATUS" == "CREATE_FAILED" ]] || [[ "$STATUS" == "ROLLBACK_COMPLETE" ]] || [[ "$STATUS" == "ROLLBACK_FAILED" ]]; then
            echo "[ERROR] Stack creation failed with status: $STATUS"
            echo "[INFO] Fetching stack events for error details..."
            aws cloudformation describe-stack-events \
                --stack-name $STACK_NAME \
                --region $REGION \
                --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
                --output table
            cleanup
        fi
        
        sleep 30
    done

    echo ""
    echo "[SUCCESS] Stack created successfully!"
fi
echo ""
echo "[INFO] Stack Outputs:"
aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --region $REGION \
  --query 'Stacks[0].Outputs' \
  --output table

echo ""
echo "[INFO] Creating dags folder in S3 bucket..."
if aws s3api head-object --bucket $BUCKET_NAME --key dags/ --region $REGION &>/dev/null; then
    echo "[INFO] dags folder already exists, skipping"
else
    aws s3api put-object --bucket $BUCKET_NAME --key dags/ --region $REGION
    echo "[INFO] dags folder created successfully"
fi
echo ""
echo "[INFO] Next steps:"
echo "  1. Upload DAG files to: s3://${BUCKET_NAME}/dags/"
echo "  2. Access Airflow UI using the WebserverUrl above"
echo ""
echo "[INFO] Deployment completed successfully!"
