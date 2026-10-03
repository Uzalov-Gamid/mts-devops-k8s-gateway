#!/usr/bin/env bash
# Runs verify.sh and records the outcome in docs/test-report.md (proof of a test run).
source "$(dirname "$0")/lib.sh"
need kubectl
out="$ROOT/docs/test-report.md"; mkdir -p "$ROOT/docs"
{
  echo "# Test report"
  echo
  echo "- Date: $(date -u +%FT%TZ)"
  echo "- OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "- Kubernetes: $(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
  echo "- Envoy Gateway: ${EG_VERSION}"
  echo "- Commit: $(git -C "$ROOT" rev-parse --short HEAD)"
  echo
  echo '```text'
  "$ROOT/scripts/verify.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  echo '```'
} | tee "$out"
