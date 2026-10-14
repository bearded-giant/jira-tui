local term = require("jira_tui.term")
local render = require("jira_tui.render")
local ui = require("jira_tui.ui")
local ansi = require("jira_tui.ansi")
local api = require("jira_tui.api")
local config = require("jira_tui.config")
local model = require("jira_tui.model")
local md = require("jira_tui.md")
local sprint = require("jira_tui.sprint")
local version = require("jira_tui.version")

local M = {}
local C = ansi.color

local function sort_roots(roots, col, dir)
  -- age is derived from created and shown as time-since, like updated: inverted order (older = bigger)
  local field = col == "age" and "created" or col
  if col == "age" or col == "updated" then dir = dir == "asc" and "desc" or "asc" end
  table.sort(roots, function(a, b)
    local va, vb = a[field], b[field]
    if type(va) == "table" then va = table.concat(va, ",") end
    if type(vb) == "table" then vb = table.concat(vb, ",") end
    if va == vb then return false end
    if va == nil then return dir == "asc" end
    if vb == nil then return dir ~= "asc" end
    if type(va) ~= type(vb) then va, vb = tostring(va), tostring(vb) end
    if dir == "desc" then return va > vb end
    return va < vb
  end)
end

function M.run(opts)
  local now = opts.clock or os.time
  local persist = opts.state
  local st = {
    view = opts.initial_view, project = opts.project, filter = nil,
    roots = {}, flat = {}, cursor = 1, scroll = 0, count = 0,
    sort_col = nil, sort_dir = nil, raw = {}, message = nil,
    hide_resolved = persist and persist.data.hide_resolved,
    rows = 24, cols = 80, detail_cache = {}, cache = {}, prefetched = {}, idle = 0,
  }
  if st.hide_resolved == nil then st.hide_resolved = true end
  st.my_projects = opts.my_projects or {}
  st.hidden = {}
  for _, name in ipairs(opts.hidden_tabs or {}) do st.hidden[name] = true end
  st.tabs = render.tabs(opts.queries, st.hidden)
  st.query_keys = {}
  for _, q in ipairs(opts.queries or {}) do if q.key then st.query_keys[q.key] = q.name end end
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
    render.COL.status = render.status_width(st.raw)
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
  -- sprint/backlog share a view id across projects, so the project is part of the key
  local function cache_key(view) return view .. "|" .. (st.project or "") end

  -- st.raw is the cache entry's table, so row patches land in the cache too
  local function show(job, entry)
    local keep = job.view == st.view and cur_node() or nil
    local old_scroll = st.scroll
    st.entry = entry
    st.view, st.filter, st.raw, st.truncated = job.view, job.filter, entry.raw, entry.truncated
    st.cursor, st.scroll, st.message = 1, 0, nil
    if rebuild(keep and keep.key) then st.scroll = old_scroll end -- draw() clamps if it no longer fits
    if persist then persist.remember(job.view, st.project) end
  end

  local function finish(job, issues, err, truncated)
    st.loading = nil
    if err then st.message = err; return false, err end
    local entry = { raw = issues or {}, truncated = truncated, at = now() }
    st.cache[job.ckey] = entry
    show(job, entry)
    return true
  end

  local function cancel_job()
    if st.job and type(st.job.h) == "table" then api.cancel(st.job.h) end
    if st.job and st.job.kind == "detail" then st.prefetched[st.job.key] = nil end
    st.job, st.loading = nil, nil
  end

  local function pump()
    local job = st.job
    if not job then return end
    local res = { coroutine.resume(job.co) }
    if coroutine.status(job.co) ~= "dead" then job.h = res[2]; return end
    st.job = nil
    if job.kind == "detail" then return end -- prefetch: fetch_detail filled the cache, or failed quietly
    if not res[1] then st.loading = nil; st.message = "load failed: " .. tostring(res[2]); return end
    finish(job, res[2], res[3], res[4])
  end

  -- loads run in a coroutine so the board stays live; a newer load cancels the older one.
  -- sync (the jql editor) blocks instead, because it needs the outcome to decide whether to reopen.
  local function load_view(view, filter, force, sync)
    cancel_job()
    local job = { view = view, filter = filter, ckey = cache_key(view), project = st.project }
    local entry = st.cache[job.ckey]
    if not force and model.cache_fresh(entry, opts.cache_ttl, now()) then show(job, entry); return true end
    st.loading = "loading " .. render.view_label(view) .. "…"
    if sync then
      if draw then draw() end
      return finish(job, opts.load(view, nil, job.project))
    end
    job.co = coroutine.create(function() return opts.load(view, nil, job.project) end)
    api._async[job.co] = true
    st.job = job
    pump()
    return true
  end

  -- after a mutation re-fetch just that row (~0.4s) instead of reloading the view (0.7-4s)
  -- only create appends: an issue opened from a link and then edited must not land on the board
  local function refresh_row(key, done_msg, append)
    st.detail_cache[key], st.prefetched[key] = nil, nil
    local row, err = sprint.get_issue_row(key)
    if not row then
      st.message, st.message_ok = done_msg .. "; row refresh failed: " .. (err or "?"), false
      return false
    end
    if append then model.upsert_row(st.raw, row) end
    for _, c in pairs(st.cache) do model.replace_row(c.raw, row) end
    model.replace_row(st.raw, row)
    rebuild(key)
    st.message, st.message_ok = done_msg, true
    return true
  end

  -- diff renderer: build every board row, emit only the rows that changed.
  -- a cursor move repaints ~2 rows, not the whole screen -> no flicker, cheap.
  st.prev = st.prev or {}
  draw = function()
    -- handlers also run under the detail popup; painting the board there would cover it
    if st.in_detail then return end
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
    st.body_screen = { first = top + 5, last = top + bh - 3 }
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
    frame[2] = interior(render.tab_bar(tab, st.tabs, iw))
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
    local ltxt = st.loading and (" ● " .. st.loading .. " ")
      or st.entry and (" updated " .. math.floor((now() - st.entry.at) / 60) .. "m ago ") or ""
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
    local loaded, err = load_view(render.jql_view(q), nil, false, true)
    if loaded and persist then persist.add_jql(q) end
    return loaded, err
  end

  -- a failed query reopens the editor on the same text + error, so a typo never costs a retype
  local function edit_jql(title, q, err)
    while true do
      local rows, cols = term.size()
      q = ui.input(title, { value = q, multiline = true, width = cols, height = math.floor(rows / 2), error = err })
      if not q or q == "" then return end
      local loaded
      loaded, err = run_jql(q)
      if loaded then return end
    end
  end

  local NEWQ = "＋ New query…"
  local function pick_jql()
    local hist = (persist and persist.data.jql_history) or {}
    local items = { NEWQ }
    for _, q in ipairs(hist) do items[#items + 1] = q end
    local choice, _, action = ui.select("JQL", items, {
      width = select(2, term.size()), keys = { e = "edit" }, hint = "e edit",
      format = function(s) return s == NEWQ and s or (s:gsub("%s+", " ")) end,
    })
    if not choice then return end
    if choice == NEWQ then edit_jql("New JQL")
    elseif action == "edit" then edit_jql("Edit JQL", choice)
    else
      local loaded, err = run_jql(choice)
      if not loaded then edit_jql("Edit JQL", choice, err) end
    end
  end

  local function open_browser(n)
    if not n then return end
    local url = config.options.jira.base .. "/browse/" .. n.key
    os.execute(string.format("(open %q || xdg-open %q) >/dev/null 2>&1 &", url, url))
  end

  local DETAIL_FIELDS = { "summary", "status", "issuetype", "priority", "assignee", "reporter", "parent",
    "created", "updated", "description", "attachment", "comment", "issuelinks", "subtasks", "labels", "project" }

  local function fetch_detail(key)
    if st.detail_cache[key] then return st.detail_cache[key] end
    local pcfg = config.get_project_config(key:match("^(.-)%-%d+$"))
    local fields = {}
    for i, f in ipairs(DETAIL_FIELDS) do fields[i] = f end
    fields[#fields + 1] = pcfg.story_point_field
    fields[#fields + 1] = pcfg.acceptance_criteria_field
    local issue, err = api.get_issue(key, fields)
    if err or type(issue) ~= "table" or type(issue.fields) ~= "table" then
      local jira_err = type(issue) == "table" and type(issue.errorMessages) == "table"
        and table.concat(issue.errorMessages, "; ")
      return nil, err or jira_err or "unexpected response"
    end
    local comments, more = model.recent_comments(issue.fields.comment, 15)
    if more then comments = api.get_comments(key, 15) or {} end
    st.detail_cache[key] = { issue = issue, comments = comments }
    return st.detail_cache[key]
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
    refresh_row(n.key, n.key .. " → " .. label)
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
    local choice = ui.select("Assign: " .. n.key .. "  (" .. (n.assignee or "Unassigned") .. ")", users, {
      format = function(u) return u.displayName or "?" end,
      on_filter = function(q)
        local found = api.get_assignable(n.key, q)
        return type(found) == "table" and found or {}
      end,
    })
    if choice then do_assign(n, choice.accountId, choice.displayName) end
  end

  local function assign_me(n)
    if not n then return end
    st.message = "resolving current user…"; draw()
    local me, merr = api.myself()
    st.message = nil
    if not me then st.message = merr; return end
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
    refresh_row(n.key, n.key .. " → " .. (type(choice.to) == "table" and choice.to.name or choice.name))
  end

  local function close_issue(n)
    if not n then return end
    st.message = "loading transitions for " .. n.key .. "…"; draw()
    local trs, terr = api.get_transitions(n.key)
    if terr or type(trs) ~= "table" or #trs == 0 then
      st.message = n.key .. ": " .. (terr or "no transitions available"); return
    end
    local pick = model.pick_done_transition(trs)
    if not pick then st.message = n.key .. ": no done/close transition"; return end
    st.message = "closing " .. n.key .. "…"; draw()
    local _, xerr = api.transition_issue(n.key, pick.id)
    if xerr then st.message = n.key .. ": " .. xerr; return end
    refresh_row(n.key, n.key .. " → " .. (type(pick.to) == "table" and pick.to.name or pick.name))
  end

  local function update_fields(n, fields, what)
    st.message = "updating " .. n.key .. "…"; draw()
    local _, uerr = api.update_issue(n.key, fields)
    if uerr then st.message = n.key .. ": " .. uerr; return end
    refresh_row(n.key, n.key .. " " .. what .. " updated")
  end

  local function current_description(n)
    st.message = "loading " .. n.key .. "…"; draw()
    local issue, ierr = api.get_issue(n.key, { "description" })
    st.message = nil
    if ierr or type(issue) ~= "table" or type(issue.fields) ~= "table" then
      st.message = n.key .. ": " .. (ierr or "unexpected response"); return
    end
    return issue.fields.description or false
  end

  local EDITS = {
    { "Summary", function(n)
      local s = ui.input("Summary: " .. n.key, { value = n.summary or "", width = 76 })
      if s and s ~= "" and s ~= n.summary then update_fields(n, { summary = s }, "summary") end
    end },
    { "Description", function(n)
      local adf = current_description(n)
      if adf == nil then return end
      if model.adf_lossy(adf) then
        st.message = n.key .. ": description has content markdown can't keep (tables, media, mentions…); use Append"
        return
      end
      local txt = ui.edit_external(adf and (model.adf_to_markdown(adf):gsub("%s+$", "")) or "", ".md")
      if not txt then st.message = n.key .. ": description unchanged"; return end
      update_fields(n, { description = md.to_adf(txt) }, "description")
    end },
    { "Append description", function(n)
      local txt = ui.input("Append description: " .. n.key, { multiline = true })
      if not txt or txt == "" then return end
      local adf = current_description(n)
      if adf == nil then return end
      update_fields(n, { description = api.append_to_adf(adf or nil, txt) }, "description")
    end },
    { "Priority", function(n)
      st.message = "loading priorities…"; draw()
      local ps, perr = api.get_priorities()
      st.message = nil
      if not ps then st.message = "priorities: " .. perr; return end
      draw()
      local p = ui.select("Priority: " .. n.key .. "  (" .. (n.priority or "?") .. ")", ps,
        { format = function(x) return x.name or "?" end })
      if p then update_fields(n, { priority = { id = p.id } }, "priority") end
    end },
    { "Points", function(n)
      local s = ui.input("Points: " .. n.key, { value = n.story_points and tostring(n.story_points) or "", width = 40 })
      if not s or s == "" then return end
      local pts, perr = model.parse_points(s)
      if not pts then st.message = perr; return end
      local spf = config.get_project_config(n.key:match("^(.-)%-%d+$")).story_point_field
      update_fields(n, { [spf] = pts }, "points")
    end },
    { "Labels", function(n)
      local cur = type(n.labels) == "table" and table.concat(n.labels, ", ") or ""
      local s = ui.input("Labels: " .. n.key .. "  (comma or space separated)", { value = cur, width = 76 })
      if s and s ~= cur then update_fields(n, { labels = model.split_labels(s) }, "labels") end
    end },
    { "Parent", function(n)
      local s = ui.input("Parent key: " .. n.key, { value = n.parent or "", width = 40 })
      if not s or s == "" then return end
      local key = model.valid_key(s)
      if not key then st.message = "not an issue key: " .. s; return end
      if key ~= n.parent then update_fields(n, { parent = { key = key } }, "parent") end
    end },
    { "Change status", function(n) change_status(n) end },
  }

  local function edit_issue(n)
    if not n then return end
    local choice = ui.select("Edit: " .. n.key, EDITS, { format = function(e) return e[1] end })
    if choice then choice[2](n) end
  end

  local function log_work(n)
    if not n then return end
    local s = ui.input("Log time on " .. n.key .. "  (1h 30m, 2d, 45m)", { width = 50 })
    if not s or s == "" then return end
    local dur = model.valid_duration(s)
    if not dur then st.message = "not a duration: " .. s .. "  (use 1h 30m, 2d, 45m)"; return end
    st.message = "logging " .. dur .. " on " .. n.key .. "…"; draw()
    local _, werr = api.add_worklog(n.key, dur)
    if werr then st.message = n.key .. ": worklog failed: " .. werr; return end
    refresh_row(n.key, "logged " .. dur .. " on " .. n.key)
  end

  local function comment_on(n)
    if not n then return end
    local text = ui.edit_external("", ".md")
    if not text then st.message = "comment cancelled (empty)"; return end
    st.message = "commenting on " .. n.key .. "…"; draw()
    local _, cerr = api.add_comment(n.key, md.to_adf(text))
    if cerr then st.message = n.key .. ": comment failed: " .. cerr; return end
    st.detail_cache[n.key] = nil
    st.message, st.message_ok = "commented on " .. n.key, true
  end

  -- a failed create keeps the text as the next template so nothing typed is lost
  local function create_flow(project, parent)
    st.message = "loading issue types for " .. project .. "…"; draw()
    local types, terr = api.get_create_types(project)
    st.message = nil
    if not types then st.message = project .. ": " .. terr; return end
    local parent_key, want_sub
    if parent then
      local row_sub = false
      for _, t in ipairs(types) do if t.name == parent.type and t.subtask then row_sub = true end end
      parent_key = row_sub and parent.parent or parent.key
      if not parent_key then st.message = parent.key .. ": sub-task without a parent"; return end
      want_sub = parent.type ~= "Epic"
    end
    local pickable = {}
    for _, t in ipairs(types) do
      if (t.subtask == true) == (want_sub == true) then pickable[#pickable + 1] = t end
    end
    if #pickable == 0 then st.message = project .. ": no matching issue types"; return end
    draw()
    local itype = ui.select(parent_key and ("New child of " .. parent_key) or ("New issue in " .. project),
      pickable, { format = function(t) return t.name end })
    if not itype then return end
    local text = ui.edit_external(st.create_draft or model.CREATE_TEMPLATE, ".md")
    if not text then st.message = "create cancelled"; return end
    local f, perr = model.parse_create(text)
    if not f then st.create_draft = text; st.message = "create: " .. perr .. " (c reopens your draft)"; return end
    st.message = "creating " .. itype.name .. " in " .. project .. "…"; draw()
    local res, cerr = api.create_issue(project, f.summary, itype, {
      description = f.description, labels = f.labels, points = f.points, priority = f.priority,
      parent = parent_key, assignee_account_id = (api.myself() or {}).accountId,
    })
    if cerr then st.create_draft = text; st.message = "create failed: " .. cerr .. " (c reopens your draft)"; return end
    st.create_draft = nil
    local new_key = type(res) == "table" and res.key
    if not new_key then st.message, st.message_ok = "created issue", true; return end
    refresh_row(new_key, "created " .. new_key, true)
  end


  local function detail_view(n, d, mode)
    local issue, comments = d.issue, d.comments
    local project = type(issue.fields.project) == "table" and issue.fields.project.key or n.key:match("^(.-)%-")
    local pcfg = config.get_project_config(project)
    local title = n.key .. "  " .. (issue.fields.summary or n.summary or "")
    if mode == "markdown" then return title, render.detail_text(issue, pcfg, mode) end
    local _, tcols = term.size()
    local rule_w = ui.detail_width(tcols) - 4
    local text = render.detail_text(issue, pcfg, mode, comments, { rule_w = rule_w, comments_collapsed = true })
    local alt
    if comments and #comments > 0 then
      alt = render.detail_text(issue, pcfg, mode, comments, { rule_w = rule_w })
    end
    return title, text, alt
  end

  -- a handler that invalidated this key's detail cache mutated the issue, so the popup reloads
  local function detail_actions(n)
    local function wrap(fn)
      return function()
        st.message = nil
        fn()
        local note = st.message
        st.message = nil
        return { note = note, reload = st.detail_cache[n.key] == nil }
      end
    end
    local function nav(dir)
      return function()
        local i = step(st.cursor, dir)
        if i == st.cursor then return { note = dir > 0 and "last issue" or "first issue" } end
        st.cursor = i
        return { nav = "step" }
      end
    end
    local acts = {
      s = wrap(function() change_status(n) end), a = wrap(function() assign_picker(n) end),
      A = wrap(function() assign_me(n) end), e = wrap(function() edit_issue(n) end),
      d = wrap(function() close_issue(n) end), C = wrap(function() comment_on(n) end),
      w = wrap(function() log_work(n) end),
      y = wrap(function() yank(n.key, n.key) end),
      Y = wrap(function() yank(config.options.jira.base .. "/browse/" .. n.key, n.key .. " url") end),
      b = wrap(function() open_browser(n) end),
      ["]"] = nav(1), ["["] = nav(-1),
      L = function()
        local d = st.detail_cache[n.key]
        local rel = d and model.related(d.issue.fields) or {}
        if #rel == 0 then return { note = "no links" } end
        local pick = ui.select("Links: " .. n.key, rel, { format = function(r)
          return ansi.fit(r.rel, 16) .. "  " .. ansi.fit(r.key, 12) .. "  " .. r.summary end })
        if pick then return { nav = { key = pick.key, summary = pick.summary } } end
      end,
    }
    local d = st.detail_cache[n.key]
    local atts = d and type(d.issue.fields.attachment) == "table" and d.issue.fields.attachment or {}
    if #atts > 0 then
      acts.o = function()
        local a = ui.select("Attachments: " .. n.key, atts, { format = function(x)
          return (x.filename or "?") .. "   " .. (x.mimeType or "") end })
        if not a then return end
        local path, derr = api.download_attachment(a)
        if not path then return { note = "download failed: " .. (derr or "?") } end
        os.execute(string.format("(open %q || xdg-open %q) >/dev/null 2>&1 &", path, path))
        return { note = "opened " .. path:match("([^/]+)$") }
      end
    end
    return acts, #atts > 0
  end

  -- a loop, not recursion: ]/[ and L reopen the popup on another issue, q unwinds L jumps first
  local function show_detail(n, mode)
    local stack = {}
    while n do
      if not st.detail_cache[n.key] then st.message = "loading " .. n.key .. "…"; draw() end
      local d, err = fetch_detail(n.key)
      st.message = nil
      if not d then st.message = n.key .. ": " .. err; return end
      draw() -- clear the "loading" footer before the popup covers the board
      local title, text, alt = detail_view(n, d, mode)
      local acts, has_atts = detail_actions(n)
      local node = n
      st.in_detail = true
      local nav = ui.detail(title, text, {
        alt = alt, actions = acts,
        hint = (has_atts and "o attachment   " or "") .. "s a A e d C w y Y b   L links   ]/[ issue",
        reload = function()
          local d2 = fetch_detail(node.key)
          if not d2 then return end
          local t2, x2, a2 = detail_view(node, d2, mode)
          return x2, a2, t2
        end,
      })
      st.in_detail = false
      if nav == "step" then stack = {}; n = cur_node()
      elseif nav then stack[#stack + 1] = n; n = nav
      else n = table.remove(stack) end
    end
  end

  local function idle_work()
    if st.job then return end
    local every = opts.refresh_interval or 0
    if every > 0 and st.entry and now() - st.entry.at >= every then load_view(st.view, st.filter, true); return end
    local n = cur_node()
    if st.idle >= 2 and n and not st.detail_cache[n.key] and not st.prefetched[n.key] then
      st.prefetched[n.key] = true
      local job = { kind = "detail", key = n.key }
      job.co = coroutine.create(function() return fetch_detail(n.key) end)
      api._async[job.co] = true
      st.job = job
      pump()
    end
  end

  local interactive = term.isatty()
  term.raw_on(); term.enter(); term.clear()
  local ok, err = pcall(function()
    load_view(st.view, nil)
    draw()

    while true do
      local k = term.read_key()
      if k ~= nil then
        st.idle = 0
        if st.job and st.job.kind == "detail" then cancel_job() end
      end
      if st.job then pump() end
      if k == nil then
        -- no input: timeout on a tty (idle work, resize, footer clock), EOF on a pipe (quit)
        if not interactive then break end
        st.idle = st.idle + 1
        idle_work()
        draw()
      else
      local n = cur_node()
      st.message_ok = false
      local armed = st.quit_armed
      st.quit_armed = false
      if armed and k ~= "esc" then st.message = nil end

      -- help is an overlay: only quit/close and tab keys get through, so data keys
      -- (r, x, /, ...) can't fire loaders or move the cursor while it's up
      local swallowed = false
      if st.help then
        swallowed = true
        if k == "ctrl-c" then break
        elseif k == "q" or k == "esc" or k == "H" or k == "?" then st.help = false
        elseif ({ M = 1, S = 1, B = 1, J = 1, left = 1, right = 1 })[k] or st.query_keys[k] then
          st.help = false; swallowed = false
        end
      end

      if swallowed then -- redraw only
      elseif k == "ctrl-c" then break
      elseif k == "esc" then
        -- a stray Esc after a modal shouldn't end the session: it peels state off first
        if armed then break
        elseif st.job and st.job.kind ~= "detail" then cancel_job(); st.message = "load cancelled"
        elseif st.filter then st.filter = nil; rebuild(n and n.key)
        elseif st.message then st.message = nil
        else st.message, st.quit_armed = "Esc again to quit", true end
      elseif k == "q" then st.message = "q goes back · Esc Esc quits" -- q never closes the tui
      elseif k == "j" or k == "down" then st.cursor = step(st.cursor, 1)
      elseif k == "k" or k == "up" then st.cursor = step(st.cursor, -1)
      elseif k == "wheeldown" then for _ = 1, 3 do st.cursor = step(st.cursor, 1) end
      elseif k == "wheelup" then for _ = 1, 3 do st.cursor = step(st.cursor, -1) end
      elseif k == "click" then
        local b, m = st.body_screen, term.mouse
        if b and m and not st.help and m.row >= b.first and m.row <= b.last then
          local e = st.flat[st.scroll + m.row - b.first + 1]
          if e and not e.spacer then st.cursor = st.scroll + m.row - b.first + 1 end
        end
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
      elseif st.query_keys[k] then load_view(st.query_keys[k], nil)
      elseif k == "S" then if ensure_project() then load_view("Active Sprint", nil) end
      elseif k == "B" then if ensure_project() then load_view("Backlog", nil) end
      elseif k == "p" then
        local p = ui.input("Project key", { value = st.project or "", width = 40 })
        if p and p ~= "" then st.project = p:upper(); load_view("Active Sprint", nil) end
      elseif k == "J" then pick_jql()
      elseif k == "H" or k == "?" then st.help = true; st.message = nil
      elseif k == "/" then
        local f = ui.input("Filter: words  @who  s:status  t:type  p:priority  l:label", { value = st.filter or "", width = 50 })
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
      elseif k == "r" then st.detail_cache, st.prefetched = {}, {}; load_view(st.view, st.filter, true)
      elseif k == "left" or k == "right" then
        local order = {}
        for _, tabdef in ipairs(st.tabs) do order[#order + 1] = tabdef.name end
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
        elseif nk == "j" then edit_jql("New JQL")
        elseif nk == "c" then if n then create_flow(n.key:match("^(.-)%-%d+$"), n) end
        elseif nk == "i" then
          local ref = ui.input("Go to issue (key or url)", { width = 60 })
          if ref and ref ~= "" then
            local key = model.parse_issue_ref(ref)
            if key then show_detail({ key = key }) else st.message = "not an issue key or url: " .. ref end
          end
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
      elseif k == "d" then close_issue(n)
      elseif k == "e" then edit_issue(n)
      elseif k == "c" then if ensure_project() then create_flow(st.project) end
      elseif k == "C" then comment_on(n)
      elseif k == "w" then log_work(n)
      end
      draw()
      end
    end
  end)

  cancel_job()
  term.leave(); term.raw_off()
  if not ok then io.stderr:write("jira-tui crashed: " .. tostring(err) .. "\n") end
  return ok, err
end

return M
