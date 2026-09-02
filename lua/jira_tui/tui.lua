local term = require("jira_tui.term")
local render = require("jira_tui.render")
local ui = require("jira_tui.ui")
local ansi = require("jira_tui.ansi")
local api = require("jira_tui.api")
local config = require("jira_tui.config")
local model = require("jira_tui.model")
local version = require("jira_tui.version")

local M = {}
local C = ansi.color

local function sort_roots(roots, col, dir)
  -- age is derived from created: same key, inverted order (older = bigger age)
  local field = col == "age" and "created" or col
  if col == "age" then dir = dir == "asc" and "desc" or "asc" end
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
  st.my_projects = opts.my_projects or {}
  st.hidden = {}
  for _, name in ipairs(opts.hidden_tabs or {}) do st.hidden[name] = true end
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

  local function cur_node()
    local e = st.flat[st.cursor]
    return e and not e.spacer and e.node or nil
  end

  -- rebuild tree from st.raw. keep_key: re-seat the cursor on that issue if it is still shown.
  -- st.filter applies here, client-side over fetched rows -- no refetch per keystroke.
  local function rebuild(keep_key)
    local issues = {}
    for _, iss in ipairs(st.raw) do
      if not (st.hide_resolved and iss.status_category == "Done") and model.matches(iss, st.filter) then
        issues[#issues + 1] = iss
      end
    end
    st.count = #issues
    st.roots = model.build_issue_tree(issues)
    if st.sort_col then sort_roots(st.roots, st.sort_col, st.sort_dir) end
    for _, n in ipairs(st.roots) do
      if n.children and #n.children > 0 then n.expanded = true end
    end
    reflatten()
    if keep_key then
      for i, e in ipairs(st.flat) do
        if e.node and e.node.key == keep_key then st.cursor = i; return true end
      end
    end
    return false
  end

  -- filter is client-side (rebuild); a refresh of the same view keeps it, a view switch clears it
  local function load_view(view, filter)
    local keep = view == st.view and cur_node() or nil
    local old_scroll = st.scroll
    st.loading = "loading " .. render.view_label(view) .. "…"
    if draw then draw() end
    local issues, err, truncated = opts.load(view, nil, st.project)
    st.loading = nil
    if err then st.message = err; return false end
    st.view, st.filter, st.raw, st.truncated = view, filter, issues or {}, truncated
    st.cursor, st.scroll, st.message = 1, 0, nil
    if rebuild(keep and keep.key) then st.scroll = old_scroll end -- draw() clamps if it no longer fits
    if persist then persist.remember(view, st.project) end
    return true
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
    local function interior(content) return sky .. ansi.fitline(content, iw) .. sky end

    local frame = {} -- frame[r] = full row string (relative row 0..bh-1)
    local tab = st.help and "Help" or render.view_label(st.view)
    local module = tab
    local proj = st.project
      or (st.view == "My Issues" and #st.my_projects > 0 and table.concat(st.my_projects, ",") or nil)
      or "all"
    local title = module .. "   - Project: " .. proj .. "   (" .. st.count .. (st.truncated and "+" or "") .. ")"
    frame[0] = render.box_top(bw, title)
    frame[1] = interior("")
    frame[2] = interior(render.tab_bar(tab, st.hidden, iw))
    frame[3] = interior("")

    if st.help then
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
      if #st.flat == 0 and not st.loading then
        frame[body_top + 1] = interior(ansi.fgtext("     (no issues)", C.overlay, ansi.ITALIC))
      end
    end

    frame[bh - 2] = interior(st.message
      and ansi.bgtext("  " .. ansi.truncate(st.message, bw - 6) .. " ", C.base, st.message_ok and C.green or C.red, ansi.BOLD)
      or render.hint_line(st.view, st.filter, iw))

    local vtxt = " v" .. version .. " "
    local ltxt = st.loading and (" ● " .. st.loading .. " ") or ""
    local ptxt = ""
    if not st.help and #st.flat > 0 then
      local cur, tot = 0, 0
      for i, e in ipairs(st.flat) do
        if not e.spacer then
          tot = tot + 1
          if i <= st.cursor then cur = cur + 1 end
        end
      end
      ptxt = " " .. cur .. "/" .. tot .. " "
    end
    local fill = math.max(0, bw - 2 - ansi.width(ltxt) - ansi.width(ptxt) - ansi.width(vtxt))
    frame[bh - 1] = ansi.fgtext("╰", C.sky)
      .. (ltxt ~= "" and ansi.fgtext(ltxt, C.yellow, ansi.BOLD) or "")
      .. ansi.fgtext(string.rep("─", fill), C.sky)
      .. ansi.fgtext(ptxt, C.overlay)
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
    if load_view(render.jql_view(q)) and persist then persist.add_jql(q) end
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
    local url = config.options.jira.base .. "/browse/" .. n.key
    os.execute(string.format("(open %q || xdg-open %q) >/dev/null 2>&1 &", url, url))
  end

  local function show_detail(n, mode)
    if not n then return end
    st.message = "loading " .. n.key .. "…"; draw()
    local issue, err = api.get_issue(n.key)
    local comments = mode ~= "markdown" and api.get_comments(n.key, 15) or nil
    st.message = nil
    if err or type(issue) ~= "table" or type(issue.fields) ~= "table" then
      local jira_err = type(issue) == "table" and type(issue.errorMessages) == "table"
        and table.concat(issue.errorMessages, "; ")
      st.message = n.key .. ": " .. (err or jira_err or "unexpected response")
      return
    end
    draw() -- clear the "loading" footer before the popup covers the board
    local project = type(issue.fields.project) == "table" and issue.fields.project.key or n.key:match("^(.-)%-")
    ui.detail(n.key .. "  " .. (n.summary or ""),
      render.detail_text(issue, config.get_project_config(project), mode, comments))
  end

  -- clipboard chain; honest success only
  local function yank(txt, what)
    local copied = false
    for _, tool in ipairs({ "pbcopy", "xclip -selection clipboard", "wl-copy" }) do
      local bin = tool:match("^%S+")
      local ok = os.execute("command -v " .. bin .. " >/dev/null 2>&1")
      if ok == true or ok == 0 then
        ok = os.execute(string.format("printf %%s %q | %s 2>/dev/null", txt, tool))
        if ok == true or ok == 0 then copied = true; break end
      end
    end
    st.message = copied and ("copied " .. what) or "copy failed: no clipboard tool (pbcopy / xclip / wl-copy)"
    st.message_ok = copied
  end

  local function do_assign(n, account_id, label)
    st.message = "assigning " .. n.key .. "…"; draw()
    local _, aerr = api.assign_issue(n.key, account_id)
    if aerr then st.message = n.key .. ": " .. aerr; return end
    load_view(st.view, st.filter)
    st.message = n.key .. " → " .. label
    st.message_ok = true
  end

  local function assign_picker(n)
    if not n then return end
    st.message = "loading assignable users…"; draw()
    local users, uerr = api.get_assignable(n.key)
    st.message = nil
    if uerr or type(users) ~= "table" or #users == 0 then
      st.message = n.key .. ": " .. (uerr or "no assignable users"); return
    end
    draw()
    local choice = ui.select("Assign: " .. n.key .. "  (" .. (n.assignee or "Unassigned") .. ")", users,
      { format = function(u) return u.displayName or "?" end })
    if choice then do_assign(n, choice.accountId, choice.displayName) end
  end

  local function assign_me(n)
    if not n then return end
    st.message = "resolving current user…"; draw()
    local me, merr = api.get_myself()
    st.message = nil
    if merr or type(me) ~= "table" or not me.accountId then
      st.message = merr or "cannot resolve current user"; return
    end
    do_assign(n, me.accountId, me.displayName or "me")
  end

  local function toggle_expand(n)
    if n and n.children and #n.children > 0 then n.expanded = not n.expanded; reflatten(); return true end
    return false
  end

  local function change_status(n)
    if not n then return end
    st.message = "loading transitions for " .. n.key .. "…"; draw()
    local trs, terr = api.get_transitions(n.key)
    st.message = nil
    if terr then st.message = n.key .. ": " .. terr; return end
    if type(trs) ~= "table" or #trs == 0 then st.message = n.key .. ": no transitions available"; return end
    draw()
    local choice = ui.select("Status: " .. n.key .. "  (" .. (n.status or "?") .. ")", trs, {
      format = function(t)
        local to = type(t.to) == "table" and t.to.name or nil
        return (to and to ~= t.name) and (t.name .. "  →  " .. to) or t.name
      end,
    })
    if not choice then return end
    st.message = "moving " .. n.key .. "…"; draw()
    local _, xerr = api.transition_issue(n.key, choice.id)
    if xerr then st.message = n.key .. ": " .. xerr; return end
    load_view(st.view, st.filter)
    st.message = n.key .. " → " .. (type(choice.to) == "table" and choice.to.name or choice.name)
    st.message_ok = true
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
      st.message_ok = false

      -- help is an overlay: only quit/close and tab keys get through, so data keys
      -- (r, x, /, ...) can't fire loaders or move the cursor while it's up
      local swallowed = false
      if st.help then
        swallowed = true
        if k == "ctrl-c" then break
        elseif k == "q" or k == "esc" or k == "H" or k == "?" then st.help = false
        elseif ({ M = 1, S = 1, B = 1, J = 1, left = 1, right = 1 })[k] then st.help = false; swallowed = false
        end
      end

      if swallowed then -- redraw only
      elseif k == "esc" or k == "ctrl-c" then break
      elseif k == "q" then st.message = "q goes back · Esc quits" -- q never closes the tui
      elseif k == "j" or k == "down" then st.cursor = step(st.cursor, 1)
      elseif k == "k" or k == "up" then st.cursor = step(st.cursor, -1)
      elseif k == "wheeldown" then for _ = 1, 3 do st.cursor = step(st.cursor, 1) end
      elseif k == "wheelup" then for _ = 1, 3 do st.cursor = step(st.cursor, -1) end
      elseif k == "G" then st.cursor = step(#st.flat + 1, -1)
      elseif k == " " or k == "tab" or k == "o" then toggle_expand(n)
      elseif k == "ctrl-d" or k == "pgdn" then
        for _ = 1, math.max(1, math.floor((st.rows - 8) / 2)) do st.cursor = step(st.cursor, 1) end
      elseif k == "ctrl-u" or k == "pgup" then
        for _ = 1, math.max(1, math.floor((st.rows - 8) / 2)) do st.cursor = step(st.cursor, -1) end
      elseif k == "enter" then if not toggle_expand(n) then show_detail(n) end
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
      elseif k == "H" or k == "?" then st.help = true; st.message = nil
      elseif k == "/" then
        local f = ui.input("Filter (summary / key)", { value = st.filter or "", width = 50 })
        if f ~= nil then st.filter = f ~= "" and f or nil; rebuild(n and n.key) end
      elseif k == "bs" then
        if st.filter then st.filter = nil; rebuild(n and n.key) end
      elseif k == "x" then
        st.hide_resolved = not st.hide_resolved
        if persist then persist.data.hide_resolved = st.hide_resolved; persist.save() end
        rebuild(n and n.key)
      elseif k == "K" then show_detail(n, "fields")
      elseif k == "m" then show_detail(n, "markdown")
      elseif k == "y" then
        if n then yank(n.key, n.key) end
      elseif k == "Y" then
        if n then yank(config.options.jira.base .. "/browse/" .. n.key, n.key .. " url") end
      elseif k == "a" then assign_picker(n)
      elseif k == "A" then assign_me(n)
      elseif k == "r" then load_view(st.view, st.filter)
      elseif k == "left" or k == "right" then
        local order = {} -- cycle order = render.TABS, minus hidden
        for _, tabdef in ipairs(render.TABS) do
          if tabdef.name == "My Issues" or not st.hidden[tabdef.name] then order[#order + 1] = tabdef.name end
        end
        local cur = st.help and "Help" or render.view_label(st.view)
        local idx = 1
        for i, v in ipairs(order) do if v == cur then idx = i end end
        idx = ((idx - 1 + (k == "right" and 1 or -1)) % #order) + 1
        local nv = order[idx]
        if nv == "Active Sprint" or nv == "Backlog" then
          if ensure_project() then load_view(nv, nil) end
        elseif nv == "JQL" then pick_jql()
        elseif nv == "Help" then st.help = true; st.message = nil
        else load_view(nv, nil) end
      elseif k == "g" then
        local nk; repeat nk = term.read_key() until nk
        if nk == "g" then st.cursor = 1
        elseif nk == "x" then open_browser(n)
        elseif nk == "b" then
          if n then
            local br = model.branch_name(n.key, n.summary)
            yank(br, "branch " .. br)
          end
        elseif nk == "j" then run_jql(ui.input("New JQL", { multiline = true }))
        elseif nk == "s" then
          -- menu is the rendered column table, so menu/columns/indicator can't drift
          local choice = ui.select("Sort by", render.COLUMNS, { format = function(c) return c.l end })
          if choice then
            if st.sort_col ~= choice.f then st.sort_col, st.sort_dir = choice.f, "asc"
            elseif st.sort_dir == "asc" then st.sort_dir = "desc"
            else st.sort_col, st.sort_dir = nil, nil end
            rebuild(n and n.key)
          end
        end
      elseif k == "s" then change_status(n)
      elseif k == "c" or k == "d" or k == "e" then
        st.message = "edit / create / close not implemented yet"
      end
      draw()
      end
    end
  end)

  term.leave(); term.raw_off()
  if not ok then io.stderr:write("jira-tui crashed: " .. tostring(err) .. "\n") end
end

return M
