#!/usr/bin/env bash
set -euo pipefail

(cd frontend && npx elm-format --validate src/)
(cd frontend && npm audit)
