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
# DEH — MWAA Lab: One-Shot Setup
# ------------------------------------------------------------
# Runs the full setup in order:
#   1. Pipeline setup  (Glue jobs, S3 data lake, DynamoDB, SNS,
#                        Step Functions)  — Mission 4 self-contained script
#   2. MWAA deploy      (VPC, DAGs S3 bucket, Airflow 3.0.6 env)
#
# After this completes you build the DAG live in class — the Glue
# jobs and Step Functions it drives already exist.
#
# Region: us-east-1
# ============================================================

set -u

REGION="us-east-1"

# Resolve the directory this wrapper lives in, so it works no
# matter where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PIPELINE_BUNDLE_NAME="mission-deh-hof-bootcamp-mission-4"
PIPELINE_SRC="${SCRIPT_DIR}/${PIPELINE_BUNDLE_NAME}"
PIPELINE_HOME="${HOME}/${PIPELINE_BUNDLE_NAME}"
PIPELINE_SETUP="mission-deh-hof-optimization-setup.sh"

MWAA_DEPLOY="mission-deh-hof-deploy-mwaa.sh"
MWAA_TEMPLATE="mission-deh-hof-mwaa-stack.yaml"

BOLD="$(tput bold 2>/dev/null || echo '')"
RESET="$(tput sgr0 2>/dev/null || echo '')"

divider() { echo "============================================================"; }

# =========================================================
# Region check (single, up front)
# =========================================================
DETECTED_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "")}}"
if [ -n "$DETECTED_REGION" ] && [ "$DETECTED_REGION" != "us-east-1" ]; then
    echo ""
    echo "${BOLD}[WARNING] Your environment is NOT set to us-east-1 (detected: ${DETECTED_REGION}).${RESET}"
    echo "${BOLD}[WARNING] This lab is designed for us-east-1 (N. Virginia).${RESET}"
    echo ""
    echo "[INFO] Set your region, then re-run this script:"
    echo "       export AWS_REGION=us-east-1"
    echo "       export AWS_DEFAULT_REGION=us-east-1"
    echo ""
    echo "[INFO] Both child scripts force us-east-1 on every call, so this will"
    echo "       continue — but set the region above to avoid confusion."
    echo ""
elif [ -z "$DETECTED_REGION" ]; then
    echo ""
    echo "${BOLD}[WARNING] No AWS region detected. Set it to avoid confusion:${RESET}"
    echo "       export AWS_REGION=us-east-1"
    echo "       export AWS_DEFAULT_REGION=us-east-1"
    echo ""
else
    echo "[INFO] Region check passed: us-east-1"
fi

divider
echo "  🚀 DEH MWAA Lab — One-Shot Setup"
divider
echo ""
echo "  Step 1 of 2: Pipeline setup (Glue, S3, DynamoDB, SNS, Step Functions)"
echo "  Step 2 of 2: MWAA deploy (VPC, DAGs bucket, Airflow environment)"
echo ""

# =========================================================
# Step 1: Pipeline setup
# =========================================================
# The Mission 4 setup script hardcodes SCRIPTS_DIR to
# $HOME/mission-deh-hof-bootcamp-mission-4/scripts, so the bundle
# must sit at $HOME. Copy it there if it isn't already.
if [ ! -d "$PIPELINE_SRC" ]; then
    echo "${BOLD}[ERROR] Pipeline bundle not found at: ${PIPELINE_SRC}${RESET}"
    echo "[INFO] Expected the '${PIPELINE_BUNDLE_NAME}' folder next to this script."
    exit 1
fi

if [ "$PIPELINE_SRC" != "$PIPELINE_HOME" ]; then
    echo "[INFO] Staging pipeline bundle into \$HOME (required by the pipeline script)..."
    cp -r "$PIPELINE_SRC" "$HOME/"
fi

if [ ! -f "${PIPELINE_HOME}/${PIPELINE_SETUP}" ]; then
    echo "${BOLD}[ERROR] Pipeline setup script not found: ${PIPELINE_HOME}/${PIPELINE_SETUP}${RESET}"
    exit 1
fi

echo ""
divider
echo "  ▶ Step 1: Running pipeline setup..."
divider
chmod +x "${PIPELINE_HOME}/${PIPELINE_SETUP}"
if ! bash "${PIPELINE_HOME}/${PIPELINE_SETUP}"; then
    echo ""
    echo "${BOLD}[ERROR] Pipeline setup failed. Stopping before MWAA deploy.${RESET}"
    echo "[INFO] Fix the issue above, then re-run this script."
    echo "[INFO] (MWAA was NOT deployed, so no long-running charges were started.)"
    exit 1
fi
echo ""
echo "[SUCCESS] Pipeline setup completed."

# =========================================================
# Step 2: MWAA deploy
# =========================================================
if [ ! -f "${SCRIPT_DIR}/${MWAA_DEPLOY}" ]; then
    echo "${BOLD}[ERROR] MWAA deploy script not found: ${SCRIPT_DIR}/${MWAA_DEPLOY}${RESET}"
    exit 1
fi
if [ ! -f "${SCRIPT_DIR}/${MWAA_TEMPLATE}" ]; then
    echo "${BOLD}[ERROR] MWAA template not found: ${SCRIPT_DIR}/${MWAA_TEMPLATE}${RESET}"
    echo "[INFO] The deploy script needs '${MWAA_TEMPLATE}' in the same folder."
    exit 1
fi

echo ""
divider
echo "  ▶ Step 2: Deploying MWAA (this takes ~20-30 minutes)..."
divider
chmod +x "${SCRIPT_DIR}/${MWAA_DEPLOY}"
# Run from SCRIPT_DIR so the deploy script's relative template path resolves.
( cd "$SCRIPT_DIR" && ./"${MWAA_DEPLOY}" )
MWAA_STATUS=$?

echo ""
divider
if [ "$MWAA_STATUS" -eq 0 ]; then
    echo "  ✅ ALL DONE — pipeline + MWAA are ready."
    echo ""
    echo "  Next:"
    echo "    1. Grab the WebserverUrl from the MWAA stack outputs above."
    echo "    2. Build your DAG in class and upload it to the DAGs S3 bucket."
    echo "    3. Run the DAG — it drives the Glue jobs / Step Functions created in Step 1."
else
    echo "  ⚠️  Pipeline setup succeeded, but MWAA deploy exited with status ${MWAA_STATUS}."
    echo "     Review the MWAA output above. The deploy script auto-cleans a failed stack."
fi
divider
exit "$MWAA_STATUS"
