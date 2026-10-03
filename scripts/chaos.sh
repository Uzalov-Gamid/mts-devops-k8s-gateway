#!/usr/bin/env bash
# Resilience test: keep sending requests through the Gateway while app pods are killed
# and the deployment is restarted. Passes only if not a single request fails.
source "$(dirname "$0")/lib.sh"
need kubectl curl jq
cluster_reachable
HTTP="$(gateway_http_url)"
RESULT="$(mktemp)"; trap 'rm -f "$RESULT"; kill "${LOAD_PID:-0}" 2>/dev/null || true' EXIT

log "Chaos test against ${HTTP}"
kubectl -n demo rollout status deploy/app-v1 --timeout=120s >/dev/null

load() { # one request every ~50 ms until the stop file appears
  local total=0 failed=0
  while [[ ! -f "$RESULT.stop" ]]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$HTTP/" || true)"
    total=$((total + 1)); [[ "$code" == "200" ]] || failed=$((failed + 1))
    sleep 0.05
  done
  echo "$total $failed" >"$RESULT"
}
rm -f "$RESULT.stop"; load & LOAD_PID=$!
sleep 3

for i in 1 2 3; do
  # skip pods that are already terminating (they stay listed during preStop/grace period)
  pod="$(kubectl -n demo get pod -l app.kubernetes.io/name=hello,app.kubernetes.io/version=v1 -o json \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)][0].metadata.name')"
  echo "  killing pod $pod ($i/3)"
  kubectl -n demo delete pod "$pod" --wait=false --ignore-not-found >/dev/null
  kubectl -n demo wait --for=delete "pod/$pod" --timeout=120s >/dev/null 2>&1 || true
  kubectl -n demo rollout status deploy/app-v1 --timeout=120s >/dev/null
  sleep 3
done
echo "  rolling restart of deploy/app-v1"
kubectl -n demo rollout restart deploy/app-v1 >/dev/null
kubectl -n demo rollout status deploy/app-v1 --timeout=180s >/dev/null
sleep 3

touch "$RESULT.stop"; wait "$LOAD_PID" || true; rm -f "$RESULT.stop"
read -r total failed <"$RESULT"
echo "  requests sent: $total, failed: $failed"
if (( total < 100 )); then die "too few requests were sent ($total), the test is not meaningful"; fi
if (( failed > 0 )); then die "$failed of $total requests failed during pod disruptions"; fi
echo "CHAOS TEST PASSED: 0 of $total requests failed"
