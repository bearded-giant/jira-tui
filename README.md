# jira-tui

[![CI](https://github.com/bearded-giant/jira-tui/actions/workflows/ci.yml/badge.svg)](https://github.com/bearded-giant/jira-tui/actions/workflows/ci.yml)

A standalone terminal UI for Jira: your issues, saved queries, sprint board, backlog and ad-hoc JQL rendered as an expandable issue tree. Read, triage, edit, create, comment and log work without leaving the terminal.

## Requirements

LuaJIT (or Lua 5.1+) and `curl`. Nothing else, JSON parsing is vendored, so there's no `luarocks install` step. On macOS that's `brew install luajit`.

## Setup

Point it at your Jira instance with environment variables:

```sh
export JIRA_BASE=https://your-domain.atlassian.net
export JIRA_EMAIL=you@example.com
export JIRA_TOKEN=your_api_token   # https://id.atlassian.com/manage-profile/security/api-tokens
```

`JIRA_API_TOKEN` is accepted as an alias for `JIRA_TOKEN`, whichever you already have set works.

Or drop a config file at `~/.config/jira-tui/config.lua` that returns a table. Environment variables override the file, so you can keep the token out of the dotfile and commit the rest:

```lua
return {
  jira = {
    base = "https://your-domain.atlassian.net",
    email = "you@example.com",
    limit = 500,
  },
  -- per-project custom fields (story points, acceptance criteria)
  projects = {
    REF = { story_point_field = "customfield_10035", acceptance_criteria_field = "customfield_10016" },
  },
  -- scope the My Issues view to these projects (empty = all projects)
  my_issues_projects = { "ABC", "DEF" },
  -- tabs to hide from the strip (My Issues never hides)
  hidden_tabs = { "Active Sprint", "Backlog" },
  -- saved queries, each gets its own tab after My Issues
  queries = {
    { name = "Review", jql = "status = 'In Review' AND project = ABC" },
    { name = "Bugs", jql = "type = Bug AND resolution IS EMPTY", key = "5" },
  },
  -- seconds a fetched view is reused when you switch back to its tab (0 = always refetch)
  cache_ttl = 300,
  -- seconds of idling before the current view reloads itself (0 = never)
  refresh_interval = 300,
  -- board columns, left to right
  columns = { "key", "summary", "assignee", "created", "age", "status" },
}
```

`columns` picks from `key`, `summary`, `assignee`, `status`, `created`, `age` (time since created), `updated` (time since last update), `priority`, `points` and `labels`. `key` and `summary` are required. On a narrow terminal the optional ones (everything except key, summary, assignee and status) drop out right to left until the title has room, and `gs` sorts by any configured column. The status column sizes itself to the longest status in the loaded rows.

Switching tabs reuses rows fetched within the last `cache_ttl` seconds, so flipping between views is instant; the footer says how long ago the rows you're looking at were fetched (`updated 3m ago`), and `r` always refetches. Leave the board idle and it reloads the current view every `refresh_interval` seconds, keeping your cursor and filter, and it quietly prefetches the detail of the row under the cursor so `enter` opens instantly. Your own edits (status, assign, edit, close) patch the affected row in every cached view that already shows it; a new issue only lands in the view you created it from.

Each saved query becomes a tab you can jump to with a digit. `key` is optional and defaults to the query's position in the list, so the first one is `1`, the second `2`, and so on up to `9`. Names have to be unique and can't reuse a built-in tab name (My Issues, JQL, Active Sprint, Backlog, Help).

## Install

```sh
git clone https://github.com/bearded-giant/jira-tui.git
cd jira-tui
make install        # symlinks bin/jira-tui into ~/.local/bin
jira-tui            # now on your PATH
```

`make install` symlinks `bin/jira-tui` into `~/.local/bin`. The launcher resolves its own location (following the symlink), so it finds the repo from anywhere. Make sure `~/.local/bin` is on your `PATH`:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc
```

Prefer a system location already on `PATH`? `make install PREFIX=/usr/local` (drops the symlink in `/usr/local/bin`; may need `sudo`). Remove it later with `make uninstall`.

Keep the repo where it is, the symlink points back to it; `git pull` updates the installed command in place.

## Usage

```sh
jira-tui                  # My Issues (no project needed)
jira-tui REF              # active sprint for project REF
jira-tui REF --backlog    # backlog
jira-tui --my             # issues assigned to you (scoped to saved projects)
jira-tui REF --jql "status = 'In Progress'"
jira-tui --help           # flags + keys
```

A project key is only needed for the sprint and backlog views. With no arguments it opens My Issues, and you move around from there, no project is ever forced on startup. Inside the TUI, `S` and `B` reuse the last project you used (from an argument or the `p` prompt), so you rarely need to retype it.

### Keys

On the board:

| Key | Action |
|-----|--------|
| `j` / `k` (or arrows, mouse wheel) | move cursor; clicking a row selects it |
| `gg` / `G` | top / bottom |
| `ctrl-d` / `ctrl-u` | half page down / up |
| `enter` | open issue detail (expands the node instead if it has subtasks) |
| `space` / `tab` / `o` | expand / collapse node |
| `t` | toggle all |
| `M` | My Issues (assigned to you) |
| `1`-`9` | jump to a saved query tab (see `queries` in the config) |
| `S` / `B` | Active Sprint / Backlog |
| `←` / `→` | cycle tabs |
| `p` | set / change the project (for sprint + backlog) |
| `J` | JQL picker (history, or new query; `e` edits the selected query) |
| `gj` | new JQL query |
| `gi` | go to an issue by key or pasted browse url; opens its detail without touching the board |
| `/` | filter loaded rows (instant, no refetch); `BS` clears it |
| `x` | show / hide resolved |
| `gs` | sort by column |
| `K` / `m` | issue detail with comments / raw markdown |
| `s` | change status |
| `e` | edit: summary, description (in your editor), append to description, priority, points, labels, parent, or status |
| `a` / `A` | assign (user picker) / assign to me |
| `C` | comment in your editor, posted as markdown |
| `w` | log work (`1h 30m`, `2d`, `45m`) |
| `c` | create an issue in the current project: pick a type, then fill the template in your editor (assigned to you) |
| `gc` | create a child of the selected row: sub-task under a story or task, standard type under an epic |
| `d` | close via the first done-ish transition |
| `b` / `gx` | open in browser |
| `y` / `Y` | copy key / url |
| `gb` | copy a git branch name (`pe-1472-add-rate-limit`) |
| `r` | refresh, skipping the view cache (keeps cursor and filter) |
| `?` / `H` | help |
| `q` | back: closes detail / help / pickers, never the app |
| `Esc` | cancel a running load, else clear the filter, else clear the footer message, else arm quit; a second `Esc` quits |
| `ctrl-c` | quit immediately |

In the detail view:

| Key | Action |
|-----|--------|
| `j` / `k`, `ctrl-d` / `ctrl-u`, `g` / `G` | scroll, page, top / bottom |
| `c` | expand / collapse comments (they start collapsed) |
| `o` | pick an attachment, download it and open it |
| `]` / `[` | next / previous issue in board order |
| `L` | jump to the parent, a subtask or a linked issue |
| `/` `n` `N` | search the issue text; next / previous match (wraps) |
| `s` `a` `A` `e` `d` `C` `w` `y` `Y` `b` | same as on the board, acting on the issue you're reading |
| `q` | back: undoes `L` jumps first, then returns to the board |

In pickers and prompts:

| Key | Action |
|-----|--------|
| `j` / `k`, `enter` | move, pick |
| `/` | filter the list as you type; `enter` keeps the filter, `Esc` clears it. In the assign picker `enter` searches every assignable user on the server |
| `Esc` / `q` | cancel |
| `ctrl-s` | submit a multi-line prompt (JQL editor, append description) |

### Filtering

`/` opens a prompt; submit it empty to clear the filter. Every word has to match. Plain words look at the summary and key; `@ann` matches the assignee, `s:review` the status, `t:bug` the type, `p:high` the priority and `l:perf` any label, all as case-insensitive substrings. So `@ann s:prog cache` is Ann's in-progress issues that mention cache. The filter runs over rows already fetched, so it's instant; on a view cut off by the fetch limit (the `+` in the title count) it only searches what was fetched.

### Reading an issue

The detail view shows the fields up top, then a Links section (parent, subtasks, linked issues with their status), attachments, the description and acceptance criteria rendered from Jira's markdown, and the newest comments. Everything you can do to an issue on the board works here too, and anything that changes the issue reloads the view in place. `]` and `[` walk the board without closing the popup, and when you `q` out the board cursor sits on whatever you looked at last.

### Writing

Comments, full description edits and new issues all open your editor: `$VISUAL`, else `$EDITOR`, else `nvim`, else `vi`. What you write is markdown, converted to Jira's format on the way out: paragraphs, headings, bullet and numbered lists, fenced code with a language, quotes, rules, bold, italic, inline code, strikethrough and links.

Creating opens a small template. The first line is the summary, the `labels:`, `points:` and `priority:` lines are optional (leave them blank to skip), and everything under `---` is the description:

```
Rate limit the export endpoint
labels: api, perf
points: 3
priority: High
---
Exports hammer the DB when a big store runs them back to back.

- cap at 1 per minute per store
- return 429 with Retry-After
```

If the create fails (a typo in a field line, or Jira rejects it), the next `c` reopens your draft so nothing is lost.

Editing the full description opens it as markdown. Descriptions holding things markdown can't carry back (tables, images, mentions, panels, colored text, nested lists and so on) are refused rather than silently flattened; use "Append description" on those. Points go to the project's `story_point_field`, so set that under `projects` if your Jira keeps story points in a different custom field than the default.

## Layout

```
lua/jira_tui/
  json.lua     vendored pure-lua json (zero deps)
  config.lua   env + ~/.config/jira-tui/config.lua
  api.lua      curl REST client (blocking, or background for view loads; secrets via curl -K)
  sprint.lua   JQL queries + pagination + field mapping
  model.lua    tree build, filters, create template, ADF -> markdown
  md.lua       markdown -> ANSI (detail view) and markdown -> ADF (writing)
  ansi.lua     SGR colors, utf8-aware width/truncate
  render.lua   columns, issue rows, tab bar, detail text
  term.lua     raw mode, key + mouse decoding
  ui.lua       modals: input, picker, detail pager, $EDITOR handoff, help
  tui.lua      board runtime: state, draw loop, keys, background loads
  state.lua    persisted JQL history + last project
  init.lua     arg parsing + wiring
bin/jira-tui   entry (luajit)
```

The Jira-facing modules (`api`, `sprint`, `model`) are front-end agnostic, no terminal code in them. If you want a different front-end later, that's the seam.

## Development

There's no build step, it's pure Lua. Everything goes through `make`:

| Target | What it does |
|--------|--------------|
| `make test` | run the test suite on LuaJIT (`make test LUA=lua` for stock Lua) |
| `make test-all` | run tests on both luajit and lua |
| `make lint` | luacheck (`luarocks install luacheck` first) |
| `make check` | lint + test |
| `make run ARGS="REF"` | run the TUI |
| `make install` / `make uninstall` | manage the `~/.local/bin` symlink |

Tests live in `test/run.lua`, a no-framework harness that exits non-zero on any failure, so it doubles as the CI gate. It covers the JSON parser, JQL normalization, tree building, ANSI width math, time formatting, ADF conversion both ways (markdown round-trips), and whole TUI flows driven headless by scripted keys against stubbed Jira calls. CI runs lint plus tests on Lua 5.1 / 5.3 / 5.4 and LuaJIT for every push to `main` and every pull request.

## State

Everything lives under `~/.config/jira-tui/`. Settings go in `config.lua`; the JQL history you build up in the `J` picker is saved to `state.json` (deduped, newest first, capped at 50). The `My Issues` project scope is the `my_issues_projects` list in `config.lua`.

## Status

Covers day-to-day Jira work: browsing and filtering, reading issues with comments and links, status changes, assignment, field and description edits, creating issues and sub-tasks, comments, worklogs and closing. Clearing a field (parent, points) isn't supported, and full description edits refuse content markdown can't round-trip.

## Credits

A [Bearded Giant](https://github.com/bearded-giant) project.

## License

MIT — see [LICENSE](LICENSE). Vendors [json.lua](https://github.com/rxi/json.lua) (rxi, MIT).
