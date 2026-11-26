#!/usr/bin/env bash
# Single source of truth for which squawk rules this repo suppresses.
#
# It lives here because the list had two copies — scripts/security-squawk.sh
# (the gate) and scripts/security-squawk-test-wrapper.sh (the fixture harness
# behind test/platform/squawk_destructive_test.sh). A suppression list in two
# places is a list that drifts: the next person to tighten the gate tightens one
# copy, the harness keeps asserting against the old policy, and the divergence
# shows up as a passing test about a rule that no longer applies.
#
# Sourced, not executed. Defines SQUAWK_EXCLUDED_RULES.

# adding-field-with-default — safe since Postgres 11 for a non-volatile default:
#   the new value is stored in the catalog and no table rewrite happens. The rule
#   predates that and fires on every one.
#
# ban-concurrent-index-creation-in-transaction — scripts/extract-migration-sql.py
#   emits a flat SQL stream and cannot carry `@disable_ddl_transaction`, so a
#   correctly written concurrent migration looks in-transaction to squawk. The
#   attribute itself is checked by scripts/lint-migrations.sh.
#
# ⚠️ `require-timeout-settings` is deliberately NOT here. It was, until
# 2026-10-16, and that exclusion was load-bearing in the wrong direction: no
# migration in this repo set a lock_timeout, nothing else checked, and the one
# gate that would have said so was switched off. Without a lock_timeout an ALTER
# wanting ACCESS EXCLUSIVE queues behind any in-flight query, and then every
# query arriving after it queues behind the ALTER — a millisecond DDL becomes an
# outage. Migrations carry the timeouts inline (`SET LOCAL` in a transaction,
# plain `SET` under `@disable_ddl_transaction`) because squawk reads the
# migration FILE: a helper call or a connection parameter emits no SQL text, so
# the gate would go blind again while still reporting green.
SQUAWK_EXCLUDED_RULES="adding-field-with-default,ban-concurrent-index-creation-in-transaction"
