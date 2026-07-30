#!/bin/bash
# Tests for export-secrets-github. Runs the real script against test/fake-curl
# (a curl shim standing in for Vault and the GitHub OIDC endpoint), so it needs
# no network access, no credentials, and no live Vault. Asserts that:
#
#   1. a single-line secret value is masked (::add-mask::) and injected into
#      $GITHUB_ENV exactly as before, and
#   2. a multi-line secret value hard-fails the step with a clear, actionable
#      error, and is never masked or written to the environment -- because
#      GitHub's line-based log masking cannot mask multi-line values reliably.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")
script="$repo/export-secrets-github"

# Put the fake curl first on PATH so the script talks to it instead of the real
# Vault/OIDC endpoints.
shim_dir=$(mktemp -d)
trap 'rm -rf "$shim_dir"' EXIT
cp "$here/fake-curl" "$shim_dir/curl"
chmod +x "$shim_dir/curl"
export PATH="$shim_dir:$PATH"

failures=0
fail() { echo "  FAIL: $1"; failures=$((failures + 1)); }

# run_script VALUE: run the script for a secret whose value is VALUE. Sets the
# globals: rc (exit code), out (merged stdout+stderr), github_env (path to the
# file the script wrote its env exports to).
run_script() {
  local value=$1 github_output
  github_env=$(mktemp)
  github_output=$(mktemp)
  out=$(
    FAKE_SECRET_VALUE="$value" \
      VAULT_AUTH_ROLE="test_role" \
      ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.test/token?x=1" \
      ACTIONS_ID_TOKEN_REQUEST_TOKEN="fake-request-token" \
      GITHUB_ENV="$github_env" \
      GITHUB_OUTPUT="$github_output" \
      bash "$script" "vault-repo-test/MY_SECRET" 2>&1
  )
  rc=$?
}

echo "test: single-line value is masked and injected"
run_script "single-line-value"
[[ $rc -eq 0 ]] || fail "expected exit 0, got $rc; output: $out"
grep -qF '::add-mask::single-line-value' <<<"$out" || fail "value was not masked"
grep -qF 'MY_SECRET<<' "$github_env" || fail "MY_SECRET not written to GITHUB_ENV"
grep -qxF 'single-line-value' "$github_env" || fail "value not present in GITHUB_ENV"

echo "test: multi-line value hard-fails and is never masked or injected"
run_script $'line one\nline two'
[[ $rc -ne 0 ]] || fail "expected nonzero exit for multi-line value, got 0"
grep -qF '::error::' <<<"$out" || fail "no ::error:: annotation emitted"
grep -qiF 'cannot be masked' <<<"$out" || fail "error did not explain the masking limitation"
grep -qiF 'base64' <<<"$out" || fail "error did not point to the base64 workaround"
grep -qF '::add-mask::line one' <<<"$out" && fail "multi-line value was masked (leak risk)"
grep -qF 'MY_SECRET<<' "$github_env" && fail "multi-line value was written to GITHUB_ENV"

if [[ $failures -eq 0 ]]; then
  echo "All tests passed."
else
  echo "$failures assertion(s) failed."
  exit 1
fi
