from datetime import datetime
from airflow.sdk import DAG, Asset
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

raw_asset = Asset("s3://mission-deh-hof/nyctlc/fhvhv_tripdata_raw")

default_args = {
    'owner': 'mission-deh-hof',
    'retries': 1,
}

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
        outlets=[raw_asset],          # 👈 declares this task PRODUCES the raw asset
    )