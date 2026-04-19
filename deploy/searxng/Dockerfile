# Custom SearXNG image for The Stacks.
#
# Bakes the curated settings.yml into `/etc/searxng/settings.yml` so the
# first boot of the container sees the 5-engine config instead of the
# upstream default (hundreds of engines, OOM-kills a 256/512MB VM in the
# first 3 seconds).
#
# Build context: `deploy/` (Fly uses the directory containing fly.toml
# as the build context by default; our fly.searxng.toml lives at
# deploy/fly.searxng.toml). The rendered settings file is therefore
# referenced as `searxng/settings.rendered.yml` — path is relative to
# the build context, NOT to this Dockerfile's own directory.
# scripts/deploy-stack.sh writes it via sed at deploy time; the rendered
# copy is gitignored and cleaned up after the deploy.
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
# scripts/deploy-stack.sh; see deploy/searxng/.gitignore. Path is
# relative to the Fly build context (`deploy/`), so we prefix with the
# subdirectory name.
COPY searxng/settings.rendered.yml /etc/searxng/settings.yml
