# jira-tui

A standalone terminal UI for Jira — sprint board, backlog, and JQL queries with an expandable issue tree. It's a port of the [jim.nvim](https://github.com/bearded-giant/jim.nvim) Neovim plugin's core into a process you can run on its own, no editor required.

## Why

jim.nvim's JIRA logic (the REST client, the parent/child tree builder, the ADF-to-markdown converter) was all perfectly good Lua trapped inside Neovim. This pulls that core out and puts a plain ANSI front-end on it, so you get the same board outside the editor.

## Requirements

LuaJIT (or Lua 5.1+) and `curl`. That's it — JSON parsing is vendored, so there's nothing to `luarocks install`. On macOS: `brew install luajit`.

## Setup

Point it at your Jira instance with environment variables:

```sh
export JIRA_BASE=https://your-domain.atlassian.net
export JIRA_EMAIL=you@example.com
export JIRA_TOKEN=your_api_token   # https://id.atlassian.com/manage-profile/security/api-tokens
```

Or drop a config file at `~/.config/jira-tui/config.lua` that returns a table (env vars override it, so you can keep the token out of the file):

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

Symlink the launcher somewhere on your `PATH`:

```sh
ln -s "$PWD/bin/jira-tui" ~/.local/bin/jira-tui
```

The launcher resolves its own location (following one symlink), so the symlink works fine.

## Usage

```sh
jira-tui REF              # active sprint for project REF
jira-tui REF --backlog    # backlog
jira-tui --my             # issues assigned to you, across projects
jira-tui REF --jql "status = 'In Progress'"
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

The Jira-facing modules (`api`, `sprint`, `model`) are front-end agnostic — the same shape jim.nvim uses, minus the `vim.*` calls. If you want to add a different front-end later, that's the seam.

## Status

MVP: view, navigate, JQL, filter, read descriptions. Editing, status changes, and creating issues live in the nvim plugin for now — not yet ported.

## Test

```sh
luajit test/run.lua
```
