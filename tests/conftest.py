import functools
import json
import os
import subprocess

import boto3
import pytest


@pytest.fixture(scope="session")
def tf_outputs():
    """Terraform outputs for the currently applied stack."""
    result = subprocess.run(
        ["terraform", "-chdir=infra", "output", "-json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return {k: v["value"] for k, v in json.loads(result.stdout).items()}


@pytest.fixture(scope="session")
def aws():
    """boto3 client factory.

    Honours AWS_ENDPOINT_URL, so this suite runs unchanged against LocalStack
    or against real AWS. Unset means real AWS.
    """
    endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
    session = boto3.Session(region_name=os.environ.get("AWS_REGION", "us-east-1"))

    @functools.lru_cache(maxsize=None)
    def client(service_name):
        return session.client(service_name, endpoint_url=endpoint)

    return client
