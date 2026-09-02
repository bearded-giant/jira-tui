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
  -- tabs to hide from the strip (My Issues never hides)
  hidden_tabs = { "Active Sprint", "Backlog" },
}
```

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

| Key | Action |
|-----|--------|
| `j` / `k` (or arrows, mouse wheel) | move cursor |
| `gg` / `G` | top / bottom |
| `enter` | open issue detail (expands the node if it has subtasks) |
| `space` / `tab` / `o` | expand / collapse node |
| `ctrl-d` / `ctrl-u` | half page down / up |
| `t` | toggle all |
| `M` | My Issues (assigned to you) |
| `S` / `B` | Active Sprint / Backlog |
| `p` | set / change the project (for sprint + backlog) |
| `J` | JQL picker (history, or new query) · `gj` new query |
| `gs` | sort by column |
| `/` | filter loaded rows by summary or key (instant, no refetch) · `BS` clear |
| `x` | show / hide resolved |
| `K` / `m` | issue detail with comments / raw markdown |
| `e` | edit issue: summary, append description, or status |
| `c` | create story in the current project (assigned to you) |
| `d` | close issue via the first done-ish transition |
| `c` (in detail) | expand / collapse comments (start collapsed) |
| `o` (in detail) | pick an attachment, download and open it |
| `s` | change issue status |
| `a` / `A` | assign (user picker) / assign to me |
| `b` / `gx` | open issue in browser |
| `y` / `Y` | copy issue key / url |
| `gb` | copy a git branch name (`pe-1472-add-rate-limit`) |
| `r` | refresh (keeps cursor and filter) |
| `?` / `H` | help |
| `q` | back: closes detail / help / pickers, never the app |
| `Esc` | quit |

`/` opens a prompt; submit empty to clear the filter. The filter is applied to already-fetched rows, so it is instant; on a view truncated by the fetch limit (the `+` in the title count) it only searches what was fetched. In the detail view, `j`/`k` scroll, `ctrl-d`/`ctrl-u` page, `c` expands the comments (collapsed by default), `o` opens an attachment (downloaded to a temp dir, then handed to `open`/`xdg-open`), and `q` returns to the board.

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

View, navigate, JQL, instant filter, rendered descriptions and comments, status changes, assignment, editing (summary / append description), creating stories, and closing issues. Worklog entry has an API method but no key yet.

## Credits

A [Bearded Giant](https://github.com/bearded-giant) project.

## License

MIT — see [LICENSE](LICENSE). Vendors [json.lua](https://github.com/rxi/json.lua) (rxi, MIT).
