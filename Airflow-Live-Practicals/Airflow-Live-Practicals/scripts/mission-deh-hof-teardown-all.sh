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
# ============================================================
# DEH — MWAA Lab: One-Shot Teardown
# ------------------------------------------------------------
# Removes everything the setup created, in order:
#   1. MWAA teardown    (Airflow env, DAGs bucket, VPC)  — FIRST,
#                        so the hourly MWAA billing stops ASAP.
#   2. Pipeline teardown (Glue, S3 data lake, DynamoDB, SNS,
#                        Step Functions, IAM roles)
#
# Region: us-east-1
# ============================================================

set -u

REGION="us-east-1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PIPELINE_BUNDLE_NAME="mission-deh-hof-bootcamp-mission-4"
PIPELINE_HOME="${HOME}/${PIPELINE_BUNDLE_NAME}"
PIPELINE_SRC="${SCRIPT_DIR}/${PIPELINE_BUNDLE_NAME}"
PIPELINE_TEARDOWN="mission-deh-hof-optimization-teardown.sh"

MWAA_TEARDOWN="mission-deh-hof-teardown-mwaa.sh"

BOLD="$(tput bold 2>/dev/null || echo '')"
RESET="$(tput sgr0 2>/dev/null || echo '')"

divider() { echo "============================================================"; }

divider
echo "  🧹 DEH MWAA Lab — One-Shot Teardown"
divider
echo ""
echo "  Step 1 of 2: MWAA teardown (Airflow env, DAGs bucket, VPC)"
echo "  Step 2 of 2: Pipeline teardown (Glue, S3, DynamoDB, SNS, Step Functions)"
echo ""
echo "${BOLD}  This permanently deletes all lab resources and their data.${RESET}"
echo ""

# =========================================================
# Step 1: MWAA teardown (stop the expensive clock first)
# =========================================================
if [ ! -f "${SCRIPT_DIR}/${MWAA_TEARDOWN}" ]; then
    echo "${BOLD}[ERROR] MWAA teardown script not found: ${SCRIPT_DIR}/${MWAA_TEARDOWN}${RESET}"
    exit 1
fi

echo ""
divider
echo "  ▶ Step 1: Tearing down MWAA (this takes ~10-15 minutes)..."
divider
chmod +x "${SCRIPT_DIR}/${MWAA_TEARDOWN}"
( cd "$SCRIPT_DIR" && ./"${MWAA_TEARDOWN}" )
MWAA_STATUS=$?
if [ "$MWAA_STATUS" -ne 0 ]; then
    echo ""
    echo "${BOLD}[WARNING] MWAA teardown exited with status ${MWAA_STATUS}.${RESET}"
    echo "[INFO] Continuing to pipeline teardown anyway. Re-check the CloudFormation"
    echo "       stack 'mission-deh-hof-stack' in the console afterwards."
fi

# =========================================================
# Step 2: Pipeline teardown
# =========================================================
# Prefer the copy staged in $HOME by setup; fall back to the one
# shipped next to this script.
if [ -f "${PIPELINE_HOME}/${PIPELINE_TEARDOWN}" ]; then
    PIPELINE_TEARDOWN_PATH="${PIPELINE_HOME}/${PIPELINE_TEARDOWN}"
elif [ -f "${PIPELINE_SRC}/${PIPELINE_TEARDOWN}" ]; then
    PIPELINE_TEARDOWN_PATH="${PIPELINE_SRC}/${PIPELINE_TEARDOWN}"
else
    echo ""
    echo "${BOLD}[ERROR] Pipeline teardown script not found.${RESET}"
    echo "[INFO] Looked in:"
    echo "       ${PIPELINE_HOME}/${PIPELINE_TEARDOWN}"
    echo "       ${PIPELINE_SRC}/${PIPELINE_TEARDOWN}"
    exit 1
fi

echo ""
divider
echo "  ▶ Step 2: Tearing down the data pipeline..."
divider
chmod +x "${PIPELINE_TEARDOWN_PATH}"
bash "${PIPELINE_TEARDOWN_PATH}"
PIPELINE_STATUS=$?

echo ""
divider
if [ "$MWAA_STATUS" -eq 0 ] && [ "$PIPELINE_STATUS" -eq 0 ]; then
    echo "  ✅ ALL DONE — pipeline + MWAA fully torn down. Billing has stopped."
else
    echo "  ⚠️  Teardown finished with warnings (MWAA=${MWAA_STATUS}, pipeline=${PIPELINE_STATUS})."
    echo "     Verify in the console that these are gone:"
    echo "       - CloudFormation stack: mission-deh-hof-stack"
    echo "       - S3 buckets: mission-deh-hof-airflow-* and mission-deh-hof-nyctlc-*"
fi
divider
