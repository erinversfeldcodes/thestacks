# Public Grafana image (ADR-021 / Epic #249 #254). Bakes the file-provisioning +
# dashboards-as-code into the image so the prod Grafana is stateless and immutable
# — no API token, no manual import (unlike fly-metrics.net). Build context is the
# repo root (deploy-stack.sh runs `fly deploy` from there).
# checkov:skip=CKV_DOCKER_3: upstream grafana image runs as the non-root `grafana` user (uid 472)
# checkov:skip=CKV_DOCKER_2: liveness owned by Fly [[checks]] (fly.grafana.toml), not Docker HEALTHCHECK
FROM grafana/grafana:11.1.0

# Datasource (→ 6PN VictoriaMetrics) + dashboard provider.
COPY deploy/grafana/provisioning /etc/grafana/provisioning

# The 6 dashboards the app ships (Core.PromEx.dashboards/0), loaded by the
# file provider above.
COPY apps/core/priv/grafana /var/lib/grafana/dashboards
