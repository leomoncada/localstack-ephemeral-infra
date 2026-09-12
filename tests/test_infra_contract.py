"""Assertions about the deployed infrastructure.

These are executable policy, not static analysis: they describe the real state
of the world after apply, which is a stronger claim than a linter pass.

Imports live at the top of this file (not appended per test) because tasks 4
and 5 append test functions here, and the shared helpers/imports must stay in
one predictable place for that to be natural.
"""

import json
import urllib.parse


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


def _role_policy_documents(iam, role_name):
    """Yield every inline policy document attached to a role, decoded."""
    for policy_name in iam.list_role_policies(RoleName=role_name)["PolicyNames"]:
        document = iam.get_role_policy(
            RoleName=role_name, PolicyName=policy_name
        )["PolicyDocument"]
        # IAM returns this either URL-encoded JSON or already decoded,
        # depending on the client and the backend. Handle both.
        if isinstance(document, str):
            document = json.loads(urllib.parse.unquote(document))
        yield policy_name, document


def test_processor_role_grants_no_wildcard_resources(aws, tf_outputs):
    """Least privilege as an executable assertion, not a review comment."""
    iam = aws("iam")
    role_name = tf_outputs["processor_role_name"]

    checked = 0
    for policy_name, document in _role_policy_documents(iam, role_name):
        for statement in document["Statement"]:
            resources = statement["Resource"]
            if isinstance(resources, str):
                resources = [resources]
            assert "*" not in resources, (
                f"policy {policy_name} grants a wildcard resource on "
                f"actions {statement.get('Action')}"
            )
            checked += 1

    assert checked > 0, f"no inline policies found on role {role_name}"


def test_processor_log_group_has_finite_retention(aws, tf_outputs):
    logs = aws("logs")
    name = f"/aws/lambda/{tf_outputs['processor_function_name']}"
    groups = logs.describe_log_groups(logGroupNamePrefix=name)["logGroups"]
    match = next(g for g in groups if g["logGroupName"] == name)
    assert match.get("retentionInDays"), "log group retains logs forever"
