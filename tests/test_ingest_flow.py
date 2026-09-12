"""End-to-end assertions: a receipt uploaded to S3 reaches DynamoDB."""

import json
import time
import uuid

POLL_TIMEOUT_SECONDS = 60
POLL_INTERVAL_SECONDS = 2


def _wait_for_receipt(ddb, table_name, receipt_id):
    """Poll for an item with a bounded deadline.

    Event delivery is asynchronous on both targets, so a bare read races the
    pipeline. The failure message carries the last response to make a timeout
    diagnosable rather than merely red.
    """
    deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
    last_response = None
    while time.monotonic() < deadline:
        last_response = ddb.get_item(
            TableName=table_name,
            Key={"receipt_id": {"S": receipt_id}},
        )
        if "Item" in last_response:
            return last_response["Item"]
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(
        f"receipt {receipt_id} did not reach {table_name} within "
        f"{POLL_TIMEOUT_SECONDS}s. Last response: {last_response}"
    )


def _upload(aws, tf_outputs, key, body):
    aws("s3").put_object(
        Bucket=tf_outputs["ingest_bucket_name"], Key=key, Body=body
    )


def test_uploaded_receipt_is_persisted(aws, tf_outputs):
    receipt_id = f"rcpt-{uuid.uuid4()}"
    payload = {
        "receipt_id": receipt_id,
        "merchant": "Acme Hardware",
        "total_cents": 1299,
    }

    _upload(aws, tf_outputs, f"{receipt_id}.json", json.dumps(payload).encode())

    item = _wait_for_receipt(
        aws("dynamodb"), tf_outputs["receipts_table_name"], receipt_id
    )
    assert item["merchant"]["S"] == "Acme Hardware"
    assert item["total_cents"]["N"] == "1299"
    assert item["source_key"]["S"] == f"{receipt_id}.json"


def test_malformed_receipt_does_not_break_the_pipeline(aws, tf_outputs):
    """A bad payload must be rejected without poisoning the consumer."""
    bad_id = f"bad-{uuid.uuid4()}"
    _upload(aws, tf_outputs, f"{bad_id}.json", b"{ this is not valid json")

    # The pipeline must still be healthy afterwards.
    good_id = f"rcpt-{uuid.uuid4()}"
    payload = {
        "receipt_id": good_id,
        "merchant": "Still Working",
        "total_cents": 500,
    }
    _upload(aws, tf_outputs, f"{good_id}.json", json.dumps(payload).encode())

    item = _wait_for_receipt(
        aws("dynamodb"), tf_outputs["receipts_table_name"], good_id
    )
    assert item["merchant"]["S"] == "Still Working"

    # The malformed one must not have been stored.
    rejected = aws("dynamodb").get_item(
        TableName=tf_outputs["receipts_table_name"],
        Key={"receipt_id": {"S": bad_id}},
    )
    assert "Item" not in rejected
