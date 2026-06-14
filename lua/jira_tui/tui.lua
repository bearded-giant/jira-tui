local term = require("jira_tui.term")
local render = require("jira_tui.render")
local ui = require("jira_tui.ui")
local ansi = require("jira_tui.ansi")
local api = require("jira_tui.api")
local model = require("jira_tui.model")
local version = require("jira_tui.version")

local M = {}
local C = ansi.color

local function sort_roots(roots, col, dir)
  local field = ({ time = "time_spent", points = "story_points" })[col] or col
  table.sort(roots, function(a, b)
    local va, vb = a[field], b[field]
    if va == vb then return false end
    if va == nil then return dir == "asc" end
    if vb == nil then return dir ~= "asc" end
    if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
    if dir == "desc" then return va > vb end
    return va < vb
  end)
end

function M.run(opts)
  local persist = opts.state
  local st = {
    view = opts.initial_view, project = opts.project, filter = nil,
    roots = {}, flat = {}, cursor = 1, scroll = 0, count = 0,
    sort_col = nil, sort_dir = nil, raw = {}, message = nil,
    hide_resolved = persist and persist.data.hide_resolved,
    rows = 24, cols = 80,
  }
  if st.hide_resolved == nil then st.hide_resolved = true end
  st.rows, st.cols = term.size()
  local draw -- forward decl (load_view shows a loading footer via draw)

  -- nearest non-spacer index from `from` walking `dir` (+1/-1)
  local function step(from, dir)
    local i = from + dir
    while st.flat[i] and st.flat[i].spacer do i = i + dir end
    return st.flat[i] and i or from
  end

  local function reflatten()
    st.flat = model.flatten(st.roots, true)
    if st.cursor > #st.flat then st.cursor = #st.flat end
    if st.cursor < 1 then st.cursor = 1 end
    if st.flat[st.cursor] and st.flat[st.cursor].spacer then st.cursor = step(st.cursor, -1) end
  end

  local function rebuild()
    local issues = {}
    for _, iss in ipairs(st.raw) do
      if not (st.hide_resolved and iss.status_category == "Done") then issues[#issues + 1] = iss end
    end
    st.count = #issues
    st.roots = model.build_issue_tree(issues)
    if st.sort_col then sort_roots(st.roots, st.sort_col, st.sort_dir) end
    for _, n in ipairs(st.roots) do
      if n.children and #n.children > 0 then n.expanded = true end
    end
    reflatten()
  end

  local function load_view(view, filter)
    st.loading = "loading " .. view:gsub("^JQL:.*", "JQL") .. "…"
    if draw then draw() end
    local issues, err = opts.load(view, filter, st.project)
    st.loading = nil
    if err then st.message = err; return false end
    st.view, st.filter, st.raw = view, filter, issues or {}
    st.cursor, st.scroll, st.message = 1, 0, nil
    rebuild()
    if persist then persist.remember(view, st.project) end
    return true
  end

  local function cur_node()
    local e = st.flat[st.cursor]
    return e and not e.spacer and e.node or nil
  end

  -- diff renderer: build every board row, emit only the rows that changed.
  -- a cursor move repaints ~2 rows, not the whole screen -> no flicker, cheap.
  st.prev = st.prev or {}
  draw = function()
    local rows, cols = term.size()
    local full = false
    if rows ~= st.rows or cols ~= st.cols or ui.consume_dirty() then
      st.rows, st.cols, st.prev, full = rows, cols, {}, true
    end
    local bw = math.max(50, cols - 2)
    local bh = math.max(14, rows - 2)
    local top = math.max(1, math.floor((rows - bh) / 2))
    local left = math.max(1, math.floor((cols - bw) / 2))
    local iw = bw - 2
    local sky = ansi.fgtext("│", C.sky)
    local function interior(content) return sky .. ansi.padline(content, iw) .. sky end

    local frame = {} -- frame[r] = full row string (relative row 0..bh-1)
    local title = "jira-tui — " .. st.view ..
      (st.project and ("  ·  " .. st.project) or "") .. "   (" .. st.count .. ")"
    local t = " " .. title .. " "
    frame[0] = ansi.fgtext("╭─", C.sky) .. ansi.fgtext(t, C.text, ansi.BOLD)
      .. ansi.fgtext(string.rep("─", math.max(0, bw - 3 - ansi.width(t))) .. "╮", C.sky)
    frame[1] = interior("")
    frame[2] = interior(render.tab_bar(st.view, st.hidden))
    frame[3] = interior("")

    if st.view == "Help" then
      local hl = ui.help_lines(iw)
      for r = 4, bh - 3 do frame[r] = interior(hl[r - 3] or "") end
    else
      frame[4] = interior(render.column_header(iw, st.sort_col, st.sort_dir))
      local body_top, body_bot = 5, bh - 3
      local body = body_bot - body_top + 1
      if st.cursor <= st.scroll then st.scroll = st.cursor - 1 end
      if st.cursor > st.scroll + body then st.scroll = st.cursor - body end
      if st.scroll < 0 then st.scroll = 0 end
      for i = 1, body do
        local e = st.flat[st.scroll + i]
        frame[body_top + i - 1] = interior((e and not e.spacer)
          and render.issue_line(e.node, e.depth, iw, st.scroll + i == st.cursor, e.last) or "")
      end
    end

    frame[bh - 2] = interior(st.message
      and ansi.bgtext("  " .. ansi.truncate(st.message, bw - 6) .. " ", C.base, C.red, ansi.BOLD)
      or render.hint_line(st.view, st.filter))

    local vtxt = " v" .. version .. " "
    local ltxt = st.loading and (" ● " .. st.loading .. " ") or ""
    local fill = math.max(0, bw - 2 - ansi.width(ltxt) - ansi.width(vtxt))
    frame[bh - 1] = ansi.fgtext("╰", C.sky)
      .. (ltxt ~= "" and ansi.fgtext(ltxt, C.yellow, ansi.BOLD) or "")
      .. ansi.fgtext(string.rep("─", fill), C.sky)
      .. ansi.fgtext(vtxt, C.overlay) .. ansi.fgtext("╯", C.sky)

    local buf = {}
    if full then buf[#buf + 1] = "\27[2J" end
    for r = 0, bh - 1 do
      if frame[r] ~= st.prev[r] then
        buf[#buf + 1] = "\27[" .. (top + r) .. ";" .. (left) .. "H" .. frame[r]
        st.prev[r] = frame[r]
      end
    end
    if #buf > 0 then term.out(table.concat(buf)) end
  end

  local function toggle_all(expand)
    local function walk(ns) for _, n in ipairs(ns) do
      if n.children and #n.children > 0 then n.expanded = expand; walk(n.children) end
    end end
    walk(st.roots)
  end

  local function ensure_project()
    if st.project then return true end
    local p = ui.input("Project key", { value = (persist and persist.data.last_project) or "", width = 40 })
    if p and p ~= "" then st.project = p:upper(); return true end
    return false
  end

  local function run_jql(q)
    if not q or q == "" then return end
    if load_view("JQL:" .. q) and persist then persist.add_jql(q) end
  end

  local NEWQ = "＋ New query…"
  local function pick_jql()
    local hist = (persist and persist.data.jql_history) or {}
    local items = { NEWQ }
    for _, q in ipairs(hist) do items[#items + 1] = q end
    local choice = ui.select("JQL", items,
      { format = function(s) return s == NEWQ and s or (s:gsub("%s+", " ")) end })
    if not choice then return end
    if choice == NEWQ then run_jql(ui.input("New JQL", { multiline = true }))
    else run_jql(choice) end
  end

  local function open_browser(n)
    if not n then return end
    local url = require("jira_tui.config").options.jira.base .. "/browse/" .. n.key
    os.execute(string.format("(open %q || xdg-open %q) >/dev/null 2>&1 &", url, url))
  end

  local interactive = term.isatty()
  term.raw_on(); term.enter(); term.clear()
  local ok, err = pcall(function()
    load_view(st.view, nil)
    draw()

    while true do
      local k = term.read_key()
      if k == nil then
        -- no input: timeout on a tty (poll for resize), EOF on a pipe (quit)
        if not interactive then break end
        local r, c = term.size()
        if r ~= st.rows or c ~= st.cols then draw() end
      else
      local n = cur_node()

      if k == "q" or k == "esc" then break
      elseif k == "j" or k == "down" then st.cursor = step(st.cursor, 1)
      elseif k == "k" or k == "up" then st.cursor = step(st.cursor, -1)
      elseif k == "wheeldown" then for _ = 1, 3 do st.cursor = step(st.cursor, 1) end
      elseif k == "wheelup" then for _ = 1, 3 do st.cursor = step(st.cursor, -1) end
      elseif k == "G" then st.cursor = step(#st.flat + 1, -1)
      elseif k == "enter" or k == " " or k == "tab" then
        if n and n.children and #n.children > 0 then n.expanded = not n.expanded; reflatten() end
      elseif k == "b" then open_browser(n)
      elseif k == "t" then
        local any = false
        for _, r in ipairs(st.roots) do if r.expanded then any = true end end
        toggle_all(not any); reflatten()
      elseif k == "M" then load_view("My Issues", nil)
      elseif k == "S" then if ensure_project() then load_view("Active Sprint", nil) end
      elseif k == "B" then if ensure_project() then load_view("Backlog", nil) end
      elseif k == "p" then
        local p = ui.input("Project key", { value = st.project or "", width = 40 })
        if p and p ~= "" then st.project = p:upper(); load_view("Active Sprint", nil) end
      elseif k == "J" then pick_jql()
      elseif k == "H" then st.view = "Help"; st.message = nil
      elseif k == "/" then
        local f = ui.input("Filter (summary ~)", { value = st.filter or "", width = 50 })
        if f ~= nil then load_view(st.view == "Help" and "My Issues" or st.view, f ~= "" and f or nil) end
      elseif k == "bs" then if st.filter then load_view(st.view, nil) end
      elseif k == "x" then
        st.hide_resolved = not st.hide_resolved
        if persist then persist.data.hide_resolved = st.hide_resolved; persist.save() end
        rebuild()
      elseif k == "K" or k == "m" then
        if n then
          st.message = "loading " .. n.key .. "…"; draw()
          local issue = api.get_issue(n.key)
          local md = (type(issue) == "table" and issue.fields)
            and model.adf_to_markdown(issue.fields.description) or ""
          if md == "" then md = "(no description)" end
          st.message = nil
          ui.detail(n.key .. "  " .. (n.summary or ""), md)
        end
      elseif k == "y" then
        if n then
          os.execute(string.format("printf %%s %q | pbcopy 2>/dev/null", n.key))
          st.message = "copied " .. n.key
        end
      elseif k == "r" then load_view(st.view, st.filter)
      elseif k == "left" or k == "right" then
        local order = { "My Issues", "JQL", "Active Sprint", "Backlog", "Help" }
        local idx = 1
        for i, v in ipairs(order) do if v == st.view then idx = i end end
        idx = ((idx - 1 + (k == "right" and 1 or -1)) % #order) + 1
        local nv = order[idx]
        if nv == "Active Sprint" or nv == "Backlog" then
          if ensure_project() then load_view(nv, nil) end
        elseif nv == "JQL" then pick_jql()
        elseif nv == "Help" then st.view = "Help"; st.message = nil
        else load_view(nv, nil) end
      elseif k == "g" then
        local nk; repeat nk = term.read_key() until nk
        if nk == "g" then st.cursor = 1
        elseif nk == "j" then run_jql(ui.input("New JQL", { multiline = true }))
        elseif nk == "s" then
          local cols = { { f = "key", l = "Key" }, { f = "summary", l = "Title" },
            { f = "assignee", l = "Assignee" }, { f = "time", l = "Time" }, { f = "status", l = "Status" } }
          local choice = ui.select("Sort by", cols, { format = function(c) return c.l end })
          if choice then
            if st.sort_col ~= choice.f then st.sort_col, st.sort_dir = choice.f, "asc"
            elseif st.sort_dir == "asc" then st.sort_dir = "desc"
            else st.sort_col, st.sort_dir = nil, nil end
            rebuild()
          end
        end
      elseif k == "s" or k == "c" or k == "d" or k == "e" or k == "a" then
        st.message = "'" .. k .. "' (edit/create/status/assign) lives in the nvim plugin, not the TUI"
      end
      draw()
      end
    end
  end)

  term.leave(); term.raw_off()
  if not ok then io.stderr:write("jira-tui crashed: " .. tostring(err) .. "\n") end
end

return M
