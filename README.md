# Kubernetes + Gateway API + Prometheus + Filebeat (DevOps-кейс МТС)

![ci](https://github.com/Uzalov-Gamid/mts-devops-k8s-gateway/actions/workflows/ci.yml/badge.svg)

Демонстрационное веб-приложение (nginx) в Kubernetes. Доступ снаружи через **Kubernetes Gateway API**
(реализация **Envoy Gateway**), метрики собирает **Prometheus**, логи приложения собирает **Filebeat**
и складывает в **Elasticsearch**. Развёртывание одной командой `make deploy`, повторный запуск безопасен.

## Архитектура

```text
                        ┌────────────────────────── Kubernetes (kubeadm, 1 нода) ───────────────────────────┐
                        │                                                                                    │
 curl ──► NodePort 30080 ─► Envoy proxy ◄── Gateway "demo" + HTTPRoute (/, /v1, /v2, /canary, host v2.*)    │
        (HTTPS: 30443)  │   (data plane)        ▲ управляет Envoy Gateway (control plane)                  │
                        │        │                                                                         │
                        │        ├──► Service app-v1 ──► nginx v1 (2 pod) ─┐ stdout: JSON access log          │
                        │        └──► Service app-v2 ──► nginx v2 (2 pod) ─┤ sidecar: nginx-exporter :9113     │
                        │                                                   │                               │
                        │  Prometheus ── scrape ─► nginx-exporter, Envoy proxy, Envoy Gateway, cAdvisor     │
                        │  Filebeat (DaemonSet) ── /var/log/containers ──► Elasticsearch (индекс demo-logs-*)│
                        └────────────────────────────────────────────────────────────────────────────────────┘
```

| Компонент | Реализация | Версия |
|---|---|---|
| Kubernetes | kubeadm (pkgs.k8s.io) | **1.35** (`K8S_MINOR`, меняется переменной) |
| CNI | Flannel | v0.27.4 |
| Container runtime | containerd (Ubuntu 24.04) | из репозитория Ubuntu |
| Gateway API | **Envoy Gateway** (Helm chart `oci://docker.io/envoyproxy/gateway-helm`) | **v1.9.1**, CRD Gateway API v1.6.1 (standard channel) |
| Приложение | `nginxinc/nginx-unprivileged` | 1.30-alpine |
| Метрики приложения | `nginx/nginx-prometheus-exporter` (sidecar) | 1.5.3 |
| Мониторинг | Prometheus (манифесты Kustomize) | v3.13.4 |
| Логирование | **Filebeat** → Elasticsearch | 9.4.7 |
| Автоматизация | Bash, Kustomize, Helm, Makefile, GitHub Actions | helm 3, kubectl ≥ 1.35 |

Используемые ресурсы Gateway API: `GatewayClass` (`envoy`), `Gateway` (`demo`, listeners HTTP:80 и HTTPS:443),
`HTTPRoute` ×4 (`hello`, `by-path`, `canary`, `by-host`). Параметры data plane (NodePort 30080/30443) заданы
через `EnvoyProxy` (CRD Envoy Gateway), на него ссылается `GatewayClass.parametersRef`.

## Требования к среде

- Ubuntu 24.04 (на ней проверялся деплой в CI, см. `docs/test-report.md`), 2+ CPU, 6+ ГБ RAM, 20 ГБ диска, доступ в интернет
  (pkgs.k8s.io, docker.io, docker.elastic.co, raw.githubusercontent.com).
- Права sudo для установки кластера. Для самого `make deploy` права root не нужны.
- Инструменты: `kubectl`, `helm`, `openssl`, `curl`, `jq`, `make`. `kubectl` ставится вместе с kubeadm, `helm` — `cluster/kubeadm/tools.sh`.

## Развёртывание (пошагово)

```bash
git clone https://github.com/Uzalov-Gamid/mts-devops-k8s-gateway.git && cd mts-devops-k8s-gateway

# 1. Kubernetes через kubeadm (одна нода, идемпотентно)
sudo ./cluster/kubeadm/install.sh
./cluster/kubeadm/tools.sh          # helm

# 2. Всё остальное: Envoy Gateway, приложение, Gateway/HTTPRoute, Prometheus, Elasticsearch, Filebeat
make deploy

# 3. Проверка всего сразу
make verify                         # в конце: ALL CHECKS PASSED
```

Без kubeadm, для быстрой проверки (нужны Docker и kind): `make kind-up && make deploy && make verify`.
Повторный `make deploy` ничего не ломает: используются `helm upgrade --install`, `kubectl apply`, а TLS-секрет
создаётся только если его нет. Удаление: `make teardown`.

## Как проверить

### Gateway API

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')   # для kind: 127.0.0.1 и порт 8080
curl http://$NODE:30080/                              # Hello World!
curl http://$NODE:30080/v2                            # Hello World! (v2)        (маршрут по пути)
curl -H 'Host: v2.demo.local' http://$NODE:30080/     # Hello World! (v2)        (маршрут по hostname)
for i in $(seq 20); do curl -s http://$NODE:30080/canary; done | sort | uniq -c   # разделение трафика 80/20
curl -k https://$NODE:30443/                          # Hello World!             (TLS на Gateway)
kubectl -n demo get gateway,httproute                 # Programmed / Accepted
```

### Мониторинг

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090 &
# Targets: http://localhost:9090/targets  (prometheus, nginx, envoy-gateway, envoy-proxy, cadvisor — UP)
curl -s 'localhost:9090/api/v1/query?query=sum(nginx_http_requests_total)'                       # запросы к nginx
curl -s 'localhost:9090/api/v1/query?query=sum(rate(envoy_cluster_upstream_rq_xx[1m])) by (envoy_response_code_class)'   # HTTP-коды на Gateway
curl -s 'localhost:9090/api/v1/query?query=sum(rate(container_cpu_usage_seconds_total{namespace="demo"}[1m]))'           # CPU приложения
```

Собираются: метрики nginx (`nginx_up`, `nginx_http_requests_total`, `nginx_connections_*`), метрики Envoy data plane
(запросы, коды ответов, латентность `envoy_cluster_upstream_rq_time_*`), метрики control plane Envoy Gateway и
CPU/RAM контейнеров (cAdvisor). Есть recording/alert-правила (`deploy/monitoring/rules.yml`).

### Логирование

```bash
curl http://$NODE:30080/hello-from-expert
kubectl -n logging port-forward svc/elasticsearch 9200:9200 &
curl -s 'localhost:9200/demo-logs-*/_search?q=message:hello-from-expert&pretty' | head -40
```

Filebeat (DaemonSet) читает stdout/stderr контейнеров namespace `demo` (access-лог nginx в JSON, error-лог
в stderr), обогащает метаданными Kubernetes, разбирает JSON-поля в `nginx.*` и пишет в Elasticsearch,
индекс `demo-logs-YYYY.MM.DD`.

## Дополнительные возможности

Всё перечисленное проверяется автоматически в CI (`make verify`, `make chaos`, `make test-rules`, `make scan`).

- **Gateway API**: несколько маршрутов, маршрутизация по path, hostname и заголовку (`x-canary: true`), два backend,
  **traffic splitting 80/20**, **TLS termination** (самоподписанный сертификат генерируется при деплое, в git его нет),
  редирект HTTP→HTTPS (`/secure`), политики Envoy Gateway `BackendTrafficPolicy`: **rate limit** (`/limited`, 5 запросов в минуту),
  retries и timeout.
- **Устойчивость**: `make chaos` убивает pod'ы и делает rolling restart под нагрузкой через Gateway и требует 0 ошибок
  (в CI: 0 из 420 запросов). Для этого у приложения graceful shutdown (preStop), PodDisruptionBudget и 2 реплики.
- **SLO и алерты**: SLO доступности 99,9% и латентности (p95 < 250 мс) на уровне Envoy, multi-window burn-rate алерты
  (`deploy/monitoring/slo-rules.yml`), юнит-тесты правил `promtool test rules` (`make test-rules`).
- **Grafana**: дашборд «Gateway and demo app overview» (RPS, коды ответов, доля 5xx, p95, CPU/RAM) создаётся при деплое.
  Открыть: `kubectl -n monitoring port-forward svc/grafana 3000:3000` (просмотр без логина, пароль админа генерируется при деплое).
- **CI** (GitHub Actions, ubuntu-24.04): shellcheck, kubeconform, promtool (конфиг и юнит-тесты), `filebeat test config`,
  Trivy (misconfiguration, падает на HIGH/CRITICAL; отчёт по образам), затем kind-кластер, двойной `make deploy`
  (идемпотентность), `make verify` и `make chaos`.
- **Логирование**: структурированные JSON access-логи, централизованное хранение и поиск в Elasticsearch.
- **Безопасность**: pod security (non-root, `readOnlyRootFilesystem` где возможно, drop ALL capabilities, seccomp RuntimeDefault),
  лимиты ресурсов, PodDisruptionBudget, секреты не хранятся в репозитории, исключения Trivy обоснованы в `.trivyignore.yaml`.
- Отчёт о прогоне: `docs/test-report.md`, `make report` пересоздаёт его для вашего кластера.

## Известные ограничения

- Скрипт `cluster/kubeadm/install.sh` в CI не запускается (нужна полноценная ВМ); в CI проверен весь остальной стек на kind под ubuntu-24.04. Отчёт: `docs/test-report.md`.
- Одна нода и `emptyDir` для Prometheus/Elasticsearch: данные теряются при пересоздании pod. Для продакшна нужны PVC, реплики и ILM.
- Elasticsearch и Grafana работают с записываемой корневой ФС (см. `.trivyignore.yaml`).
- Elasticsearch без аутентификации, доступен только внутри кластера (демонстрационная конфигурация).
- Самоподписанный сертификат, `curl -k`. Для боевого TLS нужен cert-manager.
- Нет облачного балансировщика: Gateway опубликован через NodePort 30080/30443.
- Filebeat настроен на containerd-формат логов (`/var/log/containers`) только для namespace `demo`.
- Flannel не применяет NetworkPolicy; для политик нужен другой CNI (например, Calico/Cilium).

## Структура репозитория

```text
cluster/kubeadm/   установка Kubernetes на Ubuntu 24.04 (install.sh, tools.sh)
cluster/kind/      конфиг kind для быстрых проверок и CI
deploy/app/        nginx v1/v2 (Kustomize)
deploy/gateway/    Envoy Gateway values, EnvoyProxy, GatewayClass, Gateway, HTTPRoute
deploy/monitoring/ Prometheus, правила, SLO, Grafana
tests/prometheus/  юнит-тесты правил алертов
deploy/logging/    Elasticsearch, Filebeat
scripts/           deploy / verify / chaos / report / teardown
docs/passport/     паспорт решения
.github/workflows/ CI
```
