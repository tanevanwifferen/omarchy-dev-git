#!/usr/bin/env bash
# The GitLab events walk. This is the one place in the collector that pages, and
# when it stops early the damage is silent: the panel draws a perfectly
# plausible graph that simply ends in June. So the walk is exercised against a
# stub server rather than trusted.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "events paging"

load_collector

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The collector's own scratch space and request settings, which a normal run
# sets up before any host is collected.
tmp="$work/tmp"; mkdir -p "$tmp"
req_timeout=5
AUTH_HEADER=()
ERR_FILE="$work/err"; : >"$ERR_FILE"

# A stub `curl` standing in for the events feed: it answers $STUB_PAGES full
# pages of one event each day, then a short page, and records every page it was
# asked for. X-Total-Pages is only sent when $STUB_TOTAL_PAGES says so, because
# GitLab drops that header on exactly the large accounts this walk exists for.
stub_dir="$work/bin"; mkdir -p "$stub_dir"
cat >"$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
body=""; headers=""; url=""
while (($#)); do
  case "$1" in
    -o) body=$2; shift 2 ;;
    -D) headers=$2; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
page=1
[[ $url =~ [?\&]page=([0-9]+) ]] && page=${BASH_REMATCH[1]}
echo "$page" >>"$STUB_LOG"

rows=$STUB_PAGE_SIZE
((page > STUB_PAGES)) && rows=0
((page == STUB_PAGES)) && rows=$STUB_LAST_ROWS

{ echo "HTTP/2 200"
  [[ $STUB_TOTAL_PAGES == none ]] || echo "X-Total-Pages: $STUB_TOTAL_PAGES"
} >"$headers"

# Each page carries its own day, so a truncated walk shows up as missing days
# rather than as a smaller count on the same day.
jq -n --argjson rows "$rows" --argjson page "$page" \
  '[range(0; $rows) | {created_at: ("2026-0" + (($page % 9) + 1 | tostring) + "-01T10:00:00Z")}]' \
  >"$body"
echo 200
STUB
chmod +x "$stub_dir/curl"
export PATH="$stub_dir:$PATH"
export STUB_PAGE_SIZE=$GITLAB_PAGE_SIZE

# Walk the feed and report how many pages were requested.
walk() {
  export STUB_PAGES=$1 STUB_LAST_ROWS=$2 STUB_TOTAL_PAGES=$3
  STUB_LOG="$work/log"; export STUB_LOG; : >"$STUB_LOG"
  rm -f "$tmp"/gl-stub-events*
  gitlab_calendar "https://stub" stub "$work/cal.json"
  sort -n "$STUB_LOG" | uniq | wc -l
}

# --- past the old ceiling --------------------------------------------------

# The bug that started this: a year of a busy account needs more than the 40
# pages the walk used to allow, and everything past it was simply missing.
assert_eq "0" "$((GITLAB_PAGE_CAP > 40 ? 0 : 1))" "the page cap clears the old 40"

pages=$(walk 61 40 61)
assert_eq "61" "$pages" "a 61-page year is walked to the end"
assert_eq "6040" "$(jq -r .total "$work/cal.json")" "every event on those pages is counted"

# --- stopping on its own ---------------------------------------------------

# GitLab omits X-Total-Pages past 10 000 rows, which is precisely the account
# that needs the walk. Without a count the walk must keep going and stop at the
# first short page, not read the silence as "one page".
pages=$(walk 12 15 none)
assert_eq "0" "$((pages >= 12 && pages < GITLAB_PAGE_CAP ? 0 : 1))" \
  "a missing page count still walks the whole feed"
assert_eq "1115" "$(jq -r .total "$work/cal.json")" "and counts every event in it"

# A single short page is the whole feed; asking for a second would be a wasted
# request on the most common account there is.
pages=$(walk 1 7 1)
assert_eq "1" "$pages" "a feed that fits in one page costs one request"
assert_eq "7" "$(jq -r .total "$work/cal.json")" "its events are counted"

# The cap is a ceiling, not a target: a feed that never ends stops there.
pages=$(walk 9999 100 none)
assert_eq "0" "$((pages <= GITLAB_PAGE_CAP ? 0 : 1))" "an endless feed stops at the cap"

# --- newest first ----------------------------------------------------------

# Which end of the year a capped walk loses is the difference between a graph
# that fades at the far left and one that stops in June, so the order the feed
# is asked for is asserted rather than assumed.
walk 3 10 3 >/dev/null
assert_eq "2" "$(grep -c 'events?.*sort=desc' "$COLLECTOR")" "the feed is walked newest-first"
assert_eq "0" "$(grep -c 'sort=asc' "$COLLECTOR")" "no page is asked for oldest-first"

# --- failure ---------------------------------------------------------------

# A first page that never arrives leaves an empty calendar rather than a broken
# document: the rest of the provider is still worth showing.
cat >"$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
while (($#)); do case "$1" in -o) echo '{"message":"no"}' >"$2"; shift 2 ;;
  -D) : >"$2"; shift 2 ;; *) shift ;; esac; done
echo 500
STUB
chmod +x "$stub_dir/curl"
rm -f "$tmp"/gl-stub-events*
gitlab_calendar "https://stub" stub "$work/cal.json"
assert_eq "false" "$(jq -r .supported "$work/cal.json")" \
  "an unreachable feed yields the empty calendar"

finish
