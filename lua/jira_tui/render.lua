local ansi = require("jira_tui.ansi")
local model = require("jira_tui.model")

local M = {}

local C = ansi.color
local GUTTER = 2     -- selection bar / spaces
local ROOT_PREFIX = 3 -- chevron + icon + space, before the key (icon sits next to key)
local CHILD_INDENT = 4 -- spaces per nesting level for subtasks

M.COL = {
  key = 12, assignee = 12, created = 12, age = 6, status = 14,
}

M.TABS = { -- order + hint key, matches jim
  { name = "My Issues", key = "M" },
  { name = "JQL", key = "J" },
  { name = "Active Sprint", key = "S" },
  { name = "Backlog", key = "B" },
  { name = "Help", key = "H" },
}

-- summary flex width -- fills available space (no hard cap) so columns span the board
function M.summary_width(iw)
  local fixed = M.COL.key + M.COL.assignee + M.COL.created + M.COL.age + M.COL.status
  local available = iw - GUTTER - ROOT_PREFIX - fixed - (2 * 5)
  return math.max(20, available)
end

local TYPE_ICON = {
  Bug = { "", C.red }, Story = { "", C.green }, Task = { "", C.blue },
  ["Sub-task"] = { "󰙅", C.teal }, Subtask = { "󰙅", C.teal }, Epic = { "", C.mauve },
}
local function type_icon(t)
  local e = TYPE_ICON[t]
  if e then return e[1], e[2] end
  return "●", C.green
end

-- status keyword -> bg color (jim get_status_hl)
local function status_bg(status)
  local s = (status or ""):upper()
  if s:find("READY FOR") then return C.surface end
  if s:find("DONE") or s:find("RESOLVED") or s:find("CLOSED") or s:find("FINISHED") then return C.green end
  if s:find("PROGRESS") or s:find("DEVELOP") or s:find("BUILDING") or s:find("WORKING") then return C.yellow end
  if s:find("TODO") or s:find("OPEN") or s:find("BACKLOG") then return C.blue end
  if s:find("BLOCK") or s:find("REJECT") or s:find("BUG") or s:find("ERROR") then return C.red end
  if s:find("REVIEW") or s:find("QA") or s:find("TEST") then return C.mauve end
  return C.surface
end

-- ---- tab bar ----
function M.tab_bar(view, hidden)
  local parts = { "  " }
  for _, tab in ipairs(M.TABS) do
    if tab.name == "My Issues" or tab.name == "Help" or not (hidden and hidden[tab.name]) then
      local label = string.format(" %s (%s) ", tab.name, tab.key)
      if view == tab.name then
        parts[#parts + 1] = ansi.bgtext(label, C.base, C.yellow, ansi.BOLD)
      else
        parts[#parts + 1] = ansi.bgtext(label, C.text, C.surface2)
      end
      parts[#parts + 1] = " "
    end
  end
  return table.concat(parts)
end

-- ---- hint / filter line ----
function M.hint_line(view, filter)
  if filter and filter ~= "" then
    return ansi.fgtext("  filter: " .. filter .. "   (BS clears)", C.yellow)
  end
  -- tab keys (M/J/S/B/H) live in the header; footer shows actions only
  local h = "  j/k move   ⏎ expand   t all   / filter   p project   K detail   b open   r refresh   q quit"
  return ansi.fgtext(h, C.overlay)
end

-- ---- column header ----
function M.column_header(board_w, sort_col, sort_dir)
  local sw = M.summary_width(board_w)
  local cells = {
    { "Key", M.COL.key }, { "Title", sw }, { "Assignee", M.COL.assignee },
    { "Created", M.COL.created }, { "Age", M.COL.age }, { "Status", M.COL.status },
  }
  local fields = { "key", "summary", "assignee", "created", "age", "status" }
  local line = string.rep(" ", GUTTER + ROOT_PREFIX)
  for i, c in ipairs(cells) do
    local label = c[1]
    if sort_col == fields[i] then label = label .. (sort_dir == "asc" and " ▲" or " ▼") end
    line = line .. ansi.fgtext(ansi.fit(label, c[2]), C.overlay, ansi.BOLD) .. "  "
  end
  return line
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
    local chev = (node.children and #node.children > 0) and (node.expanded and "" or "") or " "
    prefix = ansi.fgtext(chev, C.overlay) .. ansi.fgtext(icon, icon_c) .. " "
    used = 3
  else
    local indent = string.rep(" ", CHILD_INDENT * (depth - 1))
    local conn = is_last and "└─" or "├─"
    prefix = indent .. ansi.fgtext(conn, C.overlay) .. ansi.fgtext(icon, icon_c) .. " "
    used = #indent + 4
  end

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
  local status = ansi.bgtext(" " .. ansi.pad(st, M.COL.status - 2) .. " ", C.base, status_bg(node.status), ansi.BOLD)

  local gutter = selected and ansi.fgtext("▌", C.sky, ansi.BOLD) .. " " or "  "
  return table.concat({
    gutter, prefix,
    key, "  ", summary, "  ", assignee, "  ", created, "  ", age, "  ", status,
  })
end

return M
