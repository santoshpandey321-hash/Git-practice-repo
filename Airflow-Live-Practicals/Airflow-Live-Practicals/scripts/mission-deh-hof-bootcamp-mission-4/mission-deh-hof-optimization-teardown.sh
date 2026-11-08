#!/bin/bash
# Copyright © Sachin Chandrashekhar - Data Engineering Hub. All Rights Reserved.
#
# This code is provided as part of a paid training program.
# Unauthorized copying, distribution, or
# publication of this code—either in whole or in part—
# is strictly prohibited.
#
# This code may NOT be:
# - Uploaded to public repositories (GitHub, GitLab, etc.) unless approved by Data Engineering Hub
# - Shared with third parties
# - Used for commercial purposes
#
# Licensed for personal educational use only.
#
# If this code is found on a public repository or distributed without
# authorization, please notify: legal@dataengineeringhub.in
# ============================================================
# DEH Silver Bootcamp - Mission 4 Teardown Script
# Removes ALL resources: Glue jobs, crawlers, databases, Lambda,
# EventBridge, Step Function, SNS, DynamoDB, S3 bucket, IAM roles
# Region: us-east-1
# ============================================================

export AWS_PAGER=""
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-paginate)

# =========================================================
# REGION CHECK — Must run in us-east-1
# =========================================================
CURRENT_REGION="${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "")}"

if [ "$CURRENT_REGION" != "us-east-1" ] && [ -n "$CURRENT_REGION" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    ❌ WRONG REGION!                         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  This script MUST be run from us-east-1 (N. Virginia).     ║"
    echo "║                                                            ║"
    echo "║  Your current region: ${CURRENT_REGION}                    ║"
    echo "║                                                            ║"
    echo "║  HOW TO FIX:                                               ║"
    echo "║  1. Open AWS Console                                       ║"
    echo "║  2. Top-right corner → click region dropdown               ║"
    echo "║  3. Select 'US East (N. Virginia) us-east-1'               ║"
    echo "║  4. Open CloudShell again from us-east-1                   ║"
    echo "║  5. Re-run this script                                     ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# =========================================================
# Variables
# =========================================================
ROLE_NAME="mission-deh-hof-glue-role"
SNS_TOPIC_NAME="mission-deh-hof-pipeline-alerts"
METADATA_TABLE="mission-deh-hof-datalake-metadata"
AUDIT_TABLE="mission-deh-hof-job-audit"
STEP_FUNCTION_NAME="mission-deh-hof-lyft-pipeline"
S3_BUCKET="mission-deh-hof-nyctlc-${ACCOUNT_ID}"
LAMBDA_FUNCTION_NAME="mission-deh-hof-pipeline-trigger"
LAMBDA_ROLE_NAME="mission-deh-hof-lambda-trigger-role"
SFN_CUSTOM_ROLE="mission-deh-hof-stepfunctions-role"
SCHEDULER_ROLE="mission-deh-hof-scheduler-role"
SCHEDULE_NAME="mission-deh-hof-pipeline-schedule"

GLUE_JOBS=("mission-deh-hof-nyctlc-ingestion" "mission-deh-hof-raw-to-curated-etl" "mission-deh-hof-curated-to-aggregated-etl")
GLUE_CRAWLERS=("mission-deh-hof-crawler-raw" "mission-deh-hof-crawler-curated" "mission-deh-hof-crawler-aggregated")
GLUE_DATABASES=("nyctlc_raw" "nyctlc_curated" "nyctlc_aggregated")

# Log setup
LOG_DIR="$HOME/mission-deh-hof-bootcamp-mission-4/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/teardown-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "${LOG_FILE}"
}

log "============================================================"
log "  🧹 DEH Bootcamp Mission 4 — Full Teardown"
log "============================================================"
log ""
log "📋 Will remove ALL Mission 4 resources"
log "   Log file: ${LOG_FILE}"
log ""

# ---------------------------------------------------------
# Step 1: Delete Glue jobs
# ---------------------------------------------------------
log "🗑️  Step 1: Deleting Glue jobs..."
for JOB_NAME in "${GLUE_JOBS[@]}"; do
    if aws glue get-job --job-name ${JOB_NAME} --no-paginate > /dev/null 2>&1; then
        aws glue delete-job --job-name ${JOB_NAME} --no-paginate > /dev/null 2>&1 || true
        log "   ✅ Deleted Glue job: ${JOB_NAME}"
    else
        log "   ⚠️  Glue job not found: ${JOB_NAME} (skipping)"
    fi
done

# ---------------------------------------------------------
# Step 2: Delete Glue crawlers
# ---------------------------------------------------------
log ""
log "🗑️  Step 2: Deleting Glue crawlers..."
for CRAWLER_NAME in "${GLUE_CRAWLERS[@]}"; do
    if aws glue get-crawler --name ${CRAWLER_NAME} --no-paginate > /dev/null 2>&1; then
        aws glue delete-crawler --name ${CRAWLER_NAME} --no-paginate > /dev/null 2>&1 || true
        log "   ✅ Deleted Glue crawler: ${CRAWLER_NAME}"
    else
        log "   ⚠️  Glue crawler not found: ${CRAWLER_NAME} (skipping)"
    fi
done

# ---------------------------------------------------------
# Step 3: Delete Glue databases (with tables)
# ---------------------------------------------------------
log ""
log "🗑️  Step 3: Deleting Glue databases and tables..."
for DB_NAME in "${GLUE_DATABASES[@]}"; do
    if aws glue get-database --name ${DB_NAME} --no-paginate > /dev/null 2>&1; then
        TABLES=$(aws glue get-tables --database-name ${DB_NAME} --query 'TableList[].Name' --output text --no-paginate 2>/dev/null || echo "")
        for TABLE_NAME in ${TABLES}; do
            aws glue delete-table --database-name ${DB_NAME} --name ${TABLE_NAME} --no-paginate > /dev/null 2>&1 || true
            log "   ✅ Deleted table: ${DB_NAME}.${TABLE_NAME}"
        done
        aws glue delete-database --name ${DB_NAME} --no-paginate > /dev/null 2>&1 || true
        log "   ✅ Deleted Glue database: ${DB_NAME}"
    else
        log "   ⚠️  Glue database not found: ${DB_NAME} (skipping)"
    fi
done

# ---------------------------------------------------------
# Step 4: Delete Lambda function
# ---------------------------------------------------------
log ""
log "🗑️  Step 4: Deleting Lambda function..."
if aws lambda get-function --function-name ${LAMBDA_FUNCTION_NAME} --no-paginate > /dev/null 2>&1; then
    aws lambda delete-function --function-name ${LAMBDA_FUNCTION_NAME} --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted Lambda function: ${LAMBDA_FUNCTION_NAME}"
else
    log "   ⚠️  Lambda function not found: ${LAMBDA_FUNCTION_NAME} (skipping)"
fi

# ---------------------------------------------------------
# Step 5: Delete Lambda trigger role
# ---------------------------------------------------------
log ""
log "🗑️  Step 5: Deleting Lambda trigger role..."
if aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" --no-paginate > /dev/null 2>&1; then
    POLICIES=$(aws iam list-attached-role-policies --role-name "${LAMBDA_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_ARN in ${POLICIES}; do
        aws iam detach-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-arn ${POLICY_ARN} --no-paginate > /dev/null 2>&1 || true
    done
    INLINE_POLICIES=$(aws iam list-role-policies --role-name "${LAMBDA_ROLE_NAME}" --query 'PolicyNames[]' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_NAME in ${INLINE_POLICIES}; do
        aws iam delete-role-policy --role-name "${LAMBDA_ROLE_NAME}" --policy-name ${POLICY_NAME} --no-paginate > /dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "${LAMBDA_ROLE_NAME}" --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted Lambda role: ${LAMBDA_ROLE_NAME}"
else
    log "   ⚠️  Lambda role not found (skipping)"
fi

# ---------------------------------------------------------
# Step 6: Delete EventBridge Schedule
# ---------------------------------------------------------
log ""
log "🗑️  Step 6: Deleting EventBridge schedule..."
if aws scheduler get-schedule --name ${SCHEDULE_NAME} --no-paginate > /dev/null 2>&1; then
    aws scheduler delete-schedule --name ${SCHEDULE_NAME} --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted EventBridge schedule: ${SCHEDULE_NAME}"
else
    log "   ⚠️  EventBridge schedule not found (skipping)"
fi

# ---------------------------------------------------------
# Step 7: Delete Step Function state machine
# ---------------------------------------------------------
log ""
log "🗑️  Step 7: Deleting Step Function state machines..."
SFN_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${STEP_FUNCTION_NAME}"
if aws stepfunctions describe-state-machine --state-machine-arn ${SFN_ARN} --no-paginate > /dev/null 2>&1; then
    aws stepfunctions delete-state-machine --state-machine-arn ${SFN_ARN} --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted Step Function: ${STEP_FUNCTION_NAME}"
else
    log "   ⚠️  Step Function not found (skipping)"
fi

# Delete Transform Step Function
TRANSFORM_SFN_NAME="mission-deh-hof-lyft-transform-pipeline"
TRANSFORM_SFN_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${TRANSFORM_SFN_NAME}"
if aws stepfunctions describe-state-machine --state-machine-arn ${TRANSFORM_SFN_ARN} --no-paginate > /dev/null 2>&1; then
    aws stepfunctions delete-state-machine --state-machine-arn ${TRANSFORM_SFN_ARN} --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted Step Function: ${TRANSFORM_SFN_NAME}"
else
    log "   ⚠️  Transform Step Function not found (skipping)"
fi

# Delete the auto-created Step Functions role (if it exists)
SFN_AUTO_ROLE="StepFunctions-${STEP_FUNCTION_NAME}-role-${REGION}"
if aws iam get-role --role-name "${SFN_AUTO_ROLE}" --no-paginate > /dev/null 2>&1; then
    POLICIES=$(aws iam list-attached-role-policies --role-name "${SFN_AUTO_ROLE}" --query 'AttachedPolicies[].PolicyArn' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_ARN in ${POLICIES}; do
        aws iam detach-role-policy --role-name "${SFN_AUTO_ROLE}" --policy-arn ${POLICY_ARN} --no-paginate > /dev/null 2>&1 || true
    done
    INLINE_POLICIES=$(aws iam list-role-policies --role-name "${SFN_AUTO_ROLE}" --query 'PolicyNames[]' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_NAME in ${INLINE_POLICIES}; do
        aws iam delete-role-policy --role-name "${SFN_AUTO_ROLE}" --policy-name ${POLICY_NAME} --no-paginate > /dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "${SFN_AUTO_ROLE}" --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted auto-created Step Functions role: ${SFN_AUTO_ROLE}"
fi

# ---------------------------------------------------------
# Step 8: Delete Step Functions custom role
# ---------------------------------------------------------
log ""
log "🗑️  Step 8: Deleting Step Functions custom role..."
if aws iam get-role --role-name "${SFN_CUSTOM_ROLE}" --no-paginate > /dev/null 2>&1; then
    POLICIES=$(aws iam list-attached-role-policies --role-name "${SFN_CUSTOM_ROLE}" --query 'AttachedPolicies[].PolicyArn' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_ARN in ${POLICIES}; do
        aws iam detach-role-policy --role-name "${SFN_CUSTOM_ROLE}" --policy-arn ${POLICY_ARN} --no-paginate > /dev/null 2>&1 || true
    done
    INLINE_POLICIES=$(aws iam list-role-policies --role-name "${SFN_CUSTOM_ROLE}" --query 'PolicyNames[]' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_NAME in ${INLINE_POLICIES}; do
        aws iam delete-role-policy --role-name "${SFN_CUSTOM_ROLE}" --policy-name ${POLICY_NAME} --no-paginate > /dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "${SFN_CUSTOM_ROLE}" --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted Step Functions role: ${SFN_CUSTOM_ROLE}"
else
    log "   ⚠️  Step Functions role not found (skipping)"
fi

# ---------------------------------------------------------
# Step 9: Delete Scheduler role
# ---------------------------------------------------------
log ""
log "🗑️  Step 9: Deleting Scheduler role..."
if aws iam get-role --role-name "${SCHEDULER_ROLE}" --no-paginate > /dev/null 2>&1; then
    INLINE_POLICIES=$(aws iam list-role-policies --role-name "${SCHEDULER_ROLE}" --query 'PolicyNames[]' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_NAME in ${INLINE_POLICIES}; do
        aws iam delete-role-policy --role-name "${SCHEDULER_ROLE}" --policy-name ${POLICY_NAME} --no-paginate > /dev/null 2>&1 || true
    done
    aws iam delete-role --role-name "${SCHEDULER_ROLE}" --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted Scheduler role: ${SCHEDULER_ROLE}"
else
    log "   ⚠️  Scheduler role not found (skipping)"
fi

# ---------------------------------------------------------
# Step 10: Delete SNS topic and subscriptions
# ---------------------------------------------------------
log ""
log "🗑️  Step 10: Deleting SNS topic and subscriptions..."
SNS_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"
if aws sns get-topic-attributes --topic-arn ${SNS_TOPIC_ARN} --no-paginate > /dev/null 2>&1; then
    SUBS=$(aws sns list-subscriptions-by-topic --topic-arn ${SNS_TOPIC_ARN} --query 'Subscriptions[].SubscriptionArn' --output text --no-paginate 2>/dev/null || echo "")
    for SUB_ARN in ${SUBS}; do
        if [ "$SUB_ARN" != "PendingConfirmation" ] && [ -n "$SUB_ARN" ]; then
            aws sns unsubscribe --subscription-arn ${SUB_ARN} --no-paginate > /dev/null 2>&1 || true
        fi
    done
    aws sns delete-topic --topic-arn ${SNS_TOPIC_ARN} --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted SNS topic: ${SNS_TOPIC_NAME}"
else
    log "   ⚠️  SNS topic not found (skipping)"
fi

# ---------------------------------------------------------
# Step 11: Delete DynamoDB tables
# ---------------------------------------------------------
log ""
log "🗑️  Step 11: Deleting DynamoDB tables..."
for TABLE_NAME in "${METADATA_TABLE}" "${AUDIT_TABLE}"; do
    if aws dynamodb describe-table --table-name ${TABLE_NAME} --no-paginate > /dev/null 2>&1; then
        aws dynamodb delete-table --table-name ${TABLE_NAME} --no-paginate > /dev/null 2>&1 || true
        log "   ✅ Deleted table: ${TABLE_NAME}"
    else
        log "   ⚠️  Table not found: ${TABLE_NAME} (skipping)"
    fi
done

# ---------------------------------------------------------
# Step 12: Empty S3 bucket (keep bucket, remove all data)
# ---------------------------------------------------------
log ""
log "🗑️  Step 12: Emptying S3 bucket (keeping bucket)..."
if aws s3api head-bucket --bucket ${S3_BUCKET} --no-paginate > /dev/null 2>&1; then
    aws s3 rm s3://${S3_BUCKET} --recursive > /dev/null 2>&1 || true
    log "   ✅ All data removed from: ${S3_BUCKET}"
    # Add motivational message
    echo "Crack Interviews & See you in DEH Hall of Fame!" | aws s3 cp - "s3://${S3_BUCKET}/Crack Interviews & See you in DEH Hall of Fame.txt" --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Left a message for you in the bucket 🏆"
else
    log "   ⚠️  S3 bucket not found: ${S3_BUCKET} (skipping)"
fi

# ---------------------------------------------------------
# Step 13: Delete Glue IAM role
# ---------------------------------------------------------
log ""
log "🗑️  Step 13: Deleting Glue IAM role..."
if aws iam get-role --role-name ${ROLE_NAME} --no-paginate > /dev/null 2>&1; then
    POLICIES=$(aws iam list-attached-role-policies --role-name ${ROLE_NAME} --query 'AttachedPolicies[].PolicyArn' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_ARN in ${POLICIES}; do
        aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn ${POLICY_ARN} --no-paginate > /dev/null 2>&1 || true
    done
    INLINE_POLICIES=$(aws iam list-role-policies --role-name ${ROLE_NAME} --query 'PolicyNames[]' --output text --no-paginate 2>/dev/null || echo "")
    for POLICY_NAME in ${INLINE_POLICIES}; do
        aws iam delete-role-policy --role-name ${ROLE_NAME} --policy-name ${POLICY_NAME} --no-paginate > /dev/null 2>&1 || true
    done
    aws iam delete-role --role-name ${ROLE_NAME} --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Deleted Glue role: ${ROLE_NAME}"
else
    log "   ⚠️  Glue role not found (skipping)"
fi

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
log ""
log "============================================================"
log "  ✅ FULL TEARDOWN COMPLETE!"
log "============================================================"
log ""
log "  🏆 Crack Interviews & See you in DEH Hall of Fame! 🏆"
log ""
log "  Removed ALL Mission 4 resources."
log "  S3 bucket kept (emptied): ${S3_BUCKET}"
log ""
log "  Log file: ${LOG_FILE}"
log "============================================================"
