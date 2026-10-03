#!/usr/bin/env bash
# Shared helpers for deploy.sh / verify.sh / teardown.sh
set -euo pipefail

EG_VERSION="${EG_VERSION:-v1.9.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=1; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

need() {
  for c in "$@"; do command -v "$c" >/dev/null || die "'$c' is required but not installed"; done
}

cluster_reachable() { kubectl version >/dev/null 2>&1 || die "no reachable Kubernetes cluster (check KUBECONFIG)"; }

# Address where the Gateway NodePort (30080) can be reached from the machine running the scripts.
gateway_http_url() {
  if [[ -n "${GATEWAY_URL:-}" ]]; then echo "$GATEWAY_URL"; return; fi
  if [[ "$(kubectl config current-context)" == kind-* ]]; then
    echo "http://127.0.0.1:8080"          # published by cluster/kind/kind.yaml
  else
    echo "http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'):30080"
  fi
}
gateway_https_url() {
  if [[ -n "${GATEWAY_HTTPS_URL:-}" ]]; then echo "$GATEWAY_HTTPS_URL"; return; fi
  local u; u="$(gateway_http_url)"
  if [[ "$u" == *:8080 ]]; then echo "${u%:8080}:8443"; else echo "${u%:30080}:30443"; fi
}
