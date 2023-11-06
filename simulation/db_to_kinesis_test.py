import os
import time
from sshtunnel import SSHTunnelForwarder
import boto3
import psycopg2

# Kinesis configurations
KINESIS_STREAM_NAME = 'example-kinesis-stream'
REGION_NAME = 'us-west-2'

# Fetch SSM parameters
ssm_client = boto3.client('ssm', region_name=REGION_NAME)


def get_ssm_parameter(name):
    param = ssm_client.get_parameter(Name=name, WithDecryption=True)[
        'Parameter']['Value']
    print(param)
    return param


DB_ENDPOINT = get_ssm_parameter('/database/endpoint').split(':')[0]
DB_PORT = 5432
DB_USER = get_ssm_parameter('/database/username')
DB_PASSWORD = get_ssm_parameter('/database/password')
# Assuming you have stored the DB name in SSM
DB_NAME = get_ssm_parameter('/database/dbname')


SSH_HOST = os.environ['SSH_HOST']
SSH_PORT = 22
SSH_USER = os.environ['SSH_USER']
SSH_PRIVATE_KEY = os.environ['SSH_PRIVATE_KEY']


def create_ssh_tunnel():
    server = SSHTunnelForwarder(
        (SSH_HOST, SSH_PORT),
        ssh_username=SSH_USER,
        ssh_pkey=SSH_PRIVATE_KEY,
        remote_bind_address=(DB_ENDPOINT, DB_PORT)
    )
    server.start()
    return server


def create_table_if_not_exists():
    with create_ssh_tunnel() as server:
        local_port = server.local_bind_port
        conn = psycopg2.connect(
            host='127.0.0.1',
            port=local_port,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            sslmode='disable'
        )
        cur = conn.cursor()
        print(f'Connected to DB: {DB_NAME}')
        # Check if table exists and create if not
        cur.execute("""
            CREATE TABLE IF NOT EXISTS test_replication (
                id SERIAL PRIMARY KEY,
                data_string VARCHAR(255)
            );
        """)

        conn.commit()
        cur.close()
        conn.close()


def insert_into_db(data):
    with create_ssh_tunnel() as server:
        local_port = server.local_bind_port
        conn = psycopg2.connect(
            host='127.0.0.1',
            port=local_port,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            sslmode='disable'
        )
        cur = conn.cursor()
        print(f'Connected to DB: {DB_NAME} Inserting data: {data}')
        cur.execute(
            "INSERT INTO test_replication (data_string) VALUES (%s) RETURNING id;", (data,))
        record_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        conn.close()
        print(f"Inserted data with ID: {record_id}")
        return record_id


def read_from_kinesis():
    client = boto3.client('kinesis', region_name=REGION_NAME)
    shard_id = 'shardId-000000000000'  # We assume a single shard in this example
    shard_iterator = client.get_shard_iterator(
        StreamName=KINESIS_STREAM_NAME,
        ShardId=shard_id,
        ShardIteratorType='LATEST'
    )['ShardIterator']

    records = client.get_records(ShardIterator=shard_iterator, Limit=1)
    return records['Records']


def main():
    num_inserts = int(input("Enter the number of inserts to simulate: "))

    for i in range(num_inserts):
        data = f"TestData-{i}"
        inserted_id = insert_into_db(data)
        print(f"Inserted data with ID: {inserted_id}")

        # Wait for a short duration before checking Kinesis (to allow for replication)
        time.sleep(5)

        kinesis_records = read_from_kinesis()
        if kinesis_records:
            print(
                f"Received data from Kinesis: {kinesis_records[0]['Data'].decode('utf-8')}")
        else:
            print("No data received from Kinesis yet.")


if __name__ == "__main__":
    main()
