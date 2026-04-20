# Log shipper image for The Stacks.
#
# Runs Vector directly against Fly's org-wide NATS log broadcast and
# forwards to Axiom, scrubbing PII on the way. The full pipeline is in
# vector.toml (source + transform + sink) and fits in one file.
#
# Build context: `deploy/log-shipper/` (scripts/deploy-stack.sh cd's
# into this directory before invoking `fly deploy`, so Fly's remote
# builder treats CWD as the context and the COPY below is relative to
# THIS directory). See the matching comment in deploy/searxng/Dockerfile
# for the empirical evidence that CWD beats --config's directory for
# context resolution.
#
# Why not `ghcr.io/superfly/fly-log-shipper`?
# That image's entrypoint script auto-generates
# `/etc/vector/sinks/axiom.toml` at container startup when AXIOM_TOKEN
# + AXIOM_DATASET are present. Vector then loads both the generated
# sink AND our `/etc/vector/vector.toml`, hits `duplicate sink id
# found: axiom`, and refuses to start (verified 2026-04-19: log-shipper
# crash-looped until Fly suspended it). We could skip declaring the
# sink in our vector.toml and let the base generate it, but the base's
# sink reads directly from the raw NATS source and bypasses our
# PII-scrub transform — which defeats the whole point. Using Vector's
# upstream image avoids the double-wiring; NATS basic-auth in the URL
# is enough for Fly's broadcast so we don't need fly-log-shipper's
# auth machinery.

# hadolint ignore=DL3007
FROM timberio/vector:latest-debian

COPY vector.toml /etc/vector/vector.toml
