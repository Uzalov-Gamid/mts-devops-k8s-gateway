# Test report

Recorded from GitHub Actions run [37112039170](https://github.com/Uzalov-Gamid/mts-devops-k8s-gateway/actions/runs/37112039170)
(commit `448abaf`, 2026-10-03, runner `ubuntu-24.04`, kind cluster, Envoy Gateway v1.9.1).

Sequence in the `e2e` job: create kind cluster → `make deploy` → `make deploy` again (idempotency) → `make verify`. All steps succeeded.

```text
PASS Gateway demo is Programmed
PASS HTTPRoute hello / by-path / canary / by-host accepted
PASS GET /          -> Hello World!
PASS GET /v1        -> Hello World!
PASS GET /v2        -> Hello World! (v2)
PASS Host v2.demo.local -> v2
PASS HTTPS (TLS terminated at the Gateway)
PASS traffic split /canary: 20/100 requests reached v2 (target ~20)
PASS targets UP: prometheus, nginx, envoy-gateway, envoy-proxy, cadvisor
PASS query sum(nginx_http_requests_total) = 63
PASS query sum(envoy_cluster_upstream_rq_total) = 4
PASS access-log entry for /verify-1791018642 found in Elasticsearch index demo-logs-*
ALL CHECKS PASSED
```

Sample document stored in Elasticsearch (Filebeat → `demo-logs-*`):

```json
{"kubernetes":{"pod":{"name":"app-v1-b645b575d-fkfn9"}},"nginx":{"method":"GET","host":"127.0.0.1","uri":"/verify-1791018642","status":200,"bytes":13,"user_agent":"curl/8.5.0","request_time":0}}
```

## Scope of this test

- Covered: all manifests, Gateway API routing, Prometheus targets and queries, Filebeat → Elasticsearch, idempotent redeploy, on Ubuntu 24.04 with kind.
- Not covered by CI: `cluster/kubeadm/install.sh` (needs a full VM). Run it on a clean Ubuntu 24.04 host and then `make deploy && make verify`; `make report` rewrites this file with that run's output.
