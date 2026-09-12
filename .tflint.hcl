# Without this block tflint loads only its bundled `terraform` ruleset, which
# knows nothing about AWS resources: every aws_* argument would pass unchecked
# while the README advertises a four-tool lint chain. `tflint --init` (run by
# the `lint` target and by CI) installs the plugin.
#
# The `lint` target points TFLINT_CONFIG_FILE at this file and runs tflint
# with --recursive. Both are necessary: recursion is what makes tflint lint
# infra/modules/*, where every AWS resource in this stack actually lives, and
# the env var is what carries this config into each of those directories --
# tflint otherwise looks for a .tflint.hcl beside the files it is linting and
# would silently fall back to the bundled ruleset again.
plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
