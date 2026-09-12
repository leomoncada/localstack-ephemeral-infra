"""Parse receipts uploaded to S3 and persist them to DynamoDB.

Deliberately small. The point of this repository is the infrastructure and its
test loop, not the business logic.
"""

import json
import os
import urllib.parse

import boto3

# LocalStack injects AWS_ENDPOINT_URL into the Lambda environment; on real AWS
# it is unset and boto3 resolves the public endpoints. Same code, both targets.
_ENDPOINT = os.environ.get("AWS_ENDPOINT_URL") or None
_TABLE_NAME = os.environ["RECEIPTS_TABLE"]

_s3 = boto3.client("s3", endpoint_url=_ENDPOINT)
_table = boto3.resource("dynamodb", endpoint_url=_ENDPOINT).Table(_TABLE_NAME)

REQUIRED_FIELDS = ("receipt_id", "merchant", "total_cents")


def _parse(body):
    """Return a fully coerced item, or raise ValueError.

    Coercion happens here, inside the caller's guarded block, rather than at
    the put_item call site. A receipt can be well-formed JSON with every
    required field present and still carry an unusable value
    (`total_cents: "abc"`); coercing outside the guard would turn that into an
    uncaught exception, i.e. an infrastructure-level failure that burns
    retries and lands in the DLQ. A bad value is a bad payload and must be
    rejected on the same path.
    """
    receipt = json.loads(body)
    missing = [field for field in REQUIRED_FIELDS if field not in receipt]
    if missing:
        raise ValueError(f"missing required fields: {missing}")

    raw_total = receipt["total_cents"]
    try:
        total_cents = int(raw_total)
    except (TypeError, ValueError):
        raise ValueError(f"total_cents is not an integer: {raw_total!r}") from None

    return {
        "receipt_id": str(receipt["receipt_id"]),
        "merchant": str(receipt["merchant"]),
        "total_cents": total_cents,
    }


def handler(event, context):
    stored = 0
    rejected = 0

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        body = _s3.get_object(Bucket=bucket, Key=key)["Body"].read()

        try:
            receipt = _parse(body)
        except (json.JSONDecodeError, TypeError, ValueError) as exc:
            # Rejected, not raised: a bad object must not fail the invocation,
            # because a retry would only re-read the same bad object. This log
            # line is the positive evidence of clean rejection that
            # test_malformed_receipt_is_rejected_without_routing_to_the_dlq
            # asserts on.
            print(f"rejected s3://{bucket}/{key}: {exc}")
            rejected += 1
            continue

        _table.put_item(Item={**receipt, "source_key": key})
        stored += 1

    return {"stored": stored, "rejected": rejected}
