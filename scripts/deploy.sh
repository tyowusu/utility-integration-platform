#!/usr/bin/env bash
#
# Deploy the switching API to CloudHub 2.0.
#
#   ./scripts/deploy.sh                        # dev
#   DEPLOY_ENV=test ./scripts/deploy.sh        # test
#
# Secrets are read from the macOS Keychain rather than typed each time or
# written to a file. Store them once with:
#
#   security add-generic-password -a "$USER" -s uip-ca-secret  -w
#   security add-generic-password -a "$USER" -s uip-env-secret -w
#   security add-generic-password -a "$USER" -s uip-secure-key -w
#
# Each prompts for the value without echoing it. To change one later, delete
# it first: security delete-generic-password -s uip-ca-secret
#
# WHY NOT STORE THESE IN THE REPOSITORY
#
#   mule.secure.key decrypts properties/<env>.secure.yaml. Committing it
#   alongside the ciphertext would mean anyone with read access holds both
#   halves, which is the whole mechanism undone.
#
#   The Connected App secret authenticates this tooling to Anypoint — it is
#   what grants permission to deploy, so it cannot live in the thing being
#   deployed.
#
#   The environment client secret is injected into the application at deploy
#   time so it can authenticate to API Manager for autodiscovery. It has to
#   come from outside the artifact by definition.
#
# In CI these come from GitHub Secrets instead — see step 11 of the go-live
# guide. This script exists so that local deployments are not a retyping
# exercise, not as a substitute for that.
#
set -euo pipefail

ORG_ID="c7586f41-62a9-40a2-9665-aa6c7d456e66"
CA_CLIENT_ID="2a584883d4d5418eb5f73adfd77cd083"

# Target environment. Each has its own API Manager instance and its own
# environment client credentials — an application bound to another
# environment's api.id will not find it, and the readiness probe reports
# "API not found in the API Platform".
ENV_NAME="${DEPLOY_ENV:-dev}"

case "${ENV_NAME}" in
  dev)
    ENV_CLIENT_ID="ebedc33c9bde4caf846e7896ed1a25ac"
    API_ID="21117824"
    ENV_SECRET_ITEM="uip-env-secret"
    SECURE_KEY_ITEM="uip-secure-key"
    ;;
  test)
    ENV_CLIENT_ID="${TEST_ENV_CLIENT_ID:?set TEST_ENV_CLIENT_ID (Access Management -> Environments -> test)}"
    API_ID="${TEST_API_ID:?set TEST_API_ID (the test API Manager instance id)}"
    ENV_SECRET_ITEM="uip-test-env-secret"
    SECURE_KEY_ITEM="uip-test-secure-key"
    ;;
  *)
    echo "Unknown environment '${ENV_NAME}'. Use dev or test." >&2
    exit 1
    ;;
esac

: "${JAVA_HOME:=/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export JAVA_HOME
export PATH="${JAVA_HOME}/bin:${PATH}"

keychain() {
  security find-generic-password -a "${USER}" -s "$1" -w 2>/dev/null || {
    echo "Missing Keychain item '$1'. Add it with:" >&2
    echo "  security add-generic-password -a \"\$USER\" -s $1 -w" >&2
    exit 1
  }
}

CA_SECRET="$(keychain uip-ca-secret)"
ENV_SECRET="$(keychain "${ENV_SECRET_ITEM}")"
SECURE_KEY="$(keychain "${SECURE_KEY_ITEM}")"

# --publish: push the artifact to Exchange first. Required whenever anything
# inside the jar changed — CloudHub 2.0 deploys from Exchange, not from a
# local file, and Exchange versions are immutable so the pom version must be
# bumped for a republish to succeed.
if [[ "${1:-}" == "--publish" ]]; then
  echo "==> Publishing to Exchange"
  mvn clean deploy -DskipTests -DskipMunitTests -Danypoint.orgId="${ORG_ID}"
fi

echo "==> Deploying to CloudHub 2.0 (${ENV_NAME})"
mvn deploy -DmuleDeploy -P"${ENV_NAME}" \
  -DskipTests -DskipMunitTests \
  -DconnectedApp.clientId="${CA_CLIENT_ID}" \
  -DconnectedApp.clientSecret="${CA_SECRET}" \
  -Danypoint.orgId="${ORG_ID}" \
  -Dmule.secure.key="${SECURE_KEY}" \
  -Dautodiscovery.clientId="${ENV_CLIENT_ID}" \
  -Dautodiscovery.clientSecret="${ENV_SECRET}" \
  -Dapi.id="${API_ID}"
