#!/usr/bin/env bash
# shellcheck disable=SC2329  # check_* functions are invoked indirectly via "check_${app}"
#
# Post-deployment smoke test.
#
# Usage: smoke-test.sh <backend|frontend>
#
# Waits for the Kubernetes Service's AWS load balancer to get a hostname, then
# polls it until the app answers correctly. A brand-new ELB can take a few
# minutes before its DNS name resolves, so failures are retried before giving up.
#
# For the frontend, EXPECTED_API_URL (optional) is checked against the built JS
# bundle. That proves REACT_APP_MOVIE_API_URL was baked in at build time, which
# a plain HTTP 200 would not catch.

set -euo pipefail

app="${1:?usage: smoke-test.sh <backend|frontend>}"
max_attempts="${SMOKE_MAX_ATTEMPTS:-30}"
sleep_seconds="${SMOKE_SLEEP_SECONDS:-10}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [smoke-test:${app}] $*"; }
fail() { echo "::error title=Smoke test failed (${app})::$*"; exit 1; }

host=""
for attempt in $(seq 1 "$max_attempts"); do
  host=$(kubectl get service "$app" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$host" ]] && break
  log "Waiting for load balancer hostname (attempt ${attempt}/${max_attempts})"
  sleep "$sleep_seconds"
done
[[ -n "$host" ]] || fail "Service '${app}' never received a load balancer hostname"

base_url="http://${host}"
log "Load balancer: ${base_url}"

check_backend() {
  local body
  body=$(curl --silent --show-error --fail --max-time 10 "${base_url}/movies") || return 1
  # The frontend depends on this exact shape: {"movies":[{"id":..,"title":..}, ...]}
  echo "$body" | jq -e '.movies | type == "array" and length > 0 and (.[0] | has("title"))' >/dev/null || {
    log "Unexpected /movies payload: ${body}"
    return 1
  }
  log "GET /movies returned $(echo "$body" | jq '.movies | length') movies"
}

check_frontend() {
  local html bundle_path
  html=$(curl --silent --show-error --fail --max-time 10 "${base_url}/") || return 1
  echo "$html" | grep -q '<div id="root">' || { log "Index page is missing the React root element"; return 1; }

  if [[ -n "${EXPECTED_API_URL:-}" ]]; then
    bundle_path=$(echo "$html" | grep -oE '/static/js/main\.[a-f0-9]+\.js' | head -n1)
    [[ -n "$bundle_path" ]] || { log "Could not find main JS bundle in index page"; return 1; }
    curl --silent --fail --max-time 10 "${base_url}${bundle_path}" | grep -qF "$EXPECTED_API_URL" || {
      log "Bundle ${bundle_path} does not reference backend ${EXPECTED_API_URL}"
      return 1
    }
    log "Bundle ${bundle_path} is wired to backend ${EXPECTED_API_URL}"
  fi
}

for attempt in $(seq 1 "$max_attempts"); do
  if "check_${app}"; then
    log "PASSED"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "url=${base_url}" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  log "Not healthy yet (attempt ${attempt}/${max_attempts}), retrying in ${sleep_seconds}s"
  sleep "$sleep_seconds"
done

fail "${base_url} did not become healthy after $((max_attempts * sleep_seconds))s"
