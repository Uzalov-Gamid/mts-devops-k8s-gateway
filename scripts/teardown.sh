#!/usr/bin/env bash
# Removes everything installed by deploy.sh (the cluster itself is left alone).
source "$(dirname "$0")/lib.sh"
need kubectl helm
cluster_reachable
kubectl delete -k "$ROOT/deploy/logging" --ignore-not-found
kubectl delete -k "$ROOT/deploy/monitoring" --ignore-not-found
kubectl delete -k "$ROOT/deploy/gateway" --ignore-not-found
kubectl delete -k "$ROOT/deploy/app" --ignore-not-found
kubectl -n demo delete secret demo-tls --ignore-not-found
helm uninstall eg -n envoy-gateway-system || true
kubectl delete -f "$ROOT/deploy/namespace.yaml" --ignore-not-found
