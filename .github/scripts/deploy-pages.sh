#!/usr/bin/env bash
set -euo pipefail

if [[ ! "$ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo '::error::Pages upload did not return a valid artifact ID.'
  exit 1
fi

# The deploy action uses a separate artifact listing service that can miss uploads visible in REST.
repository="repos/$GITHUB_REPOSITORY"
artifact=''
for attempt in {1..6}; do
  if artifact=$(timeout 8s gh api --method GET \
    "$repository/actions/runs/$GITHUB_RUN_ID/artifacts" -f "name=$ARTIFACT_NAME" \
    --jq ".artifacts[] | select(.id == $ARTIFACT_ID and .expired == false) | .id") \
    && [[ "$artifact" == "$ARTIFACT_ID" ]]; then
    break
  fi
  if [[ "$attempt" -eq 6 ]]; then
    echo "::error::Artifact $ARTIFACT_ID is unavailable for this run."
    exit 1
  fi
  sleep 5
done

deployments="$repository/pages/deployments"
oidc_token=$(timeout 25s curl --fail --silent --show-error --retry 2 --max-time 10 \
  -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL" | jq -er '.value | select(type == "string" and length > 0)')
echo "::add-mask::$oidc_token"

# An old run can be manually rerun after a newer commit has already published.
branch_head=$(timeout 10s gh api "$repository/git/ref/heads/master" --jq .object.sha)
if [[ "$branch_head" != "$GITHUB_SHA" ]]; then
  echo "::notice::Skipping superseded commit $GITHUB_SHA."
  exit 0
fi

echo "Deploying artifact $ARTIFACT_ID from commit $GITHUB_SHA."
deployment_id=$(printf '%s' "$oidc_token" \
  | jq -Rs --argjson artifact "$ARTIFACT_ID" --arg commit "$GITHUB_SHA" \
    '{artifact_id: $artifact, pages_build_version: $commit, oidc_token: .}' \
  | timeout 20s gh api --method POST "$deployments" --input - \
  | jq -er '(.id // (.status_url | split("/") | last)) | tostring | select(test("^[A-Za-z0-9_-]+$"))')
unset oidc_token

# Cancel only this deployment if the workflow is interrupted or times out.
trap 'timeout 8s gh api --silent --method POST "$deployments/$deployment_id/cancel" || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
deadline=$((SECONDS + 240))
delay=5
while (( SECONDS < deadline )); do
  if status=$(timeout 10s gh api "$deployments/$deployment_id" --jq .status); then
    echo "Pages deployment $deployment_id: $status"
    case "$status" in
      succeed)
        trap - EXIT
        exit 0
        ;;
      deployment_failed|deployment_content_failed|deployment_perms_error|deployment_cancelled|deployment_lost)
        trap - EXIT
        echo "::error::Pages deployment ended with $status."
        exit 1
        ;;
    esac
  fi
  sleep "$delay"
  delay=$((delay < 15 ? delay + 5 : 15))
done
echo "::error::Timed out waiting for Pages deployment $deployment_id."
exit 1
