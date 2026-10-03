.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: scan chaos test-rules passport report help kind-up kind-down deploy verify teardown lint render

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

report: ## Run verify and write docs/test-report.md
	./scripts/report.sh

passport: ## Rebuild docs/passport/Паспорт.pdf
	python3 docs/passport/build.py

test-rules: ## Unit-test Prometheus alert rules with promtool (needs Docker)
	docker run --rm --entrypoint promtool -v $(CURDIR):/w -w /w/tests/prometheus prom/prometheus:v3.13.4 test rules slo-rules_test.yml

chaos: ## Kill pods under load and expect zero failed requests
	./scripts/chaos.sh

scan: ## Trivy misconfiguration scan of deploy/ (HIGH,CRITICAL fail; needs Docker)
	docker run --rm -v $(CURDIR):/w -w /w aquasec/trivy:latest config --severity HIGH,CRITICAL --ignorefile .trivyignore.yaml --exit-code 1 deploy
