#!/bin/bash
# Tests for claude-statusline: what the status line shows for a given Claude Code input.
# Runs on the host (needs jq). Colors are stripped before comparing.
set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT=$PWD/container/bin/claude-statusline
pass=0; fail=0

# case_ <name> <json> -- <expected substring | !unexpected substring ...>
case_() {
    local name=$1 json=$2; shift 3
    local out rc ok=1 why= want
    out=$(printf '%s' "$json" | TZ=UTC "$SCRIPT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); rc=$?
    [ "$rc" -ne 0 ] && { ok=0; why="exit $rc"; }
    for want in "$@"; do
        if [ "${want#!}" != "$want" ]; then
            case $out in *"${want#!}"*) ok=0; why="unexpected: ${want#!}";; esac
        else
            case $out in *"$want"*) ;; *) ok=0; why="missing: $want";; esac
        fi
    done
    if [ "$ok" = 1 ]; then
        pass=$((pass+1)); echo "ok   - $name"
    else
        fail=$((fail+1)); echo "FAIL - $name: $why"; echo "       got: $out"
    fi
}

FULL='{"model":{"display_name":"Opus 5.5"},"cost":{"total_cost_usd":1.23},
 "context_window":{"context_window_size":200000,"used_percentage":23.4,
   "current_usage":{"input_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":40000}},
 "rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1793112000},
   "seven_day":{"used_percentage":85.6,"resets_at":"2026-11-02T08:00:00.000Z"}}}'

echo "# claude-statusline"
case_ "model, context and both limits" "$FULL" -- \
    "Opus 5.5" "ctx 23% (46k/200k)" "5h 12% (14:40)" "7d 85% (Mon 08:00)"
case_ "never shows the cost" "$FULL" -- '!1.23' '!$'
out=$(printf '%s' "$FULL" | "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g')
if printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]'; then
    fail=$((fail+1)); echo "FAIL - plain ASCII only (no glyphs of ambiguous width): $out"
else
    pass=$((pass+1)); echo "ok   - plain ASCII only (no glyphs of ambiguous width)"
fi
case_ "context percentage computed when not given" \
    '{"model":{"display_name":"M"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":100000}}}' \
    -- "ctx 50% (100k/200k)"
case_ "no limits for API-key sessions" \
    '{"model":{"display_name":"M"},"context_window":{"context_window_size":200000}}' -- '!5h' '!7d'
case_ "bare input still prints the model" '{"model":{"display_name":"M"}}' -- "M" '!ctx'
case_ "empty input does not fail" '{}' --
echo "# $pass passed, $fail failed"
[ "$fail" -eq 0 ]
