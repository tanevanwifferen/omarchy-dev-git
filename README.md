# dev.git — Git dashboard bar widget for Omarchy

A native [Omarchy](https://omarchy.org) shell bar widget that watches GitHub,
GitLab and Gitea for open work: a full-year contribution graph, review queues,
and your own pull and merge requests, all in one panel.

![The dev.git panel showing the GitHub and GitLab tabs side by side](preview.png)

## Features

- **Full-year activity graph** — trailing 53 weeks, quartile-shaded, with
  per-day tooltips, streaks and today's count
- **Multiple hosts per provider** — GitHub Enterprise and self-managed GitLab
  and Gitea are discovered from `gh`/`glab`/`tea` config, each with its own
  identity, graph and queues, behind a host switch inside the tab
- **Open-work grid** — awaiting review, assigned PRs/MRs, assigned and authored
  issues, failing and running builds; each click opens the pre-filtered queue
  page
- **Checks and pipelines** — every request carries its build state as a
  coloured dot, and the red ones collect into their own section. It rides along
  with the request queues, so it costs no extra API call
- **Queue rows** carrying draft tag, approval check, comment count, repository,
  number and age
- A dot on the bar icon when something is waiting on your review
- Keyboard driven throughout

## Install

```bash
omarchy plugin add https://github.com/tanevanwifferen/omarchy-dev-git.git --enable --yes
```

Needs `curl` and `jq`, plus any of [gh](https://cli.github.com/),
[glab](https://gitlab.com/gitlab-org/cli) and [tea](https://gitea.com/gitea/tea)
signed in — the collector reads the credentials those CLIs already hold and
never stores a token of its own. All three are optional: each provider is
collected independently, so a missing or unauthenticated one never hides the
others.

Nothing is compiled or installed. Clone it and it runs.

## Keyboard

| Key       | Action                        |
|-----------|-------------------------------|
| `j` / `k` | Move down / up the queue rows |
| `h` / `l` | Previous / next provider tab  |
| `[` / `]` | Previous / next host          |
| `g` / `G` | First / last row              |
| `Enter`   | Open the selected row         |
| `p`       | Pin the provider tab first    |
| `r`       | Refresh now                   |
| `Tab`     | Neighbouring panel            |
| `Esc`     | Close                         |

Left click toggles the panel, middle click cycles providers, right click
refreshes.

### Open it from a keybinding

The panel exposes an IPC target, so it can be bound to a key. Add to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + G", "Git dashboard", "omarchy-shell dev.git toggle")
```

`toggle`, `open`, `close`, `refresh` and `next` (cycle provider) are all
available — `omarchy-shell dev.git refresh` refreshes without opening.

## How it works

`bin/gitwork` runs on a timer (default 300 s) and writes one JSON overview to
`~/.local/state/omarchy/git/overview.json`, which the panel watches. It is a
bash script with its JSON transforms in `bin/gitwork.jq`.

GitHub needs one GraphQL request per host for identity, calendar, all five
queues and the check rollup on every request in them. GitLab takes one GraphQL request for identity, merge requests and their head
pipelines, REST for issues, and the events feed for the calendar — it has no
calendar API — with page one reporting the page count so the rest are fetched
in small batches. Gitea has no
GraphQL at all, but its issue search takes each queue as query parameters and
answers pulls and issues from one row shape, so identity comes first and then
the five queues and the heatmap fly together. That search reports no build
state, and asking per row would cost one request each, so Gitea shows no CI
view rather than a confident zero.

A schema that predates the check rollup or `headPipeline` — an older
self-managed instance — makes the whole query fail, so the collector retries
that host once without the CI fields instead of losing it over a decoration.

Every host is collected in its own subshell, so a run costs the slowest single
host rather than the sum of them. A host that cannot be reached carries its last
good record forward for up to six hours, marked stale, so a dropped VPN does not
blank a working dashboard. An authentication failure is not carried: that data
is genuinely gone.

### Staying under the rate limit

Every queue this panel shows is answered by a request that was already being
made, so adding the CI view added no traffic. On top of that:

- A `429`, or a `403` that arrives with an exhausted budget, is read as *come
  back at T* rather than as a broken token, and `T` is stored on the record.
- The next run skips that host entirely until `T` passes — zero requests, not
  fewer — and the panel says `RATE LIMITED UNTIL 16:30` over the last good data
  rather than looking broken.
- GitHub reports its own remaining budget, so a token nearly spent by anything
  at all (including your own `gh` session) parks itself until the window resets.
- The GitLab events feed is the only place that pages, and it goes out six
  requests at a time, abandoning the rest the moment the instance answers 429.

## Settings

| Key                        | Type    | Default | Description                |
|----------------------------|---------|---------|----------------------------|
| `refreshIntervalSec`       | integer | 300     | Collector run interval (s) |
| `providers.github.enabled` | boolean | true    | Show the GitHub tab        |
| `providers.gitlab.enabled` | boolean | true    | Show the GitLab tab        |

## Tests

```bash
./tests/run.sh
```

No network or credentials required — every host the suite touches is
deliberately unreachable.

## License

MIT
