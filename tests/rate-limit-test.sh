#!/usr/bin/env bash
# Back-off rules. Being throttled is the one failure that gets worse the harder
# we retry, so the collector has to read a 429 correctly, remember the deadline,
# and then genuinely stay off the host until it passes.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "rate limit"

load_collector

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

headers() { printf '%s\n' "$@" >"$work/head"; printf '%s\n' "$work/head"; }

# --- reading the response --------------------------------------------------

h=$(headers 'HTTP/2 429' 'retry-after: 120')
assert_eq "120" "$(rate_limit_pause "$h" 429)" "Retry-After is taken at its word"

h=$(headers 'HTTP/2 429' 'Retry-After: 45')
assert_eq "45" "$(rate_limit_pause "$h" 429)" "the header name is case-insensitive"

# GitHub answers 403, not 429, when the hourly budget is gone; treating that as
# a bad token would send the user off to re-authenticate for nothing.
future=$(( $(date -u +%s) + 300 ))
h=$(headers 'HTTP/2 403' 'x-ratelimit-remaining: 0' "x-ratelimit-reset: $future")
pause=$(rate_limit_pause "$h" 403)
assert_eq "0" "$(( pause > 240 && pause <= 300 ? 0 : 1 ))" \
  "an exhausted budget waits for its own reset"

h=$(headers 'HTTP/2 429')
assert_eq "60" "$(rate_limit_pause "$h" 429)" "a bare 429 still backs off"

# A reset already in the past says nothing useful; wait a token minute instead
# of hammering.
h=$(headers 'HTTP/2 403' 'x-ratelimit-remaining: 0' 'x-ratelimit-reset: 1')
assert_eq "60" "$(rate_limit_pause "$h" 403)" "a stale reset falls back to a minute"

# A 403 with budget left is a permissions or token problem, and must keep
# reporting itself as one.
h=$(headers 'HTTP/2 403' 'x-ratelimit-remaining: 4999')
assert_eq "1" "$(rate_limit_pause "$h" 403 >/dev/null; echo $?)" \
  "a plain 403 is not a throttle"
assert_eq "1" "$(rate_limit_pause "$h" 200 >/dev/null; echo $?)" "a good response is not a throttle"
assert_eq "60" "$(rate_limit_pause "$work/absent" 429)" \
  "a 429 with no readable headers at all still backs off"
assert_eq "1" "$(rate_limit_pause "$work/absent" 403 >/dev/null; echo $?)" \
  "a missing header file does not invent a throttle"

# --- the deadline ----------------------------------------------------------

assert_eq "0" "$(iso_in 120 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' >/dev/null; echo $?)" \
  "the deadline is an ISO timestamp"

# Never longer than the window in which the carried-forward record still counts:
# waiting past it would blank the panel rather than hold it.
long=$(iso_in $((24 * 3600)))
capped=$(( $(date -u -d "$long" +%s) - $(date -u +%s) ))
assert_eq "0" "$(( capped <= MAX_BACKOFF_SEC ? 0 : 1 ))" "an absurd deadline is capped"

short=$(iso_in 0)
floor_gap=$(( $(date -u -d "$short" +%s) - $(date -u +%s) ))
assert_eq "0" "$(( floor_gap >= 25 ? 0 : 1 ))" "an instant retry is still a pause"

# --- honouring it next run -------------------------------------------------

overview() {
  jq -c -n --arg until "$1" '{schemaVersion: 4, providers: [
    {key: "github@github.com", kind: "github", host: "github.com", retryAfter: $until},
    {key: "gitlab@gitlab.com", kind: "gitlab", host: "gitlab.com", retryAfter: ""}]}'
}

PREVIOUS=$(overview "$(iso_in 600)")
assert_eq "0" "$([[ -n $(backoff_until github github.com) ]] && echo 0 || echo 1)" \
  "a host still serving a back-off is skipped"
assert_eq "" "$(backoff_until gitlab gitlab.com)" "a host without one is collected"
assert_eq "" "$(backoff_until github other.example)" "an unknown host is collected"

PREVIOUS=$(overview "2000-01-01T00:00:00Z")
assert_eq "" "$(backoff_until github github.com)" "an expired back-off is over"

PREVIOUS='null'
assert_eq "" "$(backoff_until github github.com)" "a first run has nothing to honour"

# --- the record it writes --------------------------------------------------

record=$(backoff_provider github github.com true "2030-01-01T10:00:00Z" "Rate limited" 5)
assert_eq "false" "$(jq -r .ready <<<"$record")" "a throttled host is not ready"
assert_eq "2030-01-01T10:00:00Z" "$(jq -r .retryAfter <<<"$record")" "the deadline is recorded"
assert_eq "Rate limited" "$(jq -r .error <<<"$record")" "the reason is recorded"
assert_eq "0" "$(jq -r '[.reviewRequests, .assignedPrs] | map(length) | add' <<<"$record")" \
  "it carries no data of its own"

# An error record with a previous good one behind it keeps the old data on
# screen, marked stale, rather than blanking the panel for an hour.
prev=$(jq -c -n '{schemaVersion: 4, providers: [{
  key: "github@github.com", kind: "github", host: "github.com", ready: true, stale: false,
  staleAt: "", error: "", retryAfter: "", updatedAt: "2030-01-01T09:00:00Z",
  reviewRequests: [{url: "u"}]}]}')
carried=$(jq -r -L "$JQ_LIB_DIR" -c --argjson prev "$prev" --argjson cur "[$record]" \
  'include "gitwork"; $cur | carry_forward($prev; 4; 0) | .[0]' <<<'null')
assert_eq "1" "$(jq -r '.reviewRequests | length' <<<"$carried")" "the last good queue is kept"
assert_eq "true" "$(jq -r .stale <<<"$carried")" "and is marked stale"
assert_eq "2030-01-01T10:00:00Z" "$(jq -r .retryAfter <<<"$carried")" \
  "the new deadline survives the carry, so the next run still waits"

finish
