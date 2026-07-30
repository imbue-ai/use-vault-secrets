# `use-vault-secrets` GitHub composite action

Authenticate to Imbue Vault from GitHub Actions and inject secrets into the job
environment. The action authenticates with a GitHub OIDC token (no static
credentials), fetches the requested secrets, writes them to `$GITHUB_ENV` for
subsequent steps, and masks their values in the logs.

This repository contains only the reusable action; it is published publicly so
it can be consumed from public repositories. Vault itself, its docs, and the
Terraform that configures roles and authorization live in the (private)
`imbue-ai/vault` repository.

The action is a thin wrapper around the
[`export-secrets-github`](export-secrets-github) script, which talks to the
Vault HTTP API directly with `curl` + `jq` (both preinstalled on GitHub-hosted
runners), so it needs no Vault CLI and downloads nothing.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # required: lets the job mint an OIDC token
      contents: read
    steps:
      - uses: imbue-ai/use-vault-secrets@main
        with:
          role: sculptor_test_gh
          secrets: |
            shared/modal/MODAL_TOKEN_ID
            shared/modal/MODAL_TOKEN_SECRET
      - run: |
          # MODAL_TOKEN_ID and MODAL_TOKEN_SECRET are now in the environment.
          ./do-something-with-modal
```

Reference the action as `@main` to always use its latest version.

## Multi-line secrets

GitHub's log masking is **line-based**: `::add-mask::` registers a single line,
and the runner only redacts that exact string where it appears verbatim. A
secret whose value spans multiple lines therefore cannot be masked reliably —
the mask command is mangled on newlines, and later step environment dumps print
the value's individual lines in plaintext — so it would leak into the job log.

To prevent that leak, **this action refuses to inject a multi-line value** and
fails the step with an error. Store such values base64-encoded so they occupy a
single line (which masks correctly), then decode them in your workflow.

For example, a GCP service-account key is multi-line JSON. Base64-encode it
before storing it as the secret's `value`:

```bash
base64 -w0 service-account.json    # GNU coreutils; on macOS use: base64 < service-account.json | tr -d '\n'
```

Then decode it in the workflow after the action injects it:

```yaml
steps:
  - uses: imbue-ai/use-vault-secrets@main
    with:
      role: my_role
      secrets: shared/gcp/GCP_SA_KEY   # value stored base64-encoded (single line)
  - run: |
      # GCP_SA_KEY is the base64 blob; decode it back to the JSON key file.
      echo "$GCP_SA_KEY" | base64 -d > "$RUNNER_TEMP/key.json"
      gcloud auth activate-service-account --key-file="$RUNNER_TEMP/key.json"
```

The base64 blob is a single line, so it is masked in the logs like any other
secret; the decoded file never appears in the log.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `role` | yes | — | Vault auth role to assume (a role on the `jwt_github_actions` backend, configured in the `imbue-ai/vault` Terraform). |
| `secrets` | yes | — | Secret paths to fetch, one per line. Each may carry an optional `@VERSION` suffix. The last path component becomes the env var name; the value is read from the secret's `value` field. |
| `export-token` | no | `false` | If `true`, also export `VAULT_TOKEN` so later steps can make their own Vault calls. |

## Outputs

| Output | Description |
|--------|-------------|
| `pinned` | Space-separated `path@version` for each fetched secret, for reproducibility. |

## Requirements

- The job must request `permissions: id-token: write`.
- The `role` must be authorized to read the requested secrets — authorization is
  configured in the `imbue-ai/vault` Terraform. The `role` is bound to the
  consuming repository, so a new repo must be added there before it can
  authenticate.
- A runner with `curl` and `jq` available (the GitHub-hosted `ubuntu-*` images
  have both).
