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
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="mission-deh-hof-airflow-${ACCOUNT_ID}"

# =========================================================
# REGION CHECK — This lab must run in us-east-1
# =========================================================
BOLD="$(tput bold 2>/dev/null || echo '')"
RESET="$(tput sgr0 2>/dev/null || echo '')"
DETECTED_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "")}}"

if [ -n "$DETECTED_REGION" ] && [ "$DETECTED_REGION" != "us-east-1" ]; then
    echo ""
    echo "${BOLD}[WARNING] Your environment is NOT set to us-east-1 (detected: ${DETECTED_REGION}).${RESET}"
    echo "${BOLD}[WARNING] This lab's resources live in us-east-1 (N. Virginia).${RESET}"
    echo ""
    echo "[INFO] How to set your region to us-east-1 in CloudShell, then re-run this script:"
    echo "       export AWS_REGION=us-east-1"
    echo "       export AWS_DEFAULT_REGION=us-east-1"
    echo ""
    echo "[INFO] This script forces every AWS call to us-east-1 regardless, so it will"
    echo "       continue — but set the region above to avoid confusion."
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

echo "[INFO] Starting MWAA teardown"
echo "[INFO] Stack Name: $STACK_NAME"
echo "[INFO] Region: $REGION"
echo ""

echo "[INFO] Checking if stack exists..."
if ! aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION &>/dev/null; then
    echo "[INFO] Stack $STACK_NAME does not exist, nothing to delete"
    exit 0
fi

echo "[WARNING] Deleting the following resources:"
echo "  - MWAA Environment: mission-deh-hof"
echo "  - S3 Bucket: $BUCKET_NAME (including all contents)"
echo "  - VPC and all networking components"
echo "  - IAM Role: mission-deh-hof-execution-role"
echo ""
echo "[INFO] Emptying S3 bucket: $BUCKET_NAME"
if aws s3 ls s3://$BUCKET_NAME --region $REGION &>/dev/null; then
    echo "[INFO] Deleting all object versions..."
    aws s3api delete-objects --bucket $BUCKET_NAME --region $REGION \
        --delete "$(aws s3api list-object-versions --bucket $BUCKET_NAME --region $REGION \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --max-items 1000)" 2>/dev/null || true
    
    echo "[INFO] Deleting all delete markers..."
    aws s3api delete-objects --bucket $BUCKET_NAME --region $REGION \
        --delete "$(aws s3api list-object-versions --bucket $BUCKET_NAME --region $REGION \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --max-items 1000)" 2>/dev/null || true
    
    echo "[INFO] Deleting remaining objects..."
    aws s3 rm s3://$BUCKET_NAME --recursive --region $REGION
    echo "[INFO] S3 bucket emptied"
else
    echo "[INFO] S3 bucket does not exist or already empty"
fi

echo ""
echo "[INFO] Deleting CloudFormation stack: $STACK_NAME"
aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION

echo "[INFO] Waiting for stack deletion (this may take 10-15 minutes)..."
echo ""

while true; do
    STATUS=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "DELETED")
    
    if [[ "$STATUS" == "DELETED" ]]; then
        break
    fi
    
    echo "[INFO] Current status: $STATUS ($(date '+%Y-%m-%d %H:%M:%S'))"
    
    if [[ "$STATUS" == "DELETE_FAILED" ]]; then
        echo "[ERROR] Stack deletion failed"
        echo "[INFO] Fetching stack events for error details..."
        aws cloudformation describe-stack-events \
            --stack-name $STACK_NAME \
            --region $REGION \
            --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
            --output table
        exit 1
    fi
    
    sleep 30
done

echo ""
echo "[SUCCESS] Stack deleted successfully!"
echo "[INFO] All resources have been cleaned up"
