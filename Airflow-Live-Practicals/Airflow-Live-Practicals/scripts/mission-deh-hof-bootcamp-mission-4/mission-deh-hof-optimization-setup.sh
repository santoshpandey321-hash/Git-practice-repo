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
# DEH Silver Bootcamp - Mission 4 Setup Script (Self-Contained)
# Creates ALL infrastructure needed for Mission 4 live class.
# Includes everything from Mission 3 PLUS Mission 3 homework.
#
# Creates:
#   - S3 bucket + folder structure
#   - IAM Role for Glue (with all required policies)
#   - Uploads backup scripts to S3
#   - 3 Glue Job definitions (ingestion, raw-to-curated, curated-to-aggregated)
#   - 3 Glue Databases (raw, curated, aggregated)
#   - 3 Glue Crawlers
#   - 2 DynamoDB tables (metadata, audit) + metadata records
#   - SNS topic + email subscription
#   - Step Functions role + state machine
#   - EventBridge Scheduler role + schedule
#   - Lambda trigger role
#   - Runs the ingestion job
#
# Does NOT create (built in Lab 1):
#   - Lambda function (S3 event trigger)
#
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
BUCKET_NAME="mission-deh-hof-nyctlc-${ACCOUNT_ID}"
ROLE_NAME="mission-deh-hof-glue-role"
CRAWLER_RAW="mission-deh-hof-crawler-raw"
CRAWLER_CURATED="mission-deh-hof-crawler-curated"
CRAWLER_AGG="mission-deh-hof-crawler-aggregated"
METADATA_TABLE="mission-deh-hof-datalake-metadata"
AUDIT_TABLE="mission-deh-hof-job-audit"
JOB_INGESTION="mission-deh-hof-nyctlc-ingestion"
JOB_RAW_TO_CURATED="mission-deh-hof-raw-to-curated-etl"
JOB_CURATED_TO_AGG="mission-deh-hof-curated-to-aggregated-etl"
SNS_TOPIC_NAME="mission-deh-hof-pipeline-alerts"
STEP_FUNCTION_NAME="mission-deh-hof-lyft-pipeline"
SFN_ROLE_NAME="mission-deh-hof-stepfunctions-role"
SCHEDULER_ROLE_NAME="mission-deh-hof-scheduler-role"
LAMBDA_ROLE_NAME="mission-deh-hof-lambda-trigger-role"
SCRIPTS_DIR="$HOME/mission-deh-hof-bootcamp-mission-4/scripts"

# Log setup
LOG_DIR="$HOME/mission-deh-hof-bootcamp-mission-4/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"

# Track created resources for rollback
CREATED_RESOURCES=()
SETUP_FAILED=false

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "${LOG_FILE}"
}

rollback() {
    log "❌ SETUP FAILED — Rolling back created resources..."
    for resource in "${CREATED_RESOURCES[@]}"; do
        case "$resource" in
            "bucket")
                log "   Rolling back: Deleting S3 bucket ${BUCKET_NAME}..."
                aws s3 rb "s3://${BUCKET_NAME}" --force --no-paginate > /dev/null 2>&1 || true
                ;;
            "role")
                log "   Rolling back: Deleting IAM role ${ROLE_NAME}..."
                aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole --no-paginate > /dev/null 2>&1 || true
                aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --no-paginate > /dev/null 2>&1 || true
                aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess --no-paginate > /dev/null 2>&1 || true
                aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess --no-paginate > /dev/null 2>&1 || true
                aws iam delete-role-policy --role-name ${ROLE_NAME} --policy-name "GluePassRolePolicy" --no-paginate > /dev/null 2>&1 || true
                aws iam delete-role --role-name ${ROLE_NAME} --no-paginate > /dev/null 2>&1 || true
                ;;
            "db_raw")
                aws glue delete-database --name "nyctlc_raw" --no-paginate > /dev/null 2>&1 || true
                ;;
            "db_curated")
                aws glue delete-database --name "nyctlc_curated" --no-paginate > /dev/null 2>&1 || true
                ;;
            "db_aggregated")
                aws glue delete-database --name "nyctlc_aggregated" --no-paginate > /dev/null 2>&1 || true
                ;;
            "crawler_raw")
                aws glue delete-crawler --name ${CRAWLER_RAW} --no-paginate > /dev/null 2>&1 || true
                ;;
            "crawler_curated")
                aws glue delete-crawler --name ${CRAWLER_CURATED} --no-paginate > /dev/null 2>&1 || true
                ;;
            "crawler_agg")
                aws glue delete-crawler --name ${CRAWLER_AGG} --no-paginate > /dev/null 2>&1 || true
                ;;
            "job_ingestion")
                aws glue delete-job --job-name ${JOB_INGESTION} --no-paginate > /dev/null 2>&1 || true
                ;;
            "job_raw_to_curated")
                aws glue delete-job --job-name ${JOB_RAW_TO_CURATED} --no-paginate > /dev/null 2>&1 || true
                ;;
            "job_curated_to_agg")
                aws glue delete-job --job-name ${JOB_CURATED_TO_AGG} --no-paginate > /dev/null 2>&1 || true
                ;;
        esac
    done
    log "   Rollback complete."
    log "   Log file: ${LOG_FILE}"
    exit 1
}

log "============================================================"
log "  🚀 DEH Bootcamp Mission 4 — Event-Driven & Optimization Setup"
log "     (Self-Contained — Creates Everything From Scratch)"
log "============================================================"
log ""
log "📋 Configuration:"
log "   Account ID:       ${ACCOUNT_ID}"
log "   Region:           ${REGION}"
log "   S3 Bucket:        ${BUCKET_NAME}"
log "   Glue Role:        ${ROLE_NAME}"
log "   Metadata Table:   ${METADATA_TABLE}"
log "   Audit Table:      ${AUDIT_TABLE}"
log "   SNS Topic:        ${SNS_TOPIC_NAME}"
log "   Step Function:    ${STEP_FUNCTION_NAME}"
log "   Log file:         ${LOG_FILE}"
log ""

# =========================================================
# Step 1: Create S3 Bucket + Folder Structure
# =========================================================
log "📦 Step 1: Creating S3 bucket and folder structure..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Bucket already exists. Proceeding."
else
    if aws s3 mb "s3://${BUCKET_NAME}" --region ${REGION} --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("bucket")
        log "   ✅ Bucket created: ${BUCKET_NAME}"
    else
        log "   ❌ Failed to create bucket."
        SETUP_FAILED=true
        rollback
    fi
fi

# Create folder structure
log "   Creating folder structure..."
aws s3api put-object --bucket ${BUCKET_NAME} --key "raw/nyctlc/fhvhv_tripdata/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "raw/nyctlc/taxi_zone_lookup/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "curated/nyctlc/fhvhv_trips_curated/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "aggregated/nyctlc/daily_borough_summary/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "aggregated/nyctlc/hourly_pattern_summary/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "aggregated/nyctlc/route_summary/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "scripts/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "athena-results/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
aws s3api put-object --bucket ${BUCKET_NAME} --key "rejected/nyctlc/" --content-length 0 --no-paginate > /dev/null 2>&1 || true
log "   ✅ Folder structure created."

# =========================================================
# Step 2: Create IAM Role for Glue
# =========================================================
log ""
log "🔐 Step 2: Creating IAM Role for Glue..."

TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name ${ROLE_NAME} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Role already exists. Ensuring policies are attached..."
else
    if aws iam create-role --role-name ${ROLE_NAME} \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --description "Glue role for DEH Bootcamp - Mission 4" \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("role")
        log "   ⏳ Waiting for IAM role to propagate (10 seconds)..."
        sleep 10
        log "   ✅ Role created: ${ROLE_NAME}"
    else
        log "   ❌ Failed to create IAM role."
        SETUP_FAILED=true
        rollback
    fi
fi

# Attach managed policies (idempotent)
aws iam attach-role-policy --role-name ${ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole \
    --no-paginate > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name ${ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess \
    --no-paginate > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name ${ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess \
    --no-paginate > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name ${ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess \
    --no-paginate > /dev/null 2>&1 || true
log "   ✅ Managed policies attached: AWSGlueServiceRole, AmazonS3FullAccess, AmazonDynamoDBFullAccess, AmazonSNSFullAccess"

# Add inline PassRole policy
PASSROLE_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",\"Resource\":\"arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}\"}]}"
aws iam put-role-policy --role-name ${ROLE_NAME} \
    --policy-name "GluePassRolePolicy" \
    --policy-document "${PASSROLE_POLICY}" \
    --no-paginate > /dev/null 2>&1 || true
log "   ✅ Inline PassRole policy attached."

ROLE_ARN=$(aws iam get-role --role-name ${ROLE_NAME} --query 'Role.Arn' --output text --no-paginate 2>/dev/null)

# =========================================================
# Step 3: Upload Backup Scripts to S3
# =========================================================
log ""
log "📜 Step 3: Uploading Glue scripts to S3..."

if [ ! -d "${SCRIPTS_DIR}" ]; then
    log "   ❌ Scripts directory not found: ${SCRIPTS_DIR}"
    log "   ❌ Please ensure the mission-deh-hof-bootcamp-mission-4/scripts/ folder exists."
    SETUP_FAILED=true
    rollback
fi

SCRIPT_FILES=("backup-nyctlc-ingestion.py" "backup-raw-to-curated.py" "backup-curated-to-aggregated.py")
UPLOAD_FAILED=false

for SCRIPT_FILE in "${SCRIPT_FILES[@]}"; do
    if [ ! -f "${SCRIPTS_DIR}/${SCRIPT_FILE}" ]; then
        log "   ❌ Script not found: ${SCRIPTS_DIR}/${SCRIPT_FILE}"
        UPLOAD_FAILED=true
    fi
done

if [ "$UPLOAD_FAILED" = true ]; then
    log "   ❌ One or more scripts are missing. Cannot continue."
    SETUP_FAILED=true
    rollback
fi

for SCRIPT_FILE in "${SCRIPT_FILES[@]}"; do
    aws s3 cp "${SCRIPTS_DIR}/${SCRIPT_FILE}" "s3://${BUCKET_NAME}/scripts/${SCRIPT_FILE}" \
        --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Uploaded: ${SCRIPT_FILE} → s3://${BUCKET_NAME}/scripts/${SCRIPT_FILE}"
done

# =========================================================
# Step 4: Create Glue Job Definitions
# =========================================================
log ""
log "⚙️  Step 4: Creating Glue job definitions..."

# Job 1: Ingestion (Python Shell)
log "   Creating job: ${JOB_INGESTION} (Python Shell)..."
if aws glue get-job --job-name ${JOB_INGESTION} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Job ${JOB_INGESTION} already exists. Proceeding."
else
    if aws glue create-job \
        --name ${JOB_INGESTION} \
        --role ${ROLE_ARN} \
        --command "{\"Name\": \"pythonshell\", \"ScriptLocation\": \"s3://${BUCKET_NAME}/scripts/backup-nyctlc-ingestion.py\", \"PythonVersion\": \"3.9\"}" \
        --max-capacity 0.0625 \
        --timeout 30 \
        --max-retries 0 \
        --glue-version "3.0" \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("job_ingestion")
        log "   ✅ Created job: ${JOB_INGESTION}"
    else
        log "   ❌ Failed to create job: ${JOB_INGESTION}"
        SETUP_FAILED=true
        rollback
    fi
fi

# Job 2: Raw to Curated (Spark ETL)
log "   Creating job: ${JOB_RAW_TO_CURATED} (Spark ETL)..."
if aws glue get-job --job-name ${JOB_RAW_TO_CURATED} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Job ${JOB_RAW_TO_CURATED} already exists. Proceeding."
else
    if aws glue create-job \
        --name ${JOB_RAW_TO_CURATED} \
        --role ${ROLE_ARN} \
        --command "{\"Name\": \"glueetl\", \"ScriptLocation\": \"s3://${BUCKET_NAME}/scripts/backup-raw-to-curated.py\", \"PythonVersion\": \"3\"}" \
        --glue-version "5.1" \
        --worker-type "G.1X" \
        --number-of-workers 2 \
        --timeout 30 \
        --max-retries 0 \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("job_raw_to_curated")
        log "   ✅ Created job: ${JOB_RAW_TO_CURATED}"
    else
        log "   ❌ Failed to create job: ${JOB_RAW_TO_CURATED}"
        SETUP_FAILED=true
        rollback
    fi
fi

# Job 3: Curated to Aggregated (Spark ETL)
log "   Creating job: ${JOB_CURATED_TO_AGG} (Spark ETL)..."
if aws glue get-job --job-name ${JOB_CURATED_TO_AGG} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Job ${JOB_CURATED_TO_AGG} already exists. Proceeding."
else
    if aws glue create-job \
        --name ${JOB_CURATED_TO_AGG} \
        --role ${ROLE_ARN} \
        --command "{\"Name\": \"glueetl\", \"ScriptLocation\": \"s3://${BUCKET_NAME}/scripts/backup-curated-to-aggregated.py\", \"PythonVersion\": \"3\"}" \
        --glue-version "5.1" \
        --worker-type "G.1X" \
        --number-of-workers 2 \
        --timeout 30 \
        --max-retries 0 \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("job_curated_to_agg")
        log "   ✅ Created job: ${JOB_CURATED_TO_AGG}"
    else
        log "   ❌ Failed to create job: ${JOB_CURATED_TO_AGG}"
        SETUP_FAILED=true
        rollback
    fi
fi

# =========================================================
# Step 5: Create Glue Databases
# =========================================================
log ""
log "🗄️  Step 5: Creating Glue Catalog databases..."

for DB_NAME in "nyctlc_raw" "nyctlc_curated" "nyctlc_aggregated"; do
    if aws glue get-database --name ${DB_NAME} --no-paginate > /dev/null 2>&1; then
        log "   ⚠️  Database ${DB_NAME} already exists. Proceeding."
    else
        if aws glue create-database \
            --database-input "{\"Name\": \"${DB_NAME}\", \"Description\": \"DEH Bootcamp - ${DB_NAME}\"}" \
            --no-paginate > /dev/null 2>&1; then
            CREATED_RESOURCES+=("db_${DB_NAME#nyctlc_}")
            log "   ✅ Created database: ${DB_NAME}"
        else
            log "   ❌ Failed to create database: ${DB_NAME}"
            SETUP_FAILED=true
            rollback
        fi
    fi
done

# =========================================================
# Step 6: Create Glue Crawlers
# =========================================================
log ""
log "🕷️  Step 6: Creating Glue Crawlers..."

# Crawler: Raw
if aws glue get-crawler --name ${CRAWLER_RAW} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Crawler ${CRAWLER_RAW} already exists. Proceeding."
else
    if aws glue create-crawler --name ${CRAWLER_RAW} \
        --role ${ROLE_ARN} \
        --database-name "nyctlc_raw" \
        --targets "{\"S3Targets\": [{\"Path\": \"s3://${BUCKET_NAME}/raw/nyctlc/fhvhv_tripdata/\"}, {\"Path\": \"s3://${BUCKET_NAME}/raw/nyctlc/taxi_zone_lookup/\"}]}" \
        --schema-change-policy "{\"UpdateBehavior\": \"UPDATE_IN_DATABASE\", \"DeleteBehavior\": \"LOG\"}" \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("crawler_raw")
        log "   ✅ Created crawler: ${CRAWLER_RAW}"
    else
        log "   ❌ Failed to create crawler: ${CRAWLER_RAW}"
        SETUP_FAILED=true
        rollback
    fi
fi

# Crawler: Curated
if aws glue get-crawler --name ${CRAWLER_CURATED} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Crawler ${CRAWLER_CURATED} already exists. Proceeding."
else
    if aws glue create-crawler --name ${CRAWLER_CURATED} \
        --role ${ROLE_ARN} \
        --database-name "nyctlc_curated" \
        --targets "{\"S3Targets\": [{\"Path\": \"s3://${BUCKET_NAME}/curated/nyctlc/fhvhv_trips_curated/\"}]}" \
        --schema-change-policy "{\"UpdateBehavior\": \"UPDATE_IN_DATABASE\", \"DeleteBehavior\": \"LOG\"}" \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("crawler_curated")
        log "   ✅ Created crawler: ${CRAWLER_CURATED}"
    else
        log "   ❌ Failed to create crawler: ${CRAWLER_CURATED}"
        SETUP_FAILED=true
        rollback
    fi
fi

# Crawler: Aggregated
if aws glue get-crawler --name ${CRAWLER_AGG} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Crawler ${CRAWLER_AGG} already exists. Proceeding."
else
    if aws glue create-crawler --name ${CRAWLER_AGG} \
        --role ${ROLE_ARN} \
        --database-name "nyctlc_aggregated" \
        --targets "{\"S3Targets\": [{\"Path\": \"s3://${BUCKET_NAME}/aggregated/nyctlc/daily_borough_summary/\"}, {\"Path\": \"s3://${BUCKET_NAME}/aggregated/nyctlc/hourly_pattern_summary/\"}, {\"Path\": \"s3://${BUCKET_NAME}/aggregated/nyctlc/route_summary/\"}]}" \
        --schema-change-policy "{\"UpdateBehavior\": \"UPDATE_IN_DATABASE\", \"DeleteBehavior\": \"LOG\"}" \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("crawler_agg")
        log "   ✅ Created crawler: ${CRAWLER_AGG}"
    else
        log "   ❌ Failed to create crawler: ${CRAWLER_AGG}"
        SETUP_FAILED=true
        rollback
    fi
fi

# =========================================================
# Step 7: Create DynamoDB Tables + Metadata Records
# =========================================================
log ""
log "📊 Step 7: Creating DynamoDB tables and inserting metadata..."

# Metadata table
if aws dynamodb describe-table --table-name ${METADATA_TABLE} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Table ${METADATA_TABLE} already exists. Proceeding."
else
    if aws dynamodb create-table \
        --table-name ${METADATA_TABLE} \
        --attribute-definitions '[{"AttributeName":"pipeline_name","AttributeType":"S"},{"AttributeName":"job_name","AttributeType":"S"}]' \
        --key-schema '[{"AttributeName":"pipeline_name","KeyType":"HASH"},{"AttributeName":"job_name","KeyType":"RANGE"}]' \
        --billing-mode PAY_PER_REQUEST \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("metadata_table")
        log "   ✅ Created table: ${METADATA_TABLE}"
        log "   ⏳ Waiting for table to become active..."
        aws dynamodb wait table-exists --table-name ${METADATA_TABLE} --no-paginate > /dev/null 2>&1 || true
    else
        log "   ❌ Failed to create table: ${METADATA_TABLE}"
        SETUP_FAILED=true
        rollback
    fi
fi

# Audit table
if aws dynamodb describe-table --table-name ${AUDIT_TABLE} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Table ${AUDIT_TABLE} already exists. Proceeding."
else
    if aws dynamodb create-table \
        --table-name ${AUDIT_TABLE} \
        --attribute-definitions '[{"AttributeName":"job_name","AttributeType":"S"},{"AttributeName":"run_timestamp","AttributeType":"S"}]' \
        --key-schema '[{"AttributeName":"job_name","KeyType":"HASH"},{"AttributeName":"run_timestamp","KeyType":"RANGE"}]' \
        --billing-mode PAY_PER_REQUEST \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        CREATED_RESOURCES+=("audit_table")
        log "   ✅ Created table: ${AUDIT_TABLE}"
        log "   ⏳ Waiting for table to become active..."
        aws dynamodb wait table-exists --table-name ${AUDIT_TABLE} --no-paginate > /dev/null 2>&1 || true
    else
        log "   ❌ Failed to create table: ${AUDIT_TABLE}"
        SETUP_FAILED=true
        rollback
    fi
fi

# Insert metadata records
log "   Inserting pipeline metadata records..."
aws dynamodb put-item --table-name ${METADATA_TABLE} --item \
    '{"pipeline_name":{"S":"lyft-nyctlc-pipeline"},"job_name":{"S":"mission-deh-hof-nyctlc-ingestion"},"job_type":{"S":"pythonshell"},"description":{"S":"Downloads 6 months of Lyft HVFHV trip data from NYCTLC and uploads to S3 raw layer"},"owner":{"S":"data-engineering-team"},"sla":{"S":"Data available by 6 AM UTC on the 5th of every month"},"source":{"S":"NYCTLC CloudFront"},"target":{"S":"s3://raw/nyctlc/fhvhv_tripdata/"}}' \
    --region ${REGION} --no-paginate > /dev/null 2>&1 || true

aws dynamodb put-item --table-name ${METADATA_TABLE} --item \
    '{"pipeline_name":{"S":"lyft-nyctlc-pipeline"},"job_name":{"S":"mission-deh-hof-raw-to-curated-etl"},"job_type":{"S":"glueetl"},"description":{"S":"Applies data quality filters, adds derived columns, joins with zone lookup"},"owner":{"S":"data-engineering-team"},"sla":{"S":"Data available by 6 AM UTC on the 5th of every month"},"source":{"S":"s3://raw/nyctlc/fhvhv_tripdata/"},"target":{"S":"s3://curated/nyctlc/fhvhv_trips_curated/"}}' \
    --region ${REGION} --no-paginate > /dev/null 2>&1 || true

aws dynamodb put-item --table-name ${METADATA_TABLE} --item \
    '{"pipeline_name":{"S":"lyft-nyctlc-pipeline"},"job_name":{"S":"mission-deh-hof-curated-to-aggregated-etl"},"job_type":{"S":"glueetl"},"description":{"S":"Produces daily borough, hourly pattern, and route summary aggregations"},"owner":{"S":"data-engineering-team"},"sla":{"S":"Data available by 6 AM UTC on the 5th of every month"},"source":{"S":"s3://curated/nyctlc/fhvhv_trips_curated/"},"target":{"S":"s3://aggregated/nyctlc/"}}' \
    --region ${REGION} --no-paginate > /dev/null 2>&1 || true

log "   ✅ Inserted 3 metadata records."

# =========================================================
# Step 8: Create SNS Topic + Email Subscription
# =========================================================
log ""
log "📬 Step 8: Creating SNS topic and email subscription..."

SNS_TOPIC_ARN=""
if aws sns get-topic-attributes --topic-arn "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}" --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  SNS topic already exists. Proceeding."
    SNS_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"
else
    SNS_TOPIC_ARN=$(aws sns create-topic --name ${SNS_TOPIC_NAME} --query 'TopicArn' --output text --no-paginate 2>/dev/null)
    if [ -n "$SNS_TOPIC_ARN" ]; then
        log "   ✅ Created SNS topic: ${SNS_TOPIC_NAME}"
        log "   Topic ARN: ${SNS_TOPIC_ARN}"
    else
        log "   ❌ Failed to create SNS topic."
        log "   ℹ️  Continuing — you can create it manually."
    fi
fi

# Prompt user for email
echo ""
read -p "Enter your email for pipeline alerts: " USER_EMAIL
echo ""

if [ -n "$USER_EMAIL" ] && [ -n "$SNS_TOPIC_ARN" ]; then
    aws sns subscribe --topic-arn ${SNS_TOPIC_ARN} \
        --protocol email \
        --notification-endpoint "${USER_EMAIL}" \
        --no-paginate > /dev/null 2>&1 || true
    log "   ✅ Email subscription created for: ${USER_EMAIL}"
    log "   📧 Check your email and confirm the subscription before proceeding!"
    log "   ⏳ Waiting 10 seconds for you to confirm..."
    sleep 10
else
    log "   ⚠️  No email provided or topic creation failed. Skipping subscription."
fi

# =========================================================
# Step 9: Create Step Functions Execution Role
# =========================================================
log ""
log "🔐 Step 9: Creating Step Functions execution role..."

SFN_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name ${SFN_ROLE_NAME} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Step Function role already exists. Ensuring policies are attached..."
else
    if aws iam create-role --role-name ${SFN_ROLE_NAME} \
        --assume-role-policy-document "${SFN_TRUST_POLICY}" \
        --description "Step Functions role for DEH Bootcamp pipeline orchestration" \
        --no-paginate > /dev/null 2>&1; then
        log "   ✅ Role created: ${SFN_ROLE_NAME}"
        sleep 5
    else
        log "   ❌ Failed to create Step Function role."
        log "   ℹ️  Continuing — you can create it manually."
    fi
fi

aws iam attach-role-policy --role-name ${SFN_ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess \
    --no-paginate > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name ${SFN_ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess \
    --no-paginate > /dev/null 2>&1 || true
log "   ✅ Policies attached: AWSGlueConsoleFullAccess, AmazonSNSFullAccess"

SFN_ROLE_ARN=$(aws iam get-role --role-name ${SFN_ROLE_NAME} --query 'Role.Arn' --output text --no-paginate 2>/dev/null)

# =========================================================
# Step 10: Create EventBridge Scheduler Role
# =========================================================
log ""
log "🔐 Step 10: Creating EventBridge Scheduler role..."

SCHEDULER_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name ${SCHEDULER_ROLE_NAME} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Scheduler role already exists. Ensuring policies are attached..."
else
    if aws iam create-role --role-name ${SCHEDULER_ROLE_NAME} \
        --assume-role-policy-document "${SCHEDULER_TRUST_POLICY}" \
        --description "EventBridge Scheduler role for DEH Bootcamp pipeline scheduling" \
        --no-paginate > /dev/null 2>&1; then
        log "   ✅ Role created: ${SCHEDULER_ROLE_NAME}"
        sleep 5
    else
        log "   ❌ Failed to create Scheduler role."
        log "   ℹ️  Continuing — you can create it manually."
    fi
fi

SCHEDULER_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"states:StartExecution\",\"Resource\":[\"arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:mission-deh-hof-lyft-pipeline\",\"arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:mission-deh-hof-lyft-transform-pipeline\"]}]}"
aws iam put-role-policy --role-name ${SCHEDULER_ROLE_NAME} \
    --policy-name "StepFunctionsStartExecution" \
    --policy-document "${SCHEDULER_POLICY}" \
    --no-paginate > /dev/null 2>&1 || true
log "   ✅ Policy attached: StepFunctionsStartExecution"

SCHEDULER_ROLE_ARN=$(aws iam get-role --role-name ${SCHEDULER_ROLE_NAME} --query 'Role.Arn' --output text --no-paginate 2>/dev/null)

# =========================================================
# Step 11: Create Lambda Trigger Role
# =========================================================
log ""
log "🔐 Step 11: Creating Lambda trigger role..."

LAMBDA_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name ${LAMBDA_ROLE_NAME} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Lambda trigger role already exists. Ensuring policies are attached..."
else
    if aws iam create-role --role-name ${LAMBDA_ROLE_NAME} \
        --assume-role-policy-document "${LAMBDA_TRUST_POLICY}" \
        --description "Lambda role for S3 event trigger - DEH Bootcamp" \
        --no-paginate > /dev/null 2>&1; then
        log "   ✅ Role created: ${LAMBDA_ROLE_NAME}"
        sleep 5
    else
        log "   ❌ Failed to create Lambda trigger role."
        log "   ℹ️  Continuing — you can create it manually."
    fi
fi

aws iam attach-role-policy --role-name ${LAMBDA_ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
    --no-paginate > /dev/null 2>&1 || true

LAMBDA_SFN_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"states:StartExecution\",\"Resource\":[\"arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:mission-deh-hof-lyft-pipeline\",\"arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:mission-deh-hof-lyft-transform-pipeline\"]}]}"
aws iam put-role-policy --role-name ${LAMBDA_ROLE_NAME} \
    --policy-name "StepFunctionsStartExecution" \
    --policy-document "${LAMBDA_SFN_POLICY}" \
    --no-paginate > /dev/null 2>&1 || true
log "   ✅ Policies attached: AWSLambdaBasicExecutionRole, StepFunctionsStartExecution"

# =========================================================
# Step 12: Create Step Function State Machine
# =========================================================
log ""
log "🔧 Step 12: Creating Step Function state machine..."

SFN_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${STEP_FUNCTION_NAME}"

if aws stepfunctions describe-state-machine --state-machine-arn ${SFN_ARN} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Step Function already exists. Proceeding."
else
    # ASL Definition with 3 Glue jobs, catch → SNS on failure, notify on success
    ASL_DEFINITION=$(cat <<EOF
{
  "Comment": "Lyft NYCTLC Data Pipeline - Orchestrated by Step Functions",
  "StartAt": "RunIngestion",
  "States": {
    "RunIngestion": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${JOB_INGESTION}"
      },
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "NotifyFailure",
        "ResultPath": "$.error"
      }],
      "Next": "RunRawToCurated"
    },
    "RunRawToCurated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${JOB_RAW_TO_CURATED}"
      },
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "NotifyFailure",
        "ResultPath": "$.error"
      }],
      "Next": "RunCuratedToAggregated"
    },
    "RunCuratedToAggregated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${JOB_CURATED_TO_AGG}"
      },
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "NotifyFailure",
        "ResultPath": "$.error"
      }],
      "Next": "NotifyAnalysts"
    },
    "NotifyAnalysts": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}",
        "Subject": "✅ Lyft Pipeline Complete - Data Available",
        "Message": "Pipeline complete, data available. All 3 Glue jobs finished successfully. Aggregated data is ready for analysis."
      },
      "Next": "PipelineSucceeded"
    },
    "PipelineSucceeded": {
      "Type": "Succeed"
    },
    "NotifyFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}",
        "Subject": "❌ Lyft Pipeline FAILED - Action Required",
        "Message.$": "States.Format('Pipeline failed. Error: {}', $.error.Cause)"
      },
      "Next": "PipelineFailed"
    },
    "PipelineFailed": {
      "Type": "Fail",
      "Error": "PipelineExecutionFailed",
      "Cause": "One or more Glue jobs failed. Check CloudWatch logs for details."
    }
  }
}
EOF
)

    if aws stepfunctions create-state-machine \
        --name ${STEP_FUNCTION_NAME} \
        --definition "${ASL_DEFINITION}" \
        --role-arn "${SFN_ROLE_ARN}" \
        --type STANDARD \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        log "   ✅ Created Step Function: ${STEP_FUNCTION_NAME}"
    else
        log "   ❌ Failed to create Step Function."
        log "   ℹ️  Continuing — you can create it manually in the console."
    fi
fi

# Create Transform-Only Pipeline (event-driven, triggered by ingestion.done marker)
log "   Creating Transform Step Function: mission-deh-hof-lyft-transform-pipeline..."

TRANSFORM_SFN_NAME="mission-deh-hof-lyft-transform-pipeline"
TRANSFORM_SFN_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${TRANSFORM_SFN_NAME}"

if aws stepfunctions describe-state-machine --state-machine-arn ${TRANSFORM_SFN_ARN} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Transform Step Function already exists. Proceeding."
else
    TRANSFORM_ASL=$(cat <<EOF
{
  "Comment": "Lyft NYCTLC Transform Pipeline - Triggered by ingestion.done marker",
  "StartAt": "RawToCurated",
  "States": {
    "RawToCurated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${JOB_RAW_TO_CURATED}"
      },
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "NotifyFailure-RawToCurated"}],
      "Next": "CuratedToAggregated"
    },
    "CuratedToAggregated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${JOB_CURATED_TO_AGG}"
      },
      "Catch": [{"ErrorEquals": ["States.ALL"], "ResultPath": "$.error", "Next": "NotifyFailure-CuratedToAggregated"}],
      "Next": "NotifyAnalysts"
    },
    "NotifyAnalysts": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}",
        "Subject": "✅ Lyft Transform Pipeline Complete — Data Available",
        "Message": "The Lyft transform pipeline has completed successfully. Fresh curated and aggregated data is now available in Athena."
      },
      "Next": "PipelineSucceeded"
    },
    "NotifyFailure-RawToCurated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}",
        "Subject": "❌ Transform Pipeline FAILED — Raw to Curated",
        "Message.$": "States.Format('Transform pipeline failed at: Raw to Curated\\n\\nError: {}\\nCause: {}', $.error.Error, $.error.Cause)"
      },
      "Next": "PipelineFailed"
    },
    "NotifyFailure-CuratedToAggregated": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}",
        "Subject": "❌ Transform Pipeline FAILED — Curated to Aggregated",
        "Message.$": "States.Format('Transform pipeline failed at: Curated to Aggregated\\n\\nError: {}\\nCause: {}', $.error.Error, $.error.Cause)"
      },
      "Next": "PipelineFailed"
    },
    "PipelineSucceeded": {
      "Type": "Succeed"
    },
    "PipelineFailed": {
      "Type": "Fail",
      "Error": "TransformPipelineFailed",
      "Cause": "One or more transform jobs failed."
    }
  }
}
EOF
)

    if aws stepfunctions create-state-machine \
        --name ${TRANSFORM_SFN_NAME} \
        --definition "${TRANSFORM_ASL}" \
        --role-arn "${SFN_ROLE_ARN}" \
        --type STANDARD \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        log "   ✅ Created Transform Step Function: ${TRANSFORM_SFN_NAME}"
    else
        log "   ❌ Failed to create Transform Step Function."
        log "   ℹ️  Continuing — you can create it manually in the console."
    fi
fi

# =========================================================
# Step 13: Create EventBridge Schedule (DISABLED)
# =========================================================
log ""
log "📅 Step 13: Creating EventBridge schedule (disabled)..."

SCHEDULE_NAME="mission-deh-hof-pipeline-schedule"

if aws scheduler get-schedule --name ${SCHEDULE_NAME} --no-paginate > /dev/null 2>&1; then
    log "   ⚠️  Schedule already exists. Proceeding."
else
    if aws scheduler create-schedule \
        --name ${SCHEDULE_NAME} \
        --schedule-expression "cron(0 6 5 * ? *)" \
        --target "{\"Arn\": \"arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${STEP_FUNCTION_NAME}\", \"RoleArn\": \"${SCHEDULER_ROLE_ARN}\"}" \
        --flexible-time-window '{"Mode": "OFF"}' \
        --state DISABLED \
        --region ${REGION} \
        --no-paginate > /dev/null 2>&1; then
        log "   ✅ Created EventBridge schedule: ${SCHEDULE_NAME} (DISABLED)"
        log "   Cron: 6 AM UTC on the 5th of every month"
    else
        log "   ❌ Failed to create EventBridge schedule."
        log "   ℹ️  Continuing — you can create it manually."
    fi
fi

# =========================================================
# =========================================================
# Step 14: Summary
# =========================================================
log ""
log "============================================================"
log "  ✅ MISSION 4 SETUP COMPLETE!"
log "============================================================"
log ""
log "  Resources Created:"
log "    ┌─────────────────────────────────────────────────────────"
log "    │ S3 Bucket:        ${BUCKET_NAME}"
log "    │ IAM Roles:"
log "    │   - ${ROLE_NAME} (Glue)"
log "    │   - ${SFN_ROLE_NAME} (Step Functions)"
log "    │   - ${SCHEDULER_ROLE_NAME} (EventBridge Scheduler)"
log "    │   - ${LAMBDA_ROLE_NAME} (Lambda Trigger)"
log "    │ Glue Jobs:"
log "    │   - ${JOB_INGESTION} (Python Shell)"
log "    │   - ${JOB_RAW_TO_CURATED} (Spark ETL)"
log "    │   - ${JOB_CURATED_TO_AGG} (Spark ETL)"
log "    │ Glue Databases:"
log "    │   - nyctlc_raw"
log "    │   - nyctlc_curated"
log "    │   - nyctlc_aggregated"
log "    │ Glue Crawlers:"
log "    │   - ${CRAWLER_RAW} → nyctlc_raw"
log "    │   - ${CRAWLER_CURATED} → nyctlc_curated"
log "    │   - ${CRAWLER_AGG} → nyctlc_aggregated"
log "    │ DynamoDB Tables:"
log "    │   - ${METADATA_TABLE} (with 3 metadata records)"
log "    │   - ${AUDIT_TABLE}"
log "    │ SNS Topic: ${SNS_TOPIC_NAME}"
log "    │ Step Function: ${STEP_FUNCTION_NAME}"
log "    │ Step Function: mission-deh-hof-lyft-transform-pipeline (event-driven)"
log "    │ EventBridge Schedule: ${SCHEDULE_NAME} (DISABLED)"
log "    └─────────────────────────────────────────────────────────"
log ""
log "  🎓 Created in LAB 1 (not by this script):"
log "    - Lambda function: mission-deh-hof-pipeline-trigger"
log "    - S3 event trigger on raw/ prefix"
log ""
log "  Region:    ${REGION}"
log "  Log file:  ${LOG_FILE}"
log ""
log "  Next: Open bootcamp-mission4-lab1-event-driven.html"
log "============================================================"
