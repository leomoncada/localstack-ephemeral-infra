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
