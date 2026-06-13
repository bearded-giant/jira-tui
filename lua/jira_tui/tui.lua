local model = require("jira_tui.model")
local render = require("jira_tui.render")
local ansi = require("jira_tui.ansi")
local api = require("jira_tui.api")

local M = {}

local out = io.write

local function term_size()
  local p = io.popen("stty size 2>/dev/null")
  local s = p and p:read("*a") or ""
  if p then p:close() end
  local rows, cols = s:match("(%d+)%s+(%d+)")
  return tonumber(rows) or 24, tonumber(cols) or 80
end

local function raw_on() os.execute("stty raw -echo 2>/dev/null") end
local function raw_off() os.execute("stty sane 2>/dev/null") end
local function alt_on() out("\27[?1049h\27[?25l") end
local function alt_off() out("\27[?1049l\27[?25h") end
local function clear() out("\27[2J\27[H") end
local function moveto(r, c) out("\27[" .. r .. ";" .. (c or 1) .. "H") end

local function read_key()
  local c = io.read(1)
  if not c then return "q" end
  if c == "\27" then
    local c2 = io.read(1)
    if c2 == "[" then
      local c3 = io.read(1)
      local map = { A = "up", B = "down", C = "right", D = "left" }
      return map[c3] or "esc"
    end
    return "esc"
  end
  if c == "\13" or c == "\10" then return "enter" end
  if c == " " then return "space" end
  if c == "\3" then return "q" end -- ctrl-c
  return c
end

-- one-line input at the bottom row; returns string or nil if cancelled (esc)
local function prompt(rows, label, initial)
  local buf = initial or ""
  while true do
    moveto(rows, 1)
    out("\27[K" .. ansi.sgr(label, ansi.fg.bright_yellow) .. buf .. "\27[K")
    local c = io.read(1)
    if not c then return nil end
    if c == "\13" or c == "\10" then return buf end
    if c == "\27" then return nil end
    if c == "\127" or c == "\8" then
      buf = buf:sub(1, -2)
    elseif c == "\3" then
      return nil
    elseif c:byte() >= 32 then
      buf = buf .. c
    end
  end
end

local function flash(rows, msg, color)
  moveto(rows, 1)
  out("\27[K" .. ansi.sgr(msg, color or ansi.fg.bright_yellow))
end

-- scrollable markdown pager for issue detail
local function pager(rows, cols, title, text)
  local lines = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    -- ponytail: hard-truncate overflow, no word-wrap. add wrap if descriptions need it.
    -- (don't reassign the for-var -- it's const in lua 5.4+)
    lines[#lines + 1] = ansi.width(raw) > cols - 1 and ansi.truncate(raw, cols - 1) or raw
  end
  local top = 1
  local body = rows - 2
  while true do
    clear()
    moveto(1, 1)
    out(ansi.sgr(" " .. title .. " ", ansi.fg.black, 47))
    for i = 0, body - 1 do
      moveto(i + 2, 1)
      out("\27[K" .. (lines[top + i] or ""))
    end
    moveto(rows, 1)
    out(ansi.sgr(" j/k scroll  q back ", ansi.fg.gray))
    local k = read_key()
    if k == "q" or k == "esc" then return end
    if (k == "j" or k == "down") and top < #lines - body + 1 then top = top + 1 end
    if (k == "k" or k == "up") and top > 1 then top = top - 1 end
    if k == "g" then top = 1 end
    if k == "G" then top = math.max(1, #lines - body + 1) end
  end
end

-- pick a jql from history or type a new one. returns the jql string or nil.
-- history items keep their original (possibly multiline) text; display collapses it.
local function jql_picker(rows, cols, history)
  local sel = 1
  local body = rows - 3
  while true do
    clear()
    moveto(1, 1)
    out(ansi.sgr(" JQL history ", ansi.fg.black, 47))
    moveto(2, 1)
    out(ansi.sgr("  enter: run    n: new query    q: cancel", ansi.fg.gray))
    if #history == 0 then
      moveto(4, 1)
      out(ansi.sgr("  no history -- press n for a new query", ansi.fg.gray))
    end
    for i = 1, math.min(#history, body) do
      moveto(i + 2, 1)
      local label = ansi.truncate((history[i]:gsub("%s+", " ")), cols - 4)
      local mark = i == sel and ansi.sgr("▌ ", ansi.fg.bright_cyan) or "  "
      out("\27[K" .. mark .. (i == sel and ansi.sgr(label, ansi.BOLD) or label))
    end
    local k = read_key()
    if k == "q" or k == "esc" then return nil end
    if k == "n" or k == "/" then
      local q = prompt(rows, "JQL> ", "")
      return (q and q ~= "") and q or nil
    end
    if #history > 0 then
      if (k == "j" or k == "down") and sel < #history then sel = sel + 1 end
      if (k == "k" or k == "up") and sel > 1 then sel = sel - 1 end
      if k == "g" then sel = 1 end
      if k == "G" then sel = #history end
      if k == "enter" then return history[sel] end
    end
  end
end

function M.run(opts)
  local state = {
    roots = {}, flat = {}, cursor = 1, scroll = 0,
    view = opts.initial_view, project = opts.project, filter = nil,
  }

  local function reflatten()
    state.flat = model.flatten(state.roots)
    if state.cursor > #state.flat then state.cursor = math.max(1, #state.flat) end
  end

  local function load(view, filter)
    local issues, err = opts.load(view, filter, state.project)
    if err then return err end
    state.view = view
    state.filter = filter
    state.roots = model.build_issue_tree(issues or {})
    -- expand roots that have children so the board isn't all collapsed
    for _, n in ipairs(state.roots) do
      if n.children and #n.children > 0 then n.expanded = true end
    end
    state.cursor = 1
    state.scroll = 0
    reflatten()
    return nil
  end

  local function draw()
    local rows, cols = term_size()
    local body = rows - 2
    if state.cursor <= state.scroll then state.scroll = state.cursor - 1 end
    if state.cursor > state.scroll + body then state.scroll = state.cursor - body end
    if state.scroll < 0 then state.scroll = 0 end

    clear()
    moveto(1, 1)
    out(render.header({ view = state.view, project = state.project, count = #state.flat }, cols))

    for i = 1, body do
      local idx = state.scroll + i
      local entry = state.flat[idx]
      moveto(i + 1, 1)
      out("\27[K")
      if entry then out(render.issue_line(entry, cols, idx == state.cursor)) end
    end

    moveto(rows, 1)
    local hint = state.filter and ("filter: " .. state.filter .. "  ") or ""
    out(ansi.sgr(hint .. "[o]toggle [t]all [K]detail [x]open [p]roject", ansi.fg.gray))
  end

  local function cur_node()
    local e = state.flat[state.cursor]
    return e and e.node
  end

  local function toggle_all(expand)
    local function walk(nodes)
      for _, n in ipairs(nodes) do
        if n.children and #n.children > 0 then n.expanded = expand; walk(n.children) end
      end
    end
    walk(state.roots)
  end

  raw_on(); alt_on()
  local ok, err = pcall(function()
    local initial_err = load(state.view, nil)
    if initial_err then
      local rows = term_size()
      flash(rows, "load error: " .. initial_err, ansi.fg.red)
      io.read(1)
    end

    local all_expanded = true
    while true do
      draw()
      local rows, cols = term_size()
      local k = read_key()

      if k == "q" then break
      elseif k == "j" or k == "down" then
        if state.cursor < #state.flat then state.cursor = state.cursor + 1 end
      elseif k == "k" or k == "up" then
        if state.cursor > 1 then state.cursor = state.cursor - 1 end
      elseif k == "g" then state.cursor = 1
      elseif k == "G" then state.cursor = #state.flat
      elseif k == "o" or k == "space" or k == "enter" then
        local n = cur_node()
        if n and n.children and #n.children > 0 then n.expanded = not n.expanded; reflatten() end
      elseif k == "t" then
        all_expanded = not all_expanded
        toggle_all(all_expanded)
        reflatten()
      elseif k == "r" then
        flash(rows, "refreshing…"); local e = load(state.view, state.filter)
        if e then flash(rows, "error: " .. e, ansi.fg.red); io.read(1) end
      elseif k == "M" then
        local e = load("My Issues", nil); if e then flash(rows, e, ansi.fg.red); io.read(1) end
      elseif k == "S" or k == "B" then
        local view = k == "S" and "Active Sprint" or "Backlog"
        if not state.project then
          flash(rows, "no project set -- press p to set one", ansi.fg.yellow); io.read(1)
        else
          local e = load(view, nil); if e then flash(rows, e, ansi.fg.red); io.read(1) end
        end
      elseif k == "p" then
        local pk = prompt(rows, "project> ", state.project or "")
        if pk and pk ~= "" then
          state.project = pk:upper()
          local e = load("Active Sprint", nil); if e then flash(rows, e, ansi.fg.red); io.read(1) end
        end
      elseif k == "J" then
        local q = jql_picker(rows, cols, opts.state and opts.state.data.jql_history or {})
        if q and q ~= "" then
          local e = load("JQL:" .. q, nil)
          if e then flash(rows, e, ansi.fg.red); io.read(1)
          elseif opts.state then opts.state.add_jql(q) end
        end
      elseif k == "/" then
        local f = prompt(rows, "filter> ", state.filter or "")
        if f ~= nil then local e = load(state.view, f ~= "" and f or nil); if e then flash(rows, e, ansi.fg.red); io.read(1) end end
      elseif k == "K" or k == "m" then
        local n = cur_node()
        if n then
          flash(rows, "loading " .. n.key .. "…")
          local issue = api.get_issue(n.key)
          local md = "(no description)"
          if type(issue) == "table" and issue.fields then
            md = model.adf_to_markdown(issue.fields.description)
            if md == "" then md = "(no description)" end
          end
          pager(rows, cols, n.key .. "  " .. (n.summary or ""), md)
        end
      elseif k == "x" then
        local n = cur_node()
        if n then
          local url = require("jira_tui.config").options.jira.base .. "/browse/" .. n.key
          os.execute(string.format("(open %q || xdg-open %q) >/dev/null 2>&1 &", url, url))
        end
      end
    end
  end)

  alt_off(); raw_off()
  if not ok then io.stderr:write("jira-tui crashed: " .. tostring(err) .. "\n") end
end

return M
