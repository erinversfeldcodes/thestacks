#!/usr/bin/env bash

_strip_ansi() {
    sed 's/\x1b\[[0-9;]*[mK]//g'
}

_parse_ci_output() {
    local output
    output="$(echo "$1" | _strip_ansi)"

    local table
    table="| Check | Status |"$'\n'"| --- | --- |"

    local name
    while IFS= read -r line; do
        case "$line" in
            PASS[[:space:]]*)
                name="${line#PASS}"
                name="${name#"${name%%[![:space:]]*}"}"
                table+=$'\n'"| ${name} | ✅ passed |"
                ;;
            FAIL[[:space:]]*)
                name="${line#FAIL}"
                name="${name#"${name%%[![:space:]]*}"}"
                table+=$'\n'"| ${name} | ❌ failed |"
                ;;
        esac
    done <<< "$output"

    echo "$table"
}

_replace_sentinel() {
    local body="$1"
    local new_section="$2"

    local body_file new_file out_file
    body_file="$(mktemp)"
    new_file="$(mktemp)"
    out_file="$(mktemp)"

    printf '%s\n' "$body"        > "$body_file"
    printf '%s\n' "$new_section" > "$new_file"

    awk -v newfile="$new_file" '
        /<!-- ci-summary-start -->/ {
            while ((getline line < newfile) > 0) print line
            close(newfile)
            skip=1; next
        }
        /<!-- ci-summary-end -->/ { skip=0; next }
        !skip                     { print }
    ' "$body_file" > "$out_file"

    cat "$out_file"
    rm -f "$body_file" "$new_file" "$out_file"
}

_replace_deployed_e2e_sentinel() {
    local body="$1"
    local new_section="$2"

    local body_file new_file out_file
    body_file="$(mktemp)"
    new_file="$(mktemp)"
    out_file="$(mktemp)"

    printf '%s\n' "$body"        > "$body_file"
    printf '%s\n' "$new_section" > "$new_file"

    awk -v newfile="$new_file" '
        /<!-- deployed-e2e-summary-start -->/ {
            while ((getline line < newfile) > 0) print line
            close(newfile)
            skip=1; next
        }
        /<!-- deployed-e2e-summary-end -->/ { skip=0; next }
        !skip                               { print }
    ' "$body_file" > "$out_file"

    cat "$out_file"
    rm -f "$body_file" "$new_file" "$out_file"
}

_get_deployed_e2e_section() {
    local repo_root="$1"

    if [[ -z "${FLY_API_TOKEN:-}" ]]; then
        cat <<'EOF'
<!-- deployed-e2e-summary-start -->
_Deployed E2E skipped — FLY_API_TOKEN not set._
<!-- deployed-e2e-summary-end -->
EOF
        return
    fi

    local tmpfile
    tmpfile="$(mktemp)"
    bash "${repo_root}/scripts/deploy-preview.sh" 2>&1 | tee /dev/tty > "$tmpfile" || true
    local deploy_output
    deploy_output="$(cat "$tmpfile")"
    rm -f "$tmpfile"

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M')"

    local table
    table="$(_parse_ci_output "$deploy_output")"

    cat <<EOF
<!-- deployed-e2e-summary-start -->
${table}

_Last deployed: ${timestamp}_
<!-- deployed-e2e-summary-end -->
EOF
}

run_ci_and_get_section() {
    local repo_root="$1"

    local runner=()
    if [[ -z "${STACKS_DEV_SHELL:-}" ]] && command -v nix &>/dev/null; then
        runner=(nix develop --command)
    fi

    local tmpfile
    tmpfile="$(mktemp)"
    ${runner[@]+"${runner[@]}"} just --justfile "$repo_root/justfile" ci 2>&1 | tee /dev/tty > "$tmpfile" || true
    local ci_output
    ci_output="$(cat "$tmpfile")"
    rm -f "$tmpfile"

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M')"

    local table
    table="$(_parse_ci_output "$ci_output")"

    cat <<EOF
<!-- ci-summary-start -->
${table}

_Last run: ${timestamp} · push \`--no-verify\` to skip_
<!-- ci-summary-end -->
EOF
}

update_pr_ci_summary() {
    local branch="$1"
    local pr_num="$2"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"

    echo "[hook] Running CI checks for PR #${pr_num} (push --no-verify to skip)..." >&2

    local ci_section
    ci_section="$(run_ci_and_get_section "$repo_root")"

    local current_body
    current_body="$(gh pr view "$pr_num" --json body --jq '.body')"

    local new_body
    new_body="$(_replace_sentinel "$current_body" "$ci_section")"

    if echo "$ci_section" | grep -v "FAIL" | grep -q "PASS" && [[ -n "${FLY_API_TOKEN:-}" ]]; then
        echo "[hook] Running deploy preview for PR #${pr_num}..." >&2
        local deployed_e2e_section
        deployed_e2e_section="$(_get_deployed_e2e_section "$repo_root")"

        if ! echo "$new_body" | grep -q "<!-- deployed-e2e-summary-start -->"; then
            new_body="${new_body}

${deployed_e2e_section}"
        else
            new_body="$(_replace_deployed_e2e_sentinel "$new_body" "$deployed_e2e_section")"
        fi
    fi

    echo "[hook] Updating PR #${pr_num} CI summary..." >&2
    gh pr edit "$pr_num" --body "$new_body"
    echo "[hook] Done." >&2

    echo "[hook] Pushing ${branch} to origin to guarantee the latest commits land..." >&2
    if git push origin "$branch" --no-verify; then
        echo "[hook] Push complete." >&2
    else
        echo "[hook] Explicit push failed — git's own push will retry (resolve any non-fast-forward manually)." >&2
    fi
}
