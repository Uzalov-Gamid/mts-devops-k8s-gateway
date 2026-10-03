#!/usr/bin/env bash
# End-to-end checks: Gateway API routing, Prometheus targets/queries, Filebeat -> Elasticsearch.
source "$(dirname "$0")/lib.sh"
need kubectl curl jq
cluster_reachable
FAILED=0
HTTP="$(gateway_http_url)"; HTTPS="$(gateway_https_url)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

retry() { # retry <seconds> <cmd...>
  local deadline=$((SECONDS + $1)); shift
  until "$@"; do (( SECONDS < deadline )) || return 1; sleep 3; done
}

log "Gateway API (${HTTP})"
kubectl -n demo get gateway demo -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' | grep -q True \
  && ok "Gateway demo is Programmed" || fail "Gateway demo is not Programmed"
for r in hello by-path canary by-host; do
  kubectl -n demo get httproute "$r" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' | grep -q True \
    && ok "HTTPRoute $r accepted" || fail "HTTPRoute $r not accepted"
done

body() { curl -fsS --max-time 10 "$@"; }
retry 120 body "$HTTP/" >/dev/null || fail "gateway did not answer on $HTTP/"
[[ "$(body "$HTTP/")" == "Hello World!" ]]               && ok "GET /          -> Hello World!"      || fail "GET / unexpected body"
[[ "$(body "$HTTP/v1")" == "Hello World!" ]]             && ok "GET /v1        -> Hello World!"      || fail "GET /v1"
[[ "$(body "$HTTP/v2")" == "Hello World! (v2)" ]]        && ok "GET /v2        -> Hello World! (v2)" || fail "GET /v2"
[[ "$(body -H 'Host: v2.demo.local' "$HTTP/")" == "Hello World! (v2)" ]] \
                                                         && ok "Host v2.demo.local -> v2"            || fail "hostname routing"
[[ "$(body -k "$HTTPS/")" == "Hello World!" ]]            && ok "HTTPS (TLS terminated at the Gateway)" || fail "HTTPS listener"
[[ "$(body -H 'x-canary: true' "$HTTP/")" == "Hello World! (v2)" ]] && ok "header x-canary: true -> v2"  || fail "header-based routing"
loc="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "$HTTP/secure")"
[[ "$loc" == 301\ https://* ]] && ok "GET /secure -> 301 redirect to HTTPS ($loc)" || fail "HTTP->HTTPS redirect (got: $loc)"
limited=0; for _ in $(seq 1 12); do [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$HTTP/limited")" == 429 ]] && limited=$((limited+1)); done
(( limited > 0 )) && ok "rate limit on /limited: $limited of 12 requests answered 429" || fail "rate limit did not trigger on /limited"
kubectl -n demo get backendtrafficpolicy -o jsonpath='{range .items[*]}{.metadata.name}={.status.ancestors[0].conditions[?(@.type=="Accepted")].status} {end}' | grep -vq False \
  && ok "BackendTrafficPolicies accepted" || fail "a BackendTrafficPolicy was not accepted"
v2=0; for _ in $(seq 1 100); do [[ "$(body "$HTTP/canary")" == *v2* ]] && v2=$((v2+1)); done
(( v2 > 0 && v2 < 100 )) && ok "traffic split /canary: ${v2}/100 requests reached v2 (target ~20)" || fail "canary split: ${v2}/100 reached v2"

log "Prometheus"
kubectl -n monitoring port-forward svc/prometheus 19090:9090 >/dev/null 2>&1 & PIDS+=($!)
prom() { curl -fsS --max-time 10 "http://127.0.0.1:19090$1"; }
retry 60 prom /-/ready >/dev/null || fail "Prometheus not reachable"
targets_up() {
  prom /api/v1/targets | jq -e '[.data.activeTargets[] | select(.health=="up") | .labels.job] | unique
    | (index("prometheus") and index("nginx") and index("envoy-gateway") and index("envoy-proxy") and index("cadvisor"))' >/dev/null
}
retry 120 targets_up && ok "targets UP: prometheus, nginx, envoy-gateway, envoy-proxy, cadvisor" \
  || { fail "some targets are not UP:"; prom /api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health) \(.lastError)"'; }
q() { prom "/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -r '.data.result[0].value[1] // empty'; }
has_requests() { local v; v="$(q 'sum(nginx_http_requests_total)')"; [[ -n "$v" ]] && awk "BEGIN{exit !($v>0)}"; }
retry 90 has_requests && ok "query sum(nginx_http_requests_total) = $(q 'sum(nginx_http_requests_total)')" || fail "nginx_http_requests_total missing"
has_envoy() { [[ -n "$(q 'sum(envoy_cluster_upstream_rq_total)')" ]]; }
retry 90 has_envoy && ok "query sum(envoy_cluster_upstream_rq_total) = $(q 'sum(envoy_cluster_upstream_rq_total)')" || fail "envoy_cluster_upstream_rq_total missing"

has_slo() { [[ -n "$(q 'slo:http_requests:rate5m')" ]]; }
retry 120 has_slo && ok "SLO recording rule slo:http_requests:rate5m is evaluated" || fail "SLO recording rules produce no data"
has_hist() { [[ -n "$(q 'sum(envoy_cluster_upstream_rq_time_bucket)')" ]]; }
retry 60 has_hist && ok "latency histogram envoy_cluster_upstream_rq_time_bucket present" || fail "Envoy latency histogram missing"
has_5xx() { [[ -n "$(q 'sum(envoy_cluster_upstream_rq_xx{envoy_response_code_class="2"})')" ]]; }
retry 60 has_5xx && ok "response-code series envoy_cluster_upstream_rq_xx present" || fail "Envoy response-code series missing"

log "Grafana"
kubectl -n monitoring port-forward svc/grafana 13000:3000 >/dev/null 2>&1 & PIDS+=($!)
graf() { curl -fsS --max-time 10 "http://127.0.0.1:13000$1"; }
retry 60 graf /api/health >/dev/null && ok "Grafana is healthy" || fail "Grafana not reachable"
dash_ok() { graf '/api/search?query=Gateway' | jq -e 'map(select(.uid=="gateway-overview"))|length==1' >/dev/null; }
retry 60 dash_ok && ok "dashboard 'Gateway and demo app overview' is provisioned" || fail "Grafana dashboard missing"
ds_ok() { graf /api/datasources/proxy/uid/prom/api/v1/query?query=up | jq -e '.status=="success"' >/dev/null; }
if retry 60 ds_ok; then ok "Grafana queries Prometheus through the provisioned datasource"; else
  fail "Grafana datasource cannot reach Prometheus"
  graf /api/datasources || true
  kubectl -n monitoring logs deploy/grafana --tail=30 || true
fi

log "Logging (Filebeat -> Elasticsearch)"
marker="verify-$(date +%s)"
body "$HTTP/$marker" >/dev/null
kubectl -n logging port-forward svc/elasticsearch 19200:9200 >/dev/null 2>&1 & PIDS+=($!)
es_hit() {
  curl -fsS --max-time 10 "http://127.0.0.1:19200/demo-logs-*/_search" -H 'content-type: application/json' \
    -d "{\"size\":1,\"query\":{\"match_phrase\":{\"message\":\"/$marker\"}}}" \
    | jq -e '.hits.total.value > 0' >/dev/null
}
if retry 120 es_hit; then
  ok "access-log entry for /$marker found in Elasticsearch index demo-logs-*"
  curl -fsS "http://127.0.0.1:19200/demo-logs-*/_search" -H 'content-type: application/json' \
    -d "{\"size\":1,\"query\":{\"match_phrase\":{\"message\":\"/$marker\"}},\"_source\":[\"nginx\",\"kubernetes.pod.name\"]}" \
    | jq -c '.hits.hits[0]._source'
else
  fail "no log entry for /$marker in Elasticsearch"
fi

echo
if (( FAILED )); then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"
