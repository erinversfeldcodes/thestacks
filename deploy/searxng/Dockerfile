# Custom SearXNG image for The Stacks.
#
# Bakes the curated settings.yml into `/etc/searxng/settings.yml` so the
# first boot of the container sees the 5-engine config instead of the
# upstream default (hundreds of engines, OOM-kills a 256/512MB VM in the
# first 3 seconds).
#
# Build context: `deploy/searxng/` (scripts/deploy-stack.sh cd's into
# this directory before invoking `fly deploy`, so Fly's remote builder
# treats CWD as the context and COPY paths below are relative to THIS
# directory).
#
# Empirically verified 2026-04-19: running `fly deploy --config <abs>`
# from the repo root collapses the build context to a 2-byte payload
# (the root .dockerignore filters almost everything out) and the COPY
# fails with `"settings.rendered.yml": not found`. Running from within
# deploy/searxng/ yields a ~2 kB context containing exactly what we
# need. CWD wins over --config's directory for Fly's context
# resolution.
#
# The rendered settings file is written by sed at deploy time and
# cleaned up after; see deploy/searxng/.gitignore.
#
# Why not a volume + post-deploy SFTP?
# The previous approach mounted an empty `searxng_settings` volume, ran
# `fly deploy` (SearXNG booted with no settings → OOM crash loop), then
# SFTP'd settings into the running machine. By the time the file landed,
# Fly had already suspended the app after N failed restarts. Baking the
# config into the image moves the settings into the first boot, where
# they belong.

# Track upstream's rolling `latest` tag intentionally. SearXNG publishes
# date-stamped tags on an irregular cadence and we want the security-
# patched build each deploy without tag-curation overhead. The risk of a
# breaking upstream change is bounded by this repo's 5-engine keep_only
# config — `settings.rendered.yml` below — which SearXNG has kept stable.
# hadolint ignore=DL3007
FROM searxng/searxng:latest

# `settings.rendered.yml` is generated at deploy time by
# scripts/deploy-stack.sh and sits in the same directory as this
# Dockerfile. Path is relative to the build context (this directory —
# see top comment), hence the bare basename.
COPY settings.rendered.yml /etc/searxng/settings.yml
