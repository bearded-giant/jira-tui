local ansi = require("jira_tui.ansi")
local model = require("jira_tui.model")

local M = {}

local TYPE_ICON = {
  Bug = { "", ansi.fg.red },
  Story = { "", ansi.fg.green },
  Task = { "", ansi.fg.blue },
  ["Sub-task"] = { "󰙅", ansi.fg.cyan },
  Subtask = { "󰙅", ansi.fg.cyan },
  Epic = { "", ansi.fg.magenta },
}

local function type_icon(t)
  local e = TYPE_ICON[t]
  if e then return e[1], e[2] end
  return "●", ansi.fg.gray
end

local function status_color(node)
  local cat = node.status_category
  if cat == "Done" then return ansi.fg.green end
  if cat == "In Progress" then return ansi.fg.yellow end
  if cat == "To Do" then return ansi.fg.gray end
  return ansi.fg.white
end

local COL_KEY = 12
local COL_STATUS = 16
local COL_ASSIGNEE = 16
local COL_META = 10 -- points + time

-- one issue row. `selected` draws a colored gutter bar instead of reverse video
-- (embedded SGR resets make reverse video on a multi-color line unreliable).
function M.issue_line(entry, term_width, selected)
  local node, depth = entry.node, entry.depth
  local gutter = selected and ansi.sgr("▌", ansi.fg.bright_cyan, ansi.BOLD) .. " " or "  "
  local indent = string.rep("  ", depth - 1)

  local chevron = " "
  if node.children and #node.children > 0 then
    chevron = node.expanded and "" or ""
  end
  local icon, icon_c = type_icon(node.type)

  local pts = node.story_points and string.format("%g", node.story_points) or ""
  local time = model.format_time(node.time_spent)
  local meta = ansi.pad(pts, 4) .. ansi.sgr(ansi.pad(time .. "h", COL_META - 4), ansi.fg.gray)

  local key = ansi.sgr(ansi.pad(node.key or "", COL_KEY), depth == 1 and ansi.fg.bright_white or ansi.fg.gray, ansi.BOLD)
  local status = ansi.sgr(ansi.pad(ansi.truncate(node.status, COL_STATUS - 1), COL_STATUS), status_color(node))
  local assignee = ansi.sgr(ansi.pad(ansi.truncate(node.assignee, COL_ASSIGNEE - 1), COL_ASSIGNEE), ansi.fg.cyan)

  local prefix_w = ansi.width(indent) + 2 + 2 -- indent + chevron+space + icon+space
  local fixed = prefix_w + COL_KEY + 2 + COL_STATUS + 2 + COL_ASSIGNEE + 2 + COL_META + 2
  local summary_w = math.max(10, term_width - fixed)
  local summary = ansi.pad(ansi.truncate(node.summary or "", summary_w), summary_w)

  return table.concat({
    gutter,
    indent,
    ansi.sgr(chevron, ansi.fg.gray), " ",
    ansi.sgr(icon, icon_c), " ",
    key, "  ",
    summary, "  ",
    status, "  ",
    assignee, "  ",
    meta,
  })
end

function M.header(ctx, term_width)
  local title = ansi.sgr(" jira-tui ", ansi.fg.black, 47) -- white bg
  local view = ansi.sgr(" " .. (ctx.view or "") .. " ", ansi.fg.bright_yellow, ansi.BOLD)
  local proj = ctx.project and ansi.sgr(ctx.project, ansi.fg.cyan) or ""
  local count = ansi.sgr(string.format("%d issues", ctx.count or 0), ansi.fg.gray)
  local right = ansi.sgr("[r]efresh [/]filter [S]print [B]acklog [J]ql [q]uit", ansi.fg.gray)
  local left = table.concat({ title, " ", view, " ", proj, "  ", count }, "")
  local pad = math.max(1, term_width - ansi.width(left:gsub("\27%[[%d;]*m", "")) - ansi.width(right:gsub("\27%[[%d;]*m", "")))
  return left .. string.rep(" ", pad) .. right
end

return M
