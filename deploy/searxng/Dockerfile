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
#
# Suppressions matching the upstream image's choices, not local omissions:
#   * CKV_DOCKER_7 — :latest is intentional (rationale above); same as the
#     hadolint DL3007 ignore.
#   * CKV_DOCKER_3 — the upstream searxng image already drops to a
#     non-root `searxng` user; checkov can't see across FROM, so it sees
#     no USER directive and flags it. Re-asserting `USER searxng` here
#     would couple us to the upstream UID/username, which is exactly the
#     kind of duplication this image is trying to avoid.
#   * CKV_DOCKER_2 — Fly's [[checks]] in fly.searxng.toml owns liveness
#     (TCP probe on the listening port); a Docker HEALTHCHECK would just
#     duplicate it inside the container with worse failure visibility.
#
# checkov:skip=CKV_DOCKER_7: rolling :latest is intentional — see comment
# checkov:skip=CKV_DOCKER_3: upstream image drops to `searxng` user
# checkov:skip=CKV_DOCKER_2: liveness owned by Fly [[checks]], not Docker HEALTHCHECK
# hadolint ignore=DL3007
FROM searxng/searxng:latest@sha256:f433294b46a93564993c4371005341e013d94aa8ea4662d8ee521cd2cccb08e8

# `settings.rendered.yml` is generated at deploy time by
# scripts/deploy-stack.sh and sits in the same directory as this
# Dockerfile. Path is relative to the build context (this directory —
# see top comment), hence the bare basename.
COPY settings.rendered.yml /etc/searxng/settings.yml
