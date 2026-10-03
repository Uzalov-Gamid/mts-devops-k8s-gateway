# Test report

Recorded from GitHub Actions run [37115754226](https://github.com/Uzalov-Gamid/mts-devops-k8s-gateway/actions/runs/37115754226)
(commit `99b3df3` on `main`, 2026-10-03, runner `ubuntu-24.04`, kind cluster, Envoy Gateway v1.9.1).

Jobs: `lint` (shellcheck, kubeconform, Trivy, promtool config and unit tests, `filebeat test config`) and `e2e`
(kind cluster → `make deploy` → `make deploy` again for idempotency → `make verify` → `make chaos`). Everything succeeded.

`make verify` result (every check prints `PASS`, the run ends with `ALL CHECKS PASSED`):

```text
Gateway API: Gateway Programmed; HTTPRoutes hello, by-path, canary, by-host accepted
  GET /  -> Hello World!        GET /v1 -> Hello World!        GET /v2 -> Hello World! (v2)
  Host v2.demo.local -> v2      HTTPS (TLS terminated at the Gateway)
  header x-canary: true -> v2   GET /secure -> 301 redirect to HTTPS
  rate limit on /limited: requests answered 429 once the limit is hit; BackendTrafficPolicies accepted
  traffic split /canary: ~20/100 requests reached v2 (target ~20)
Prometheus: targets UP: prometheus, nginx, envoy-gateway, envoy-proxy, cadvisor
  query sum(nginx_http_requests_total) = 119
  query sum(envoy_cluster_upstream_rq_total) = 5
  SLO recording rule slo:http_requests:rate5m evaluated; Envoy latency histogram and status-class series present
Grafana: healthy; dashboard 'Gateway and demo app overview' provisioned; datasource queries Prometheus
Logging: access-log entry for /verify-1791022700 found in Elasticsearch index demo-logs-*
```

Sample document stored in Elasticsearch (Filebeat → `demo-logs-*`):

```json
{"kubernetes":{"pod":{"name":"app-v1-5bf8f59976-vxflc"}},"nginx":{"method":"GET","uri":"/verify-1791022700","status":200,"bytes":13,"host":"127.0.0.1","user_agent":"curl/8.5.0"}}
```

`make chaos` result: `CHAOS TEST PASSED: 0 of 424 requests failed` (three pod kills and a rolling restart under load).

## Scope of this test

- Covered: all manifests, Gateway API routing and policies, Prometheus targets, queries and SLO rules, Grafana, Filebeat → Elasticsearch, idempotent redeploy, pod-failure resilience, on Ubuntu 24.04 with kind.
- Not covered by CI: `cluster/kubeadm/install.sh` (needs a full VM). It was run by hand on a clean Ubuntu 24.04.5 VM (4 vCPU / 8 GB, Selectel): Kubernetes v1.35.9, node Ready in about 20 s, then `make deploy`, `make verify` (ALL CHECKS PASSED) and `make chaos` (0 of 347 requests failed) all passed; screenshots are in `docs/screenshots/`. `make report` rewrites this file with a run's output.
