from datetime import datetime
from airflow import DAG
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

default_args = {
    'owner': 'mission-deh-hof',
    'retries': 1,
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

data_ingestion >> raw_to_curated >> curated_to_aggregated