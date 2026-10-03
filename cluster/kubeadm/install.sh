#!/usr/bin/env bash
# Single-node Kubernetes cluster with kubeadm on Ubuntu 24.04.
# Idempotent: safe to re-run; already-initialised nodes are left untouched.
# Usage: sudo ./cluster/kubeadm/install.sh
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-1.35}"
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.27.4}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }
. /etc/os-release
[[ "${ID}-${VERSION_ID}" == "ubuntu-24.04" ]] || echo "WARNING: tested on Ubuntu 24.04 only (found ${PRETTY_NAME})"

log "Kernel prerequisites (swap off, br_netfilter, ip_forward)"
swapoff -a
sed -ri '/\sswap\s/s/^/#/' /etc/fstab
cat >/etc/modules-load.d/k8s.conf <<MODS
overlay
br_netfilter
MODS
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-k8s.conf <<SYS
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
sysctl --system >/dev/null

log "Installing containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd jq
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

log "Installing kubeadm/kubelet/kubectl ${K8S_MINOR} from pkgs.k8s.io"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  log "kubeadm init"
  kubeadm init --pod-network-cidr="${POD_CIDR}"
else
  log "Cluster already initialised, skipping kubeadm init"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

log "Installing CNI (flannel ${FLANNEL_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml"

log "Single node: allow workloads on the control plane"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

log "Waiting for the node to become Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

# Hand the kubeconfig to the invoking user so that make/helm/kubectl work without sudo.
if [[ -n "${SUDO_USER:-}" ]]; then
  home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  install -d -o "$SUDO_USER" -g "$SUDO_USER" "$home/.kube"
  install -m 0600 -o "$SUDO_USER" -g "$SUDO_USER" /etc/kubernetes/admin.conf "$home/.kube/config"
  log "kubeconfig copied to $home/.kube/config"
fi

log "Installing client tools (helm)"
"$(dirname "$(readlink -f "$0")")/tools.sh"

kubectl get nodes -o wide
