#!/usr/bin/env bash
# Row normalization: every provider is flattened onto one Item shape so the
# panel never branches on which host a row came from.

source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

echo "items"

# --- authors ---------------------------------------------------------------

# A row in your own queue does not need to tell you who opened it.
assert_eq "" "$(jqlib 'other_author("ariadev"; "ariadev")')" "your own handle is blanked"
assert_eq "" "$(jqlib 'other_author("AriaDev"; "ariadev")')" "the match is case-insensitive"
assert_eq "" "$(jqlib 'other_author(""; "ariadev")')" "a missing author stays empty"
assert_eq "someone" "$(jqlib 'other_author("someone"; "ariadev")')" "another handle is kept"

# --- totals ----------------------------------------------------------------

# The server-side count can exceed the rows we fetched; show the true number
# rather than lying about it, but never report fewer rows than we hold.
assert_json_eq '{"a":90}' "$(jqlib 'totals([["a", 90, 50]])')" "a larger server count wins"
assert_json_eq '{"a":50}' "$(jqlib 'totals([["a", 3, 50]])')" "a stale count never undercounts rows"
assert_json_eq '{"a":0}' "$(jqlib 'totals([["a", 0, 0]])')" "an empty queue is zero"
assert_json_eq '{"a":1,"b":2}' "$(jqlib 'totals([["a",1,0],["b",0,2]])')" "every queue is keyed"

# --- GitHub rows -----------------------------------------------------------

gh_nodes='[
  {"number":7,"title":"Fix bar","url":"https://github.com/o/r/pull/7","updatedAt":"2026-08-01T00:00:00Z",
   "isDraft":true,"reviewDecision":"CHANGES_REQUESTED","author":{"login":"other"},
   "comments":{"totalCount":4},"repository":{"nameWithOwner":"o/r"},
   "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
  {"number":8,"title":"No url","url":"","repository":{"nameWithOwner":"o/r"}}
]'
gh=$(jqlib 'github_items($n; "ariadev")' --argjson n "$gh_nodes")
assert_eq "1" "$(jq -r 'length' <<<"$gh")" "a row without a url is dropped"
assert_json_eq '{
  "number":7,"title":"Fix bar","repository":"o/r","url":"https://github.com/o/r/pull/7",
  "updatedAt":"2026-08-01T00:00:00Z","draft":true,"author":"other",
  "review":"changes_requested","ci":"failed","comments":4}' "$(jq -c '.[0]' <<<"$gh")" \
  "a GitHub row maps onto the shared item shape"

# The rollup is absent on an old GitHub Enterprise, and on any request that
# never ran a check. Neither is a red build.
assert_eq "" "$(jqlib 'github_items([{"number":1,"url":"u"}]; "me") | .[0].ci')" \
  "a request with no status rollup has no build state"

assert_eq "" "$(jqlib 'github_items([{"number":1,"url":"u","author":null}]; "me") | .[0].author')" \
  "a deleted GitHub author is empty, not null"
assert_eq "" "$(jqlib 'github_items([{"number":1,"url":"u"}]; "me") | .[0].review')" \
  "a missing review decision is empty"
assert_json_eq '[]' "$(jqlib 'github_items(null; "me")')" "a missing queue yields no rows"

# --- GitLab merge requests -------------------------------------------------

gl_nodes='[
  {"iid":"42","title":"Ship it","webUrl":"https://gitlab.com/g/p/-/merge_requests/42",
   "updatedAt":"2026-08-02T00:00:00Z","draft":false,"approved":true,"userNotesCount":2,
   "author":{"username":"ariadev"},"project":{"fullPath":"g/p"},
   "headPipeline":{"status":"RUNNING"}}
]'
gl=$(jqlib 'gitlab_mr_items($n; "ariadev")' --argjson n "$gl_nodes")
assert_json_eq '{
  "number":42,"title":"Ship it","repository":"g/p",
  "url":"https://gitlab.com/g/p/-/merge_requests/42","updatedAt":"2026-08-02T00:00:00Z",
  "draft":false,"author":"","review":"approved","ci":"running","comments":2}' \
  "$(jq -c '.[0]' <<<"$gl")" \
  "a GitLab merge request maps onto the shared item shape"

assert_eq "" "$(jqlib 'gitlab_mr_items([{"iid":"9","webUrl":"u"}]; "me") | .[0].ci')" \
  "an instance too old for headPipeline reports no build state"

assert_eq "number" "$(jqlib 'gitlab_mr_items([{"iid":"9","webUrl":"u"}]; "me") | .[0].number | type')" \
  "the string iid becomes a number"
assert_eq "" "$(jqlib 'gitlab_mr_items([{"iid":"9","webUrl":"u","approved":false}]; "me") | .[0].review')" \
  "an unapproved merge request has no review state"

# --- GitLab issues ---------------------------------------------------------

assert_eq "group/project" "$(jqlib 'project_from_reference("group/project#12")')" \
  "an issue reference yields the project path"
assert_eq "group/project" "$(jqlib 'project_from_reference("group/project!5")')" \
  "a merge request reference does too"
assert_eq "group/sub/project" "$(jqlib 'project_from_reference("group/sub/project#1")')" \
  "nested groups survive"
assert_eq "" "$(jqlib 'project_from_reference("")')" "an empty reference stays empty"

gl_issues='[{"iid":3,"title":"Bug","web_url":"https://gitlab.com/g/p/-/issues/3",
  "updated_at":"2026-08-03T00:00:00Z","user_notes_count":1,
  "author":{"username":"other"},"references":{"full":"g/p#3"}}]'
assert_json_eq '{
  "number":3,"title":"Bug","repository":"g/p","url":"https://gitlab.com/g/p/-/issues/3",
  "updatedAt":"2026-08-03T00:00:00Z","draft":false,"author":"other","review":"","ci":"",
  "comments":1}' \
  "$(jqlib 'gitlab_issue_items($n; "ariadev") | .[0]' --argjson n "$gl_issues")" \
  "a GitLab issue maps onto the shared item shape"

# --- Gitea rows ------------------------------------------------------------

# One endpoint and one row shape answers both pulls and issues, so the same
# transform has to carry a draft pull and a plain issue.
gt_rows='[
  {"number":11,"title":"Add tea","html_url":"https://git.example.com/o/r/pulls/11",
   "updated_at":"2026-08-04T00:00:00Z","comments":3,"user":{"login":"other"},
   "repository":{"full_name":"o/r"},"pull_request":{"draft":true,"merged":false}},
  {"number":12,"title":"No url","html_url":""}
]'
gt=$(jqlib 'gitea_items($n; "ariadev")' --argjson n "$gt_rows")
assert_eq "1" "$(jq -r 'length' <<<"$gt")" "a Gitea row without a url is dropped"
assert_json_eq '{
  "number":11,"title":"Add tea","repository":"o/r","url":"https://git.example.com/o/r/pulls/11",
  "updatedAt":"2026-08-04T00:00:00Z","draft":true,"author":"other","review":"","ci":"",
  "comments":3}' \
  "$(jq -c '.[0]' <<<"$gt")" "a Gitea pull maps onto the shared item shape"

# --- build state -----------------------------------------------------------

# Three providers spell the same four outcomes six ways; the panel only ever
# sees the normalized set.
assert_eq "success" "$(jqlib 'ci_state("SUCCESS")')" "GitHub success normalizes"
assert_eq "success" "$(jqlib 'ci_state("passed")')" "a passed pipeline normalizes"
assert_eq "failed" "$(jqlib 'ci_state("FAILURE")')" "a GitHub failure is red"
assert_eq "failed" "$(jqlib 'ci_state("FAILED")')" "a GitLab failure is red"
assert_eq "failed" "$(jqlib 'ci_state("ERROR")')" "an errored check is red too"
assert_eq "running" "$(jqlib 'ci_state("PENDING")')" "a pending check is moving"
assert_eq "running" "$(jqlib 'ci_state("WAITING_FOR_RESOURCE")')" "so is a queued pipeline"
assert_eq "canceled" "$(jqlib 'ci_state("CANCELED")')" "a cancelled pipeline is named"
assert_eq "skipped" "$(jqlib 'ci_state("SKIPPED")')" "a skipped pipeline is named"
assert_eq "manual" "$(jqlib 'ci_state("MANUAL")')" "a manual pipeline waits on a human"
assert_eq "" "$(jqlib 'ci_state(null)')" "no pipeline is no state"
assert_eq "" "$(jqlib 'ci_state("SOMETHING_NEW")')" "an unknown state is shown as none"

# The pipeline section is assembled from the queues we already hold, so a
# merge request sitting in two of them must appear once.
ci_queues='[
  [{"url":"a","ci":"failed","updatedAt":"2026-08-01T00:00:00Z"}],
  [{"url":"a","ci":"failed","updatedAt":"2026-08-01T00:00:00Z"},
   {"url":"b","ci":"failed","updatedAt":"2026-08-03T00:00:00Z"}],
  [{"url":"c","ci":"running","updatedAt":"2026-08-02T00:00:00Z"},
   {"url":"d","ci":"success","updatedAt":"2026-08-02T00:00:00Z"}]
]'
failing=$(jqlib 'ci_rows($q; "failed")' --argjson q "$ci_queues")
assert_eq "2" "$(jq -r 'length' <<<"$failing")" "a request in two queues is listed once"
assert_json_eq '["b","a"]' "$(jq -c '[.[].url]' <<<"$failing")" "failing rows are newest first"
assert_eq "1" "$(jqlib 'ci_rows($q; "running") | length' --argjson q "$ci_queues")" \
  "running pipelines are their own queue"
assert_json_eq '[]' "$(jqlib 'ci_rows(null; "failed")')" "no queues yield no pipeline rows"

assert_eq "false" \
  "$(jqlib 'gitea_items([{"number":1,"html_url":"u"}]; "me") | .[0].draft')" \
  "an issue carries no pull_request block and is never a draft"
assert_eq "" "$(jqlib 'gitea_items([{"number":1,"html_url":"u","user":null}]; "me") | .[0].author')" \
  "a deleted Gitea author is empty, not null"
assert_json_eq '[]' "$(jqlib 'gitea_items(null; "me")')" "a missing Gitea queue yields no rows"

# --- calendar count extraction ---------------------------------------------

assert_json_eq '{"2026-01-01":2,"2026-01-02":5}' \
  "$(jqlib '{"weeks":[{"contributionDays":[
      {"date":"2026-01-01","contributionCount":2},
      {"date":"2026-01-02","contributionCount":5}]}]} | counts_from_github_calendar')" \
  "GitHub calendar weeks flatten to a day map"

assert_json_eq '{"2026-01-01":2,"2026-01-02":1}' \
  "$(jqlib '[{"created_at":"2026-01-01T09:00:00Z"},{"created_at":"2026-01-01T10:00:00Z"},
      {"created_at":"2026-01-02T10:00:00Z"}] | counts_from_gitlab_events')" \
  "GitLab events tally per day"

assert_json_eq '{}' "$(jqlib '[{"created_at":"bad"},{}] | counts_from_gitlab_events')" \
  "malformed events are skipped rather than crashing the run"

# Gitea reports several buckets a day, so the day total is a sum, not a lookup.
assert_json_eq '{"2026-05-01":3,"2026-05-02":4}' \
  "$(jqlib '[{"timestamp":1777636800,"contributions":1},
      {"timestamp":1777640400,"contributions":2},
      {"timestamp":1777723200,"contributions":4}] | counts_from_gitea_heatmap')" \
  "Gitea heatmap buckets sum per day"

assert_json_eq '{}' "$(jqlib '[{"contributions":3},{}] | counts_from_gitea_heatmap')" \
  "a bucket with no timestamp is skipped"

# --- the base record -------------------------------------------------------

for kind in github gitlab gitea; do
  base=$(jqlib "base_provider(\"$kind\"; \"example.com\"; false)")
  assert_eq "$kind@example.com" "$(jq -r .key <<<"$base")" "$kind key is kind@host"
  assert_eq "false" "$(jq -r .ready <<<"$base")" "$kind starts unready"
  assert_eq "https://example.com" "$(jq -r .webUrl <<<"$base")" "$kind web url defaults to the host"
  assert_eq "0" "$(jq -r '[.reviewRequests,.assignedPrs,.authoredPrs,.assignedIssues,.authoredIssues]
    | map(length) | add' <<<"$base")" "$kind starts with empty queues"
done

assert_eq "GitHub" "$(jqlib 'base_provider("github"; "h"; true) | .name')" "GitHub is named"
assert_eq "GitLab" "$(jqlib 'base_provider("gitlab"; "h"; true) | .name')" "GitLab is named"
assert_eq "Gitea" "$(jqlib 'base_provider("gitea"; "h"; true) | .name')" "Gitea is named"

assert_eq "Pull requests" "$(jqlib 'base_provider("github"; "h"; true) | .mrTerm')" "GitHub says pull requests"
assert_eq "Pull requests" "$(jqlib 'base_provider("gitea"; "h"; true) | .mrTerm')" "Gitea says pull requests too"
assert_eq "Merge requests" "$(jqlib 'base_provider("gitlab"; "h"; true) | .mrTerm')" "GitLab says merge requests"
assert_eq "PRs" "$(jqlib 'base_provider("github"; "h"; true) | .mrTermShort')" "GitHub short term"
assert_eq "MRs" "$(jqlib 'base_provider("gitlab"; "h"; true) | .mrTermShort')" "GitLab short term"
assert_eq "PRs" "$(jqlib 'base_provider("gitea"; "h"; true) | .mrTermShort')" "Gitea short term"

finish
