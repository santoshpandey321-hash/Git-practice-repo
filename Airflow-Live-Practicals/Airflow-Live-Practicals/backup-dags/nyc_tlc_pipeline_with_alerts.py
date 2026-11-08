# Copyright © Sachin Chandrashekhar - Data Engineering Hub. All Rights Reserved.
#
# This code is provided as part of a paid training program.
# Unauthorized copying, distribution, or publication of this code—either in
# whole or in part—is strictly prohibited.
#
# Licensed for personal educational use only.
# If this code is found on a public repository or distributed without
# authorization, please notify: legal@dataengineeringhub.in
# ============================================================
# Airflow Lab 1 — Backup DAG: NYC TLC Pipeline (with SNS alerts)
# Same pipeline as nyc_tlc_pipeline.py, plus:
#   - on_failure_callback  -> SNS alert if any task fails
#   - notify_success task  -> SNS alert when the pipeline finishes
# SNS topic (created by the setup script): mission-deh-hof-pipeline-alerts
# ============================================================

from datetime import datetime
from airflow import DAG
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator
from airflow.operators.python import PythonOperator
import boto3


def send_failure_notification(context):
    """Called automatically when a task fails."""
    account_id = boto3.client('sts').get_caller_identity()['Account']
    sns = boto3.client('sns', region_name='us-east-1')
    topic_arn = f"arn:aws:sns:us-east-1:{account_id}:mission-deh-hof-pipeline-alerts"
    ti = context['task_instance']
    sns.publish(
        TopicArn=topic_arn,
        Subject='NYC TLC Pipeline FAILED',
        Message=f"Task '{ti.task_id}' failed in DAG '{ti.dag_id}'.",
    )


def send_success_notification(**context):
    """Called when the whole pipeline finishes successfully."""
    account_id = boto3.client('sts').get_caller_identity()['Account']
    sns = boto3.client('sns', region_name='us-east-1')
    topic_arn = f"arn:aws:sns:us-east-1:{account_id}:mission-deh-hof-pipeline-alerts"
    sns.publish(
        TopicArn=topic_arn,
        Subject='NYC TLC Pipeline SUCCESS',
        Message="All 3 stages completed: ingestion, curated, aggregated.",
    )


default_args = {
    'owner': 'mission-deh-hof',
    'retries': 1,
    'on_failure_callback': send_failure_notification,
}

with DAG(
    dag_id='nyc_tlc_pipeline',
    default_args=default_args,
    schedule='@monthly',
    start_date=datetime(2026, 1, 1),
) as dag:

    data_ingestion = GlueJobOperator(
        task_id='data_ingestion',
        job_name='mission-deh-hof-nyctlc-ingestion',
    )

    raw_to_curated = GlueJobOperator(
        task_id='raw_to_curated',
        job_name='mission-deh-hof-raw-to-curated-etl',
    )

    curated_to_aggregated = GlueJobOperator(
        task_id='curated_to_aggregated',
        job_name='mission-deh-hof-curated-to-aggregated-etl',
    )

    notify_success = PythonOperator(
        task_id='notify_success',
        python_callable=send_success_notification,
    )

    data_ingestion >> raw_to_curated >> curated_to_aggregated >> notify_success
