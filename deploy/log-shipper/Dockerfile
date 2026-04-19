# Log shipper image for The Stacks.
#
# Extends Superfly's fly-log-shipper (which bundles Vector + the NATS
# dial-in logic to subscribe to the org's log broadcast) and replaces
# the default vector.toml with our own — adding PII-scrubbing transforms
# between the source and the Axiom sink.
#
# Build context: `deploy/` (Fly uses the directory containing fly.toml
# as the build context by default; our fly.log-shipper.toml lives at
# deploy/fly.log-shipper.toml). The vector config is therefore
# referenced as `log-shipper/vector.toml` below — path is relative to
# the build context, NOT to this Dockerfile's own directory.
#
# Why not build our own from scratch off timberio/vector? The NATS auth
# flow against Fly's log broadcast is non-trivial (token exchange on
# startup, reconnect handling). fly-log-shipper's entrypoint handles it.
# We only need to override the config.

# Track upstream's rolling `latest` tag intentionally — same rationale
# as deploy/searxng/Dockerfile. Vector itself is stable, and upstream
# patches arrive via this tag.
# hadolint ignore=DL3007
FROM ghcr.io/superfly/fly-log-shipper:latest

COPY log-shipper/vector.toml /etc/vector/vector.toml
