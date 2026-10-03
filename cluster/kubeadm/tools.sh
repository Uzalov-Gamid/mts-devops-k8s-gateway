#!/usr/bin/env bash
# Installs the client tools needed to run the deployment: helm (kubectl comes with kubeadm).
set -euo pipefail
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short
