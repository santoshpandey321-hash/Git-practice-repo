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
# Airflow Lab 2 — Backup DAG: PRODUCER
# Runs the ingestion Glue job and declares the raw Asset as its output.
# When data_ingestion succeeds, Airflow marks raw_asset as updated,
# which auto-triggers the consumer DAG (nyc_tlc_consumer.py).
#
# IMPORTANT: the Asset URI must match EXACTLY in both producer & consumer.
# ============================================================

from datetime import datetime
from airflow.sdk import DAG, Asset
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

# Shared Asset — must be identical in nyc_tlc_consumer.py
raw_asset = Asset("s3://mission-deh-hof/nyctlc/fhvhv_tripdata_raw")

default_args = {
    'owner': 'mission-deh-hof',
    'retries': 1,
}

with DAG(
    dag_id='nyc_tlc_producer',
    default_args=default_args,
    schedule='@monthly',
    start_date=datetime(2026, 1, 1),
) as dag:

    data_ingestion = GlueJobOperator(
        task_id='data_ingestion',
        job_name='mission-deh-hof-nyctlc-ingestion',
        outlets=[raw_asset],          # declares this task PRODUCES the raw asset
    )
