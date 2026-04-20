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

# The upstream image ships a demo `/etc/vector/vector.yaml` that
# generates fake syslog lines (appname="BronzeGamer" etc. — Vector's
# `demo_logs` tutorial source). Vector's default CMD is
# `--config-dir /etc/vector` which loads EVERY config file in that
# directory, so the demo source runs alongside ours and spams stdout
# hard enough to push our own startup logs out of Fly's retention
# window (verified 2026-04-20). Removing it here so only our config is
# loaded — belt-and-suspenders alongside the explicit --config CMD
# below, which also narrows the loader to exactly one file.
RUN rm -f /etc/vector/vector.yaml

COPY vector.toml /etc/vector/vector.toml

# Override the default CMD (`--config-dir /etc/vector`) with an
# explicit --config pointing at our file. Prevents any future stock
# files or operator-dropped configs in /etc/vector/ from being loaded
# alongside ours without us noticing.
CMD ["--config", "/etc/vector/vector.toml"]
