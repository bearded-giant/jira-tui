# jira-tui

[![CI](https://github.com/bearded-giant/jira-tui/actions/workflows/ci.yml/badge.svg)](https://github.com/bearded-giant/jira-tui/actions/workflows/ci.yml)

A standalone terminal UI for Jira: sprint board, backlog, and JQL queries rendered as an expandable issue tree. Browse your work without leaving the terminal.

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
  projects = {
    REF = { story_point_field = "customfield_10035" },
  },
  -- scope the My Issues view to these projects (empty = all projects)
  my_issues_projects = { "ABC", "DEF" },
}
```

## Install

```sh
git clone https://github.com/bearded-giant/jira-tui.git
cd jira-tui
make install        # symlinks bin/jira-tui into ~/.local/bin
```

The launcher resolves its own location (following one symlink), so the symlink works from anywhere on your `PATH`. Prefer a different prefix? `make install PREFIX=/usr/local`.

## Usage

```sh
jira-tui                  # My Issues (no project needed)
jira-tui REF              # active sprint for project REF
jira-tui REF --backlog    # backlog
jira-tui --my             # issues assigned to you (scoped to saved projects)
jira-tui REF --jql "status = 'In Progress'"
jira-tui --help           # flags + keys
```

A project key is only needed for the sprint and backlog views. With no arguments it opens My Issues, and you move around from there, no project is ever forced on startup.

### Keys

| Key | Action |
|-----|--------|
| `j` / `k` (or arrows) | move cursor |
| `g` / `G` | top / bottom |
| `o` / `space` / `enter` | expand / collapse node |
| `t` | toggle all |
| `M` | My Issues (assigned to you) |
| `S` / `B` | switch to Active Sprint / Backlog |
| `p` | set / change the project (enables sprint + backlog) |
| `J` | JQL history picker (or `n` for a new query) |
| `/` | filter current view by summary |
| `r` | refresh |
| `K` / `m` | show issue description (markdown) |
| `x` | open issue in browser |
| `q` | quit |

`/` opens a prompt; submit empty to clear the filter. In the detail view, `j`/`k` scroll and `q` returns to the board.

## Layout

```
lua/jira_tui/
  json.lua     vendored pure-lua json (zero deps)
  config.lua   env + ~/.config/jira-tui/config.lua
  api.lua      curl REST client (synchronous, secrets via curl -K)
  sprint.lua   JQL queries + pagination + field mapping
  model.lua    tree build, time format, ADF -> markdown
  ansi.lua     SGR colors, utf8-aware width/truncate
  render.lua   issue tree -> ANSI lines
  tui.lua      raw-mode runtime, input, draw loop, detail pager
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

Tests live in `test/run.lua`, a no-framework harness that exits non-zero on any failure, so it doubles as the CI gate. It covers the JSON parser, JQL normalization, tree building, ANSI width math, time formatting, and ADF conversion. CI runs lint plus tests on Lua 5.1 / 5.3 / 5.4 and LuaJIT for every push to `main` and every pull request.

## State

Everything lives under `~/.config/jira-tui/`. Settings go in `config.lua`; the JQL history you build up in the `J` picker is saved to `state.json` (deduped, newest first, capped at 50). The `My Issues` project scope is the `my_issues_projects` list in `config.lua`.

## Status

MVP: view, navigate, JQL, filter, read descriptions. Editing, status changes, assignment, and creating issues are not implemented yet.

## Credits

A [Bearded Giant](https://github.com/bearded-giant) project.
