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


def _drain_dlq(sqs, queue_url):
    """Empty the dead-letter queue so a later read describes only this test.

    Drained by receive/delete rather than PurgeQueue: purge is rate-limited to
    once every 60 seconds on real AWS, which would make back-to-back suite
    runs flaky on one target but not the other.
    """
    while True:
        batch = sqs.receive_message(
            QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=0
        ).get("Messages", [])
        if not batch:
            return
        sqs.delete_message_batch(
            QueueUrl=queue_url,
            Entries=[
                {"Id": str(i), "ReceiptHandle": m["ReceiptHandle"]}
                for i, m in enumerate(batch)
            ],
        )


def _dlq_depth(sqs, queue_url):
    attributes = sqs.get_queue_attributes(
        QueueUrl=queue_url, AttributeNames=["ApproximateNumberOfMessages"]
    )["Attributes"]
    return int(attributes["ApproximateNumberOfMessages"])


def _wait_for_rejection_log(logs, function_name, key):
    """Wait for the handler to log that it rejected `key`.

    This is the assertion a crashed invocation can never satisfy: the line is
    printed only on the reject-and-continue path. It is what makes the
    DLQ-is-empty check below meaningful rather than merely fast.

    Necessary because the DLQ check alone is not sufficient. Routing a failed
    asynchronous invocation to the dead-letter queue was measured at roughly
    four minutes against LocalStack (two retries at ~60s apart, then routing),
    so reading an empty queue moments after an upload cannot by itself
    distinguish "rejected cleanly" from "crashed, message not routed yet".
    Together the two assertions can.
    """
    group = f"/aws/lambda/{function_name}"
    deadline = time.monotonic() + POLL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        for event in logs.filter_log_events(logGroupName=group).get("events", []):
            message = event["message"]
            if "rejected s3://" in message and key in message:
                return message
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(
        f"handler never logged a rejection for {key} within "
        f"{POLL_TIMEOUT_SECONDS}s; it did not take the reject-and-continue "
        "path, which means the invocation most likely failed instead"
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


def test_malformed_receipt_is_rejected_without_routing_to_the_dlq(aws, tf_outputs):
    """Bad input must be rejected in-process, not fail the invocation.

    S3 delivers one invocation per object, so a handler that simply crashed on
    bad input would still let an independent good upload succeed. "The good
    one arrived" therefore proves nothing about how the bad one was handled.
    What distinguishes clean rejection from crash-then-retry-into-DLQ is
    observable elsewhere: the handler logs the rejection, and nothing is
    routed to the dead-letter queue.

    Two shapes of bad input are covered, because they fail at different
    points: a payload that is not JSON at all, and a payload that is valid
    JSON with every required field present but an unusable value.
    """
    sqs = aws("sqs")
    dlq_url = tf_outputs["processor_dlq_url"]
    _drain_dlq(sqs, dlq_url)

    unparseable_key = f"bad-{uuid.uuid4()}.json"
    _upload(aws, tf_outputs, unparseable_key, b"{ this is not valid json")

    bad_value_id = f"badval-{uuid.uuid4()}"
    bad_value_key = f"{bad_value_id}.json"
    _upload(
        aws,
        tf_outputs,
        bad_value_key,
        json.dumps(
            {
                "receipt_id": bad_value_id,
                "merchant": "Acme Hardware",
                "total_cents": "abc",
            }
        ).encode(),
    )

    # Positive evidence of the reject-and-continue path. A crashing invocation
    # cannot produce these lines.
    logs = aws("logs")
    function_name = tf_outputs["processor_function_name"]
    _wait_for_rejection_log(logs, function_name, unparseable_key)
    _wait_for_rejection_log(logs, function_name, bad_value_key)

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

    # The bad value carried a receipt_id of its own, so a handler that coerced
    # it loosely instead of rejecting it would have stored it under that key.
    # This one is falsifiable, unlike a lookup keyed on an object name the
    # handler never reads.
    stored = aws("dynamodb").get_item(
        TableName=tf_outputs["receipts_table_name"],
        Key={"receipt_id": {"S": bad_value_id}},
    )
    assert "Item" not in stored, (
        f"{bad_value_id} carried total_cents='abc' and must not have been "
        "persisted"
    )

    # Nothing was escalated to an infrastructure-level failure.
    depth = _dlq_depth(sqs, dlq_url)
    assert depth == 0, (
        f"{depth} message(s) reached the dead-letter queue; bad input failed "
        "the invocation instead of being rejected in-process"
    )
