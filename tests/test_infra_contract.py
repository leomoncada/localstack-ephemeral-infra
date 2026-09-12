"""Assertions about the deployed infrastructure.

These are executable policy, not static analysis: they describe the real state
of the world after apply, which is a stronger claim than a linter pass.

Imports live at the top of this file (not appended per test) because tasks 4
and 5 append test functions here, and the shared helpers/imports must stay in
one predictable place for that to be natural.
"""


def test_receipts_table_has_point_in_time_recovery(aws, tf_outputs):
    ddb = aws("dynamodb")
    backups = ddb.describe_continuous_backups(
        TableName=tf_outputs["receipts_table_name"]
    )
    status = backups["ContinuousBackupsDescription"][
        "PointInTimeRecoveryDescription"
    ]["PointInTimeRecoveryStatus"]
    assert status == "ENABLED"


def test_ingest_bucket_has_versioning_enabled(aws, tf_outputs):
    s3 = aws("s3")
    versioning = s3.get_bucket_versioning(Bucket=tf_outputs["ingest_bucket_name"])
    assert versioning.get("Status") == "Enabled"


def test_ingest_bucket_blocks_all_public_access(aws, tf_outputs):
    s3 = aws("s3")
    config = s3.get_public_access_block(
        Bucket=tf_outputs["ingest_bucket_name"]
    )["PublicAccessBlockConfiguration"]
    assert config["BlockPublicAcls"]
    assert config["IgnorePublicAcls"]
    assert config["BlockPublicPolicy"]
    assert config["RestrictPublicBuckets"]
