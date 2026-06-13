local ansi = require("jira_tui.ansi")
local model = require("jira_tui.model")

local M = {}

local C = ansi.color
local PREFIX_W = 7

M.COL = {
  key = 12, assignee = 12, time = 16, status = 14, summary_max = 60,
}

M.TABS = { -- order + hint key, matches jim
  { name = "My Issues", key = "M" },
  { name = "JQL", key = "J" },
  { name = "Active Sprint", key = "S" },
  { name = "Backlog", key = "B" },
  { name = "Help", key = "H" },
}

-- summary flex width (jim's get_effective_summary_width)
function M.summary_width(board_w)
  local fixed = M.COL.key + M.COL.assignee + M.COL.time + M.COL.status
  local available = board_w - PREFIX_W - fixed - (2 * 4) - 2
  return math.max(15, math.min(M.COL.summary_max, available))
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
        parts[#parts + 1] = ansi.bgtext(label, C.subtext, C.surface)
      end
      parts[#parts + 1] = "  "
    end
  end
  return table.concat(parts)
end

-- ---- hint / filter line ----
function M.hint_line(view, filter)
  if filter and filter ~= "" then
    return ansi.fgtext("  Filter: " .. filter .. "  (<BS> to clear)", C.yellow)
  end
  local h = "  o/⏎:toggle  t:all  /:filter  M:mine  S:sprint  B:backlog  K:detail  m:md  gx:open  r:refresh  H:help  q:quit"
  if view == "JQL" then h = "  gj:new/history  J:rerun" .. h:gsub("^  o/⏎:toggle", "  o/⏎:toggle") end
  return ansi.fgtext(h, C.overlay)
end

-- ---- column header ----
function M.column_header(board_w, sort_col, sort_dir)
  local sw = M.summary_width(board_w)
  local cells = {
    { "Key", M.COL.key }, { "Title", sw }, { "Assignee", M.COL.assignee },
    { "Time", M.COL.time }, { "Status", M.COL.status },
  }
  local fields = { "key", "summary", "assignee", "time", "status" }
  local line = string.rep(" ", PREFIX_W)
  for i, c in ipairs(cells) do
    local label = c[1]
    if sort_col == fields[i] then label = label .. (sort_dir == "asc" and " ▲" or " ▼") end
    line = line .. ansi.fgtext(ansi.fit(label, c[2]), C.overlay, ansi.BOLD) .. "  "
  end
  return line
end

-- ---- progress bar (root time) ----
local function progress_bar(spent, estimate)
  spent = spent or 0
  estimate = estimate or 0
  local denom = math.max(estimate, spent)
  local filled = denom > 0 and math.floor((spent / denom) * 8) or 0
  filled = math.max(0, math.min(8, filled))
  local bar = ansi.fgtext(string.rep("▰", filled), C.blue) .. ansi.fgtext(string.rep("▱", 8 - filled), C.overlay)
  local ratio = ""
  if spent > 0 or estimate > 0 then
    ratio = " " .. model.format_time(spent) .. "/" .. model.format_time(estimate)
  end
  return bar, ratio
end

-- ---- one issue row ----
-- returns the full ANSI line. selected draws a colored gutter bar.
function M.issue_line(node, depth, board_w, selected)
  local sw = M.summary_width(board_w)
  local is_root = depth == 1
  local indent = string.rep("    ", depth - 1)

  local chevron = " "
  if node.children and #node.children > 0 then chevron = node.expanded and "" or "" end
  local icon, icon_c = type_icon(node.type)
  local prefix_used = ansi.width(chevron) + 1 + ansi.width(icon)
  local prefix_pad = string.rep(" ", math.max(1, PREFIX_W - prefix_used))

  -- summary shrinks with depth so trailing cols stay aligned
  local summary_w = math.max(10, sw - 4 * (depth - 1))

  -- key
  local key = is_root and ansi.fgtext(ansi.fit(node.key or "", M.COL.key), C.text, ansi.BOLD)
    or ansi.fgtext(ansi.fit(node.key or "", M.COL.key), C.overlay)
  -- summary
  local summary = is_root and ansi.fgtext(ansi.fit(node.summary or "", summary_w), C.text, ansi.BOLD)
    or ansi.fgtext(ansi.fit(node.summary or "", summary_w), C.overlay)
  -- assignee
  local ass = node.assignee or "Unassigned"
  local assignee = ass == "Unassigned"
    and ansi.fgtext(ansi.fit(ass, M.COL.assignee), C.graytext, ansi.ITALIC)
    or ansi.fgtext(ansi.fit(ass, M.COL.assignee), C.green)
  -- time
  local time_cell
  if is_root then
    local bar, ratio = progress_bar(node.time_spent, node.time_estimate)
    time_cell = ansi.fit(bar .. ansi.fgtext(ratio, C.overlay), M.COL.time)
  else
    local t = node.time_spent and node.time_spent > 0 and model.format_time(node.time_spent) or "-"
    time_cell = ansi.fgtext(ansi.fit(t, M.COL.time), C.overlay)
  end
  -- status badge: bg color, dark fg
  local st = ansi.truncate(node.status or "", M.COL.status - 2)
  local status = ansi.bgtext(" " .. ansi.pad(st, M.COL.status - 2) .. " ", C.base, status_bg(node.status), ansi.BOLD)

  local gutter = selected and ansi.fgtext("▌", C.sky, ansi.BOLD) .. " " or "  "
  return table.concat({
    gutter, indent,
    ansi.fgtext(chevron, C.overlay), " ", ansi.fgtext(icon, icon_c), prefix_pad,
    key, "  ", summary, "  ", assignee, "  ", time_cell, "  ", status,
  })
end

return M
