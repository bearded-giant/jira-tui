# jira-tui

[![CI](https://github.com/bearded-giant/jira-tui/actions/workflows/ci.yml/badge.svg)](https://github.com/bearded-giant/jira-tui/actions/workflows/ci.yml)

A standalone terminal UI for Jira: sprint board, backlog, and JQL queries rendered as an expandable issue tree. It's a port of the [jim.nvim](https://github.com/bearded-giant/jim.nvim) Neovim plugin's core, lifted out of the editor so you can run the same board as its own process.

## Why

jim.nvim's Jira logic, the REST client, the parent/child tree builder, the ADF-to-markdown converter, was all good Lua trapped inside Neovim. This pulls that core out, strips the `vim.*` calls, and puts a plain ANSI front-end on it. Same board, no editor required.

## Requirements

LuaJIT (or Lua 5.1+) and `curl`. Nothing else, JSON parsing is vendored, so there's no `luarocks install` step. On macOS that's `brew install luajit`.

## Setup

Point it at your Jira instance with environment variables:

```sh
export JIRA_BASE=https://your-domain.atlassian.net
export JIRA_EMAIL=you@example.com
export JIRA_TOKEN=your_api_token   # https://id.atlassian.com/manage-profile/security/api-tokens
```

`JIRA_API_TOKEN` is also accepted for the token (that's the variable jim.nvim uses), so an existing jim.nvim shell setup works as-is once `JIRA_BASE` is set.

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
jira-tui REF              # active sprint for project REF
jira-tui REF --backlog    # backlog
jira-tui --my             # issues assigned to you, across projects
jira-tui REF --jql "status = 'In Progress'"
jira-tui --help           # flags + keys
```

### Keys

| Key | Action |
|-----|--------|
| `j` / `k` (or arrows) | move cursor |
| `g` / `G` | top / bottom |
| `o` / `space` / `enter` | expand / collapse node |
| `t` | toggle all |
| `S` / `B` | switch to Active Sprint / Backlog |
| `J` | run a JQL query |
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

The Jira-facing modules (`api`, `sprint`, `model`) are front-end agnostic, the same shape jim.nvim uses minus the `vim.*` calls. If you want a different front-end later, that's the seam.

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

## Status

MVP: view, navigate, JQL, filter, read descriptions. Editing, status changes, assignment, and creating issues still live in the nvim plugin, not yet ported.

## Credits

A [Bearded Giant](https://github.com/bearded-giant) project, ported from [jim.nvim](https://github.com/bearded-giant/jim.nvim).
