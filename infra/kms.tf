data "aws_caller_identity" "current" {}

# One customer-managed key for the whole stack: the ingest bucket, the receipts
# table, the dead-letter queue and the Lambda's log group all encrypt under it.
# A key per resource would buy independent rotation and revocation between
# components that share a single trust boundary and a single lifetime, which
# this stack does not need.
#
# The Lambda's environment block is the one thing not on that list. See the
# CKV_AWS_173 justification in modules/processor-lambda/main.tf for why
# `kms_key_arn` was implemented, applied, and then withdrawn.
data "aws_iam_policy_document" "stack_key" {
  #checkov:skip=CKV_AWS_356:A KMS key policy is already scoped by the key it is attached to, and the KMS API rejects any Resource other than "*" -- there, "*" means "this key" and nothing else. These three checks read the document as an identity policy, where "*" would mean every resource in the account. The narrowing that does exist is in the second statement's ArnLike condition on kms:EncryptionContext, and in the caller-side grant in modules/processor-lambda, which is scoped to this key ARN.
  #checkov:skip=CKV_AWS_111:See CKV_AWS_356 above. The account-root statement is not optional either: KMS refuses a key policy that leaves no principal able to administer the key, and this statement is what lets IAM policies govern use of it at all. It is AWS's own documented default key policy, unmodified.
  #checkov:skip=CKV_AWS_109:See CKV_AWS_356 above.

  # Without this the key is unmanageable: KMS refuses a key policy that leaves
  # no principal able to administer it, and IAM policies cannot grant access to
  # a key whose own policy does not delegate to the account.
  statement {
    sid       = "EnableAccountIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # CloudWatch Logs encrypts through the service principal, not through the
  # caller's role, so it needs its own grant. Scoped by encryption context to
  # log groups in this account and region -- the key cannot be used to decrypt
  # some other account's logs.
  statement {
    sid = "AllowCloudWatchLogs"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "stack" {
  description             = "${var.project_name} stack encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.stack_key.json
}

resource "aws_kms_alias" "stack" {
  name          = "alias/${var.project_name}"
  target_key_id = aws_kms_key.stack.key_id
}
