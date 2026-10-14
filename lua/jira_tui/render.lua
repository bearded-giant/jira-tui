local ansi = require("jira_tui.ansi")
local md = require("jira_tui.md")
local model = require("jira_tui.model")

local M = {}

local C = ansi.color
local GUTTER = 2     -- selection bar / spaces
local ROOT_PREFIX = 3 -- chevron + icon + space, before the key (icon sits next to key)
local CHILD_INDENT = 4 -- spaces per nesting level for subtasks

M.COL = {
  key = 12, assignee = 12, created = 12, age = 6, status = 14,
  updated = 7, priority = 9, points = 6, labels = 16,
}
local SEP = 2
local MIN_SUMMARY = 20

M.ALL_COLUMNS = {
  key = { f = "key", l = "Key" }, summary = { f = "summary", l = "Title" },
  assignee = { f = "assignee", l = "Assignee" }, status = { f = "status", l = "Status" },
  created = { f = "created", l = "Created", optional = true }, age = { f = "age", l = "Age", optional = true },
  updated = { f = "updated", l = "Updated", optional = true },
  priority = { f = "priority", l = "Priority", optional = true },
  points = { f = "story_points", l = "Pts", optional = true, w = "points" },
  labels = { f = "labels", l = "Labels", optional = true },
}
M.DEFAULT_COLUMNS = { "key", "summary", "assignee", "created", "age", "status" }

function M.set_columns(names)
  local cols = {}
  local have = {}
  for _, name in ipairs(names or M.DEFAULT_COLUMNS) do
    local c = M.ALL_COLUMNS[name]
    if not c then return nil, "columns: unknown column '" .. tostring(name) .. "'" end
    cols[#cols + 1] = c
    have[name] = true
  end
  if not have.key or not have.summary then return nil, "columns: key and summary are required" end
  M.COLUMNS = cols
  return true
end
M.set_columns()

local function colw(c) return M.COL[c.w or c.f] end

local function fixed_width(cols)
  local w = SEP * (#cols - 1)
  for _, c in ipairs(cols) do if c.f ~= "summary" then w = w + colw(c) end end
  return w
end

-- columns shown at this interior width: optional columns drop right to left until the title fits
-- ponytail: below ~71 cols rows are hard-cut by ansi.cut; shrink assignee/status if that matters
function M.columns(iw)
  local cols = {}
  for i, c in ipairs(M.COLUMNS) do cols[i] = c end
  local i = #cols
  while i > 0 and iw - GUTTER - ROOT_PREFIX - fixed_width(cols) < MIN_SUMMARY do
    if cols[i].optional then table.remove(cols, i) end
    i = i - 1
  end
  return cols
end

function M.status_width(rows)
  local w = 0
  for _, r in ipairs(rows or {}) do w = math.max(w, ansi.width(r.status or "")) end
  return math.max(10, math.min(22, w + 2))
end

M.TABS = { -- order + hint key, matches jim
  { name = "My Issues", key = "M" },
  { name = "JQL", key = "J" },
  { name = "Active Sprint", key = "S" },
  { name = "Backlog", key = "B" },
  { name = "Help", key = "H" },
}

function M.tabs(queries, hidden)
  local out = { M.TABS[1] }
  for _, q in ipairs(queries or {}) do out[#out + 1] = { name = q.name, key = q.key } end
  for i = 2, #M.TABS do
    local t = M.TABS[i]
    if t.name == "Help" or not (hidden and hidden[t.name]) then out[#out + 1] = t end
  end
  return out
end

-- "JQL:<query>" view naming, one place: build, parse, label
function M.jql_view(q) return "JQL:" .. q end
function M.jql_query(view)
  if view:sub(1, 4) == "JQL:" then return view:sub(5) end
  return nil
end

-- tab label for a view: "JQL:<query>" -> "JQL", everything else as-is
function M.view_label(view)
  return M.jql_query(view) and "JQL" or view
end

-- top border of a rounded box, optionally with an embedded bold title
function M.box_top(w, title)
  if not title then return ansi.fgtext("╭" .. string.rep("─", w - 2) .. "╮", C.sky) end
  local t = ansi.truncate(" " .. title .. " ", w - 4)
  return ansi.fgtext("╭─", C.sky) .. ansi.fgtext(t, C.text, ansi.BOLD)
    .. ansi.fgtext(string.rep("─", math.max(0, w - 3 - ansi.width(t))) .. "╮", C.sky)
end

-- summary flex width -- fills available space (no hard cap) so columns span the board
function M.summary_width(iw)
  return math.max(MIN_SUMMARY, iw - GUTTER - ROOT_PREFIX - fixed_width(M.columns(iw)))
end

local TYPE_ICON = {
  -- byte escapes: literal nerd-font PUA chars have been silently stripped by tooling before
  Bug = { "\239\134\136", C.red },       -- U+F188 bug
  Story = { "\239\128\174", C.green },   -- U+F02E bookmark
  Task = { "\238\154\156", C.blue },     -- U+E69C checkbox
  ["Sub-task"] = { "\243\176\153\133", C.teal }, Subtask = { "\243\176\153\133", C.teal }, -- U+F0645
  Epic = { "\239\131\167", C.mauve },    -- U+F0E7 bolt
}
local function type_icon(t)
  local e = TYPE_ICON[t]
  if e then return e[1], e[2] end
  return "●", C.green
end

-- status keyword -> pill bg + fg (jim get_status_hl). spaces stripped so "To Do" matches TODO.
-- unmatched statuses get a light fg on surface2; base-on-surface was near invisible.
function M.status_bg(status)
  local s = (status or ""):upper():gsub("%s", "")
  if s:find("READYFOR") then return C.surface2, C.text end
  if s:find("DONE") or s:find("RESOLVED") or s:find("CLOSED") or s:find("FINISHED") then return C.green, C.base end
  if s:find("PROGRESS") or s:find("DEVELOP") or s:find("BUILDING") or s:find("WORKING") then return C.yellow, C.base end
  if s:find("TODO") or s:find("OPEN") or s:find("BACKLOG") then return C.blue, C.base end
  if s:find("BLOCK") or s:find("REJECT") or s:find("BUG") or s:find("ERROR") then return C.red, C.base end
  if s:find("REVIEW") or s:find("QA") or s:find("TEST") then return C.mauve, C.base end
  return C.surface2, C.text
end
local status_bg = M.status_bg

-- ---- tab bar (tabs = M.tabs(...); Help right-aligned) ----
function M.tab_bar(view, tabs, width)
  local function chip(tab)
    local label = tab.key and string.format(" %s (%s) ", tab.name, tab.key) or (" " .. tab.name .. " ")
    if view == tab.name then return ansi.bgtext(label, C.base, C.yellow, ansi.BOLD) end
    return ansi.bgtext(label, C.text, C.surface2)
  end
  local left, help = { "  " }, ""
  for _, tab in ipairs(tabs) do
    if tab.name == "Help" then
      help = chip(tab)
    else
      left[#left + 1] = chip(tab)
      left[#left + 1] = " "
    end
  end
  local leftstr = table.concat(left)
  local pad = math.max(1, (width or 80) - ansi.width(leftstr) - ansi.width(help) - 1)
  return leftstr .. string.rep(" ", pad) .. help
end

-- ---- hint / filter line ----
-- tab keys (M/J/S/B/H) live in the header; footer shows actions only
local HINTS = { "j/k move", "⏎ open", "/ filter", "s status", "a assign", "K detail", "b open", "r refresh", "Esc quit" }

function M.hint_line(view, filter, width)
  if filter and filter ~= "" then
    return ansi.fgtext("  filter: " .. filter .. "   (BS clears)", C.yellow)
  end
  local items = {}
  for i, h in ipairs(HINTS) do items[i] = h end
  local function line() return "  " .. table.concat(items, "   ") end
  -- narrow board: drop hints from the tail, but always keep "Esc quit"
  while width and #items > 1 and ansi.width(line()) > width do table.remove(items, #items - 1) end
  return ansi.fgtext(line(), C.overlay)
end

-- ---- column header ----
function M.column_header(board_w, sort_col, sort_dir)
  local sw = M.summary_width(board_w)
  local cells = {}
  for _, c in ipairs(M.columns(board_w)) do
    local label = c.l
    if sort_col == c.f then label = label .. (sort_dir == "asc" and " ▲" or " ▼") end
    cells[#cells + 1] = ansi.fgtext(ansi.fit(label, c.f == "summary" and sw or colw(c)), C.overlay, ansi.BOLD)
  end
  return string.rep(" ", GUTTER + ROOT_PREFIX) .. table.concat(cells, string.rep(" ", SEP))
end

local function human_size(n)
  n = tonumber(n) or 0
  if n >= 1048576 then return string.format("%.1fMB", n / 1048576) end
  if n >= 1024 then return string.format("%.0fKB", n / 1024) end
  return n .. "B"
end

-- ---- detail popup body ----
-- mode "markdown": raw markdown (title, description, acceptance criteria).
-- mode "fields" (default): labelled header, attachments, description +
-- acceptance criteria + comments (newest first), markdown-rendered.
-- opts: rule_w = section separator width; comments_collapsed = bodies hidden.
function M.detail_text(issue, p_config, mode, comments, opts)
  opts = opts or {}
  local f = issue.fields or {}
  local function name(t) return type(t) == "table" and (t.displayName or t.name) or nil end
  local desc = model.adf_to_markdown(f.description)
  if desc == "" then desc = "(no description)" end
  local ac = f[p_config.acceptance_criteria_field]
  if type(ac) == "table" then ac = model.adf_to_markdown(ac) end
  if ac == "" then ac = nil end

  if mode == "markdown" then
    local out = "# " .. (issue.key or "") .. " " .. (f.summary or "") .. "\n\n" .. desc
    if ac then out = out .. "\n\n## Acceptance Criteria\n\n" .. ac end
    return out
  end

  local created = model.short_date(f.created)
  if created ~= "" then created = created .. "  (" .. model.age(f.created) .. ")" end
  local rows = {
    { "Status", name(f.status) }, { "Type", name(f.issuetype) }, { "Priority", name(f.priority) },
    { "Assignee", name(f.assignee) or "Unassigned" }, { "Reporter", name(f.reporter) },
    { "Points", f[p_config.story_point_field] }, { "Parent", type(f.parent) == "table" and f.parent.key or nil },
    { "Created", created },
  }
  local lines = {}
  for _, r in ipairs(rows) do
    if r[2] ~= nil and r[2] ~= "" then
      lines[#lines + 1] = ansi.fgtext(ansi.pad(r[1], 10), C.sky) .. ansi.fgtext(tostring(r[2]), C.text)
    end
  end
  local rule_w = opts.rule_w or 60
  local function rule(label, color)
    local t = " " .. label .. " "
    return ansi.fgtext("──", C.overlay) .. ansi.fgtext(t, color or C.yellow, ansi.BOLD)
      .. ansi.fgtext(string.rep("─", math.max(2, rule_w - 2 - ansi.width(t))), C.overlay)
  end
  local function section(label) lines[#lines + 1] = ""; lines[#lines + 1] = rule(label); lines[#lines + 1] = "" end

  local rel = model.related(f)
  if #rel > 0 then
    section("Links (" .. #rel .. ")")
    for _, r in ipairs(rel) do
      local sbg, sfg = status_bg(r.status)
      lines[#lines + 1] = ansi.fgtext(ansi.fit(r.rel, 16), C.overlay) .. "  "
        .. ansi.fgtext(ansi.fit(r.key, 12), C.sky, ansi.BOLD)
        .. (r.status ~= "" and ansi.bgtext(" " .. r.status .. " ", sfg, sbg) .. " " or "")
        .. ansi.fgtext(r.summary, C.text)
    end
  end

  local atts = type(f.attachment) == "table" and f.attachment or {}
  if #atts > 0 then
    section("Attachments (" .. #atts .. ")")
    for i, a in ipairs(atts) do
      lines[#lines + 1] = ansi.fgtext(string.format("%2d. ", i), C.overlay)
        .. ansi.fgtext(a.filename or "?", C.sky)
        .. ansi.fgtext("   " .. human_size(a.size) .. "   " .. (a.mimeType or ""), C.overlay)
    end
  end

  section("Description")
  lines[#lines + 1] = md.to_ansi(desc)
  if ac then section("Acceptance Criteria"); lines[#lines + 1] = md.to_ansi(ac) end
  if comments and #comments > 0 then
    section("Comments (" .. #comments .. ")")
    if opts.comments_collapsed then
      lines[#lines + 1] = ansi.fgtext("collapsed, press c to show", C.overlay)
    else
      for _, cm in ipairs(comments) do
        local who = type(cm.author) == "table" and cm.author.displayName or "unknown"
        local when = model.short_date(cm.created)
        local age = model.age(cm.created)
        lines[#lines + 1] = rule(who .. " · " .. when .. (age ~= "" and "  (" .. age .. ")" or ""), C.sky)
        lines[#lines + 1] = ""
        local body = type(cm.body) == "table" and model.adf_to_markdown(cm.body) or tostring(cm.body or "")
        lines[#lines + 1] = md.to_ansi(body)
        lines[#lines + 1] = ""
      end
    end
  end
  return table.concat(lines, "\n")
end

-- ---- one issue row ----
-- returns the full ANSI line. selected draws a colored gutter bar.
function M.issue_line(node, depth, board_w, selected, is_last)
  local sw = M.summary_width(board_w)
  local is_root = depth == 1
  local icon, icon_c = type_icon(node.type)

  -- prefix sits between the gutter and the key; icon ends right before the key
  -- (one space). roots: chevron+icon. children: indent + connector + icon.
  local prefix, used
  if is_root then
    local chev = (node.children and #node.children > 0)
      and (node.expanded and "\239\145\188" or "\239\145\160") or " " -- U+F47C / U+F460 chevrons
    prefix = ansi.fgtext(chev, C.overlay) .. ansi.fgtext(icon, icon_c) .. " "
    used = 3
  else
    local indent = string.rep(" ", CHILD_INDENT * (depth - 1))
    local conn = is_last and "└─" or "├─"
    prefix = indent .. ansi.fgtext(conn, C.overlay) .. ansi.fgtext(icon, icon_c) .. " "
    used = #indent + 4
  end
  -- a stripped or missing icon glyph must not shift the row's columns
  prefix = ansi.padline(prefix, used)

  -- shrink summary by however far this row's prefix exceeds a root prefix, so
  -- the trailing columns stay aligned across depths
  local summary_w = math.max(10, sw - (used - ROOT_PREFIX))

  -- key
  local key = is_root and ansi.fgtext(ansi.fit(node.key or "", M.COL.key), C.text, ansi.BOLD)
    or ansi.fgtext(ansi.fit(node.key or "", M.COL.key), C.child)
  -- summary
  local summary = is_root and ansi.fgtext(ansi.fit(node.summary or "", summary_w), C.text, ansi.BOLD)
    or ansi.fgtext(ansi.fit(node.summary or "", summary_w), C.child)
  -- assignee
  local ass = node.assignee or "Unassigned"
  local assignee = ass == "Unassigned"
    and ansi.fgtext(ansi.fit(ass, M.COL.assignee), C.graytext, ansi.ITALIC)
    or ansi.fgtext(ansi.fit(ass, M.COL.assignee), C.green)
  -- created date + age
  local created = ansi.fgtext(ansi.fit(model.short_date(node.created), M.COL.created), C.overlay)
  local age = ansi.fgtext(ansi.fit(model.age(node.created), M.COL.age), C.subtext)
  -- status badge: bg color, dark fg
  local st = ansi.truncate(node.status or "", M.COL.status - 2)
  local sbg, sfg = status_bg(node.status)
  local status = ansi.bgtext(" " .. ansi.pad(st, M.COL.status - 2) .. " ", sfg, sbg, ansi.BOLD)

  local updated = ansi.fgtext(ansi.fit(model.age(node.updated), M.COL.updated), C.subtext)
  local priority = ansi.fgtext(ansi.fit(node.priority or "", M.COL.priority), C.subtext)
  local pts = node.story_points and tostring(node.story_points):gsub("%.0+$", "") or ""
  local points = ansi.fgtext(ansi.fit(pts, M.COL.points), C.sky)
  local labels = ansi.fgtext(ansi.fit(type(node.labels) == "table" and table.concat(node.labels, ",") or "",
    M.COL.labels), C.overlay)

  local gutter = selected and ansi.fgtext("▌", C.sky, ansi.BOLD) .. " " or "  "
  local cells = { key = key, summary = summary, assignee = assignee, created = created, age = age, status = status,
    updated = updated, priority = priority, story_points = points, labels = labels }
  local out = {}
  for _, c in ipairs(M.columns(board_w)) do out[#out + 1] = cells[c.f] end
  return gutter .. prefix .. table.concat(out, string.rep(" ", SEP))
end

return M
