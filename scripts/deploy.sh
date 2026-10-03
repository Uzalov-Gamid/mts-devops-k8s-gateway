#!/usr/bin/env bash
# Deploys the whole solution into the cluster selected by KUBECONFIG. Idempotent.
source "$(dirname "$0")/lib.sh"
need kubectl helm openssl
cluster_reachable

log "1/6 Namespaces"
kubectl apply -f "$ROOT/deploy/namespace.yaml"

log "2/6 Envoy Gateway ${EG_VERSION} (Gateway API implementation + Gateway API CRDs)"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$EG_VERSION" -n envoy-gateway-system --create-namespace \
  -f "$ROOT/deploy/gateway/envoy-gateway-values.yaml" --wait --timeout 5m
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io crd/envoyproxies.gateway.envoyproxy.io --timeout=60s

log "3/6 Demo application (nginx v1 + v2)"
kubectl apply -k "$ROOT/deploy/app"

log "4/6 Self-signed TLS certificate for the HTTPS listener (generated, not stored in git)"
if ! kubectl -n demo get secret demo-tls >/dev/null 2>&1; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=demo.local" \
    -addext "subjectAltName=DNS:demo.local,DNS:v2.demo.local,DNS:localhost" \
    -keyout "$tmp/tls.key" -out "$tmp/tls.crt" 2>/dev/null
  kubectl -n demo create secret tls demo-tls --cert="$tmp/tls.crt" --key="$tmp/tls.key"
else
  echo "secret demo/demo-tls already exists"
fi

log "5/6 Gateway API resources (EnvoyProxy, GatewayClass, Gateway, HTTPRoutes)"
kubectl apply -k "$ROOT/deploy/gateway"

log "6/6 Monitoring (Prometheus) and logging (Elasticsearch + Filebeat)"
kubectl apply -k "$ROOT/deploy/monitoring"
kubectl apply -k "$ROOT/deploy/logging"

log "Waiting for everything to become ready"
kubectl -n demo rollout status deploy/app-v1 deploy/app-v2 --timeout=300s
kubectl -n demo wait --for=condition=Programmed gateway/demo --timeout=300s
kubectl -n envoy-gateway-system wait --for=condition=Available deploy --all --timeout=300s
kubectl -n monitoring rollout status deploy/prometheus --timeout=300s
kubectl -n logging rollout status statefulset/elasticsearch --timeout=600s
kubectl -n logging rollout status ds/filebeat --timeout=300s

log "Deployed. Run 'make verify' to check Gateway API, monitoring and logging."
