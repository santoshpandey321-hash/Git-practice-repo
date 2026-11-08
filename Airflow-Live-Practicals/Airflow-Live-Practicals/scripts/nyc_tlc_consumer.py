from datetime import datetime
from airflow.sdk import DAG, Asset
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

raw_asset = Asset("s3://mission-deh-hof/nyctlc/fhvhv_tripdata_raw")

default_args = {
    'owner': 'mission-deh-hof',
    'retries': 1,
}

with DAG(
    dag_id='nyc_tlc_consumer',
    default_args=default_args,
    schedule=[raw_asset],          # 👈 run whenever raw_asset is updated — no cron!
    start_date=datetime(2026, 1, 1),
) as dag:

    raw_to_curated = GlueJobOperator(
        task_id='raw_to_curated',
        job_name='mission-deh-hof-raw-to-curated-etl',
    )

    curated_to_aggregated = GlueJobOperator(
        task_id='curated_to_aggregated',
        job_name='mission-deh-hof-curated-to-aggregated-etl',
    )

    raw_to_curated >> curated_to_aggregated