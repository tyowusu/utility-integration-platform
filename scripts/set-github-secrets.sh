#!/usr/bin/env bash
#
# Populate the GitHub Actions secrets the pipelines read (go-live guide
# step 11).
#
# Sensitive values are piped straight from the macOS Keychain into `gh` and
# never printed. Store them first — see scripts/deploy.sh for the
# add-generic-password commands.
#
# Requires a GitHub token with "Secrets: Read and write" on the repository.
#
set -euo pipefail

REPO="tyowusu/utility-integration-platform"

# --- values that are not secret -------------------------------------------
# Identifiers, URLs and client IDs. Kept in GitHub secrets anyway because the
# workflows read them from there, and because an org id in a public log is
# needless information for an attacker even if it is not a credential.
ORG_ID="c7586f41-62a9-40a2-9665-aa6c7d456e66"
CA_CLIENT_ID="2a584883d4d5418eb5f73adfd77cd083"
ENV_CLIENT_ID_DEV="ebedc33c9bde4caf846e7896ed1a25ac"
API_INSTANCE_ID_DEV="21117824"
API_BASE_URL_DEV="https://switching-process-api-dev-i6det0.5sc6y6-1.usa-e2.cloudhub.io"
TOKEN_URL_DEV="https://dev-y07kpoe8c074nk6q.us.auth0.com/oauth/token"

# --- test --------------------------------------------------------------
# Sourced from the environment rather than hardcoded, because unlike dev
# these are not yet fixed. Export them before running, or the test block
# below skips itself rather than writing an empty secret — an empty secret
# is worse than a missing one, because the workflow then fails at deploy
# time with an authentication error instead of an obvious "not configured".
#
#   Access Management -> Environments -> test        -> client id / secret
#   API Manager (test env) -> the API instance       -> instance id
#   Runtime Manager (test env) -> the app            -> public URL
#
ENV_CLIENT_ID_TEST="${ENV_CLIENT_ID_TEST:-}"
API_INSTANCE_ID_TEST="${API_INSTANCE_ID_TEST:-21117830}"
API_BASE_URL_TEST="${API_BASE_URL_TEST:-}"
# Same Auth0 tenant as dev today. When test gets its own audience (see
# API_AUDIENCE_TEST), this stays the same URL — the audience differs, the
# token endpoint does not.
TOKEN_URL_TEST="${TOKEN_URL_TEST:-$TOKEN_URL_DEV}"

set_plain() {
  printf '%s' "$2" | gh secret set "$1" --repo "$REPO"
  echo "  set $1"
}

set_from_keychain() {
  local name="$1" item="$2"
  if security find-generic-password -a "${USER}" -s "${item}" -w >/dev/null 2>&1; then
    security find-generic-password -a "${USER}" -s "${item}" -w \
      | tr -d '\n' | gh secret set "${name}" --repo "$REPO"
    echo "  set ${name}  (from Keychain: ${item})"
  else
    echo "  SKIP ${name} — no Keychain item '${item}'" >&2
  fi
}

echo "==> Non-secret identifiers"
set_plain ANYPOINT_ORG_ID                  "$ORG_ID"
set_plain ANYPOINT_CONNECTED_APP_CLIENT_ID "$CA_CLIENT_ID"
set_plain ANYPOINT_PLATFORM_CLIENT_ID_DEV  "$ENV_CLIENT_ID_DEV"
set_plain API_INSTANCE_ID_DEV              "$API_INSTANCE_ID_DEV"
set_plain API_BASE_URL_DEV                 "$API_BASE_URL_DEV"
set_plain TOKEN_URL_DEV                    "$TOKEN_URL_DEV"

if [[ -n "$ENV_CLIENT_ID_TEST" && -n "$API_INSTANCE_ID_TEST" && -n "$API_BASE_URL_TEST" ]]; then
  echo "==> Non-secret identifiers (test)"
  set_plain ANYPOINT_PLATFORM_CLIENT_ID_TEST "$ENV_CLIENT_ID_TEST"
  set_plain API_INSTANCE_ID_TEST             "$API_INSTANCE_ID_TEST"
  set_plain API_BASE_URL_TEST                "$API_BASE_URL_TEST"
  set_plain TOKEN_URL_TEST                   "$TOKEN_URL_TEST"
else
  echo "==> SKIP test identifiers — export ENV_CLIENT_ID_TEST, API_INSTANCE_ID_TEST and API_BASE_URL_TEST to set them" >&2
fi

echo "==> Secrets from Keychain"
set_from_keychain ANYPOINT_CONNECTED_APP_CLIENT_SECRET uip-ca-secret
set_from_keychain ANYPOINT_PLATFORM_CLIENT_SECRET_DEV  uip-env-secret
set_from_keychain MULE_SECURE_KEY_DEV                  uip-secure-key
set_from_keychain API_CLIENT_ID                        uip-qa-client-id
set_from_keychain API_CLIENT_SECRET                    uip-qa-client-secret
set_from_keychain ANYPOINT_PLATFORM_CLIENT_SECRET_TEST  uip-test-env-secret
set_from_keychain MULE_SECURE_KEY_TEST                  uip-test-secure-key
set_from_keychain GATEWAY_CLIENT_ID                     uip-gateway-client-id
set_from_keychain GATEWAY_CLIENT_SECRET                 uip-gateway-client-secret

# MUnit runs locally in Anypoint Studio against its bundled licensed runtime.
# In CI it is skipped unless MULESOFT_NEXUS_USERNAME is set, because the EE
# runtime resolves com.mulesoft.licm:licm from MuleSoft's private Nexus — a
# paid support entitlement. This key only has to be non-empty for the local
# profile's secure properties, which are plaintext throwaways.
set_plain MULE_SECURE_KEY_LOCAL "localdevkey12345"

cat <<'NOTE'

Not set, and why:

  UNAPPROVED_CLIENT_ID / _SECRET
      Step 8.4's client application with no approved contract. Create it, then:
        gh secret set UNAPPROVED_CLIENT_ID --repo REPO
      Without it the gateway suite falls back to a placeholder that is refused
      for the wrong reason — it is not a registered client at all, so the test
      passes without proving contract enforcement.

  *_PROD
      Production has no API instance, no client provider association and no
      deployment yet. cd-deploy.yml promotes dev -> test -> prod, so it will
      fail at deploy-prod until they exist. Test is deployed and its secrets
      are set above.

  MULESOFT_NEXUS_USERNAME / _PASSWORD
      A paid MuleSoft support entitlement. Absent, ci-build.yml skips MUnit
      and says so rather than failing on a 401 for a licensing artifact.
NOTE
