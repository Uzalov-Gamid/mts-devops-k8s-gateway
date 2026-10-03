.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help kind-up kind-down deploy verify teardown lint render

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n",$$1,$$2}'

kind-up: ## Create a local kind cluster (alternative to kubeadm, for quick checks)
	kind create cluster --name mts --config cluster/kind/kind.yaml

kind-down: ## Delete the kind cluster
	kind delete cluster --name mts

deploy: ## Deploy Gateway API, app, Prometheus and Filebeat into the current cluster
	./scripts/deploy.sh

verify: ## Run end-to-end checks
	./scripts/verify.sh

teardown: ## Remove everything installed by deploy
	./scripts/teardown.sh

render: ## Render all kustomizations to stdout
	@for d in app gateway monitoring logging; do kubectl kustomize deploy/$$d; echo '---'; done

lint: ## Offline validation: shellcheck + kubeconform on rendered manifests
	shellcheck scripts/*.sh cluster/kubeadm/*.sh
	$(MAKE) -s render | kubeconform -strict -summary -ignore-missing-schemas -
