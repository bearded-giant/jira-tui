local term = require("jira_tui.term")
local ansi = require("jira_tui.ansi")

local M = {}
local C = ansi.color

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local function center(rows, cols, w, h)
  return math.max(1, math.floor((rows - h) / 2)), math.max(1, math.floor((cols - w) / 2))
end

-- rounded box, bright border + title. fills interior blank.
local function draw_box(top, left, w, h, title)
  local function row(r, s) term.moveto(r, left); term.out(s) end
  local tline
  if title then
    local t = " " .. title .. " "
    local rest = math.max(0, w - 3 - ansi.width(t))
    tline = ansi.fgtext("╭─", C.sky) .. ansi.fgtext(t, C.text, ansi.BOLD)
      .. ansi.fgtext(string.rep("─", rest) .. "╮", C.sky)
  else
    tline = ansi.fgtext("╭" .. string.rep("─", w - 2) .. "╮", C.sky)
  end
  row(top, tline)
  local side = ansi.fgtext("│", C.sky)
  for r = 1, h - 2 do
    row(top + r, side .. string.rep(" ", w - 2) .. side)
  end
  row(top + h - 1, ansi.fgtext("╰" .. string.rep("─", w - 2) .. "╯", C.sky))
end
M.draw_box = draw_box
M.center = center

-- text input modal. opts: {value, multiline, width, height, hint}. returns string or nil (cancel).
function M.input(title, opts)
  opts = opts or {}
  local rows, cols = term.size()
  local w = math.min(opts.width or 76, cols - 6)
  local h = opts.multiline and math.min(opts.height or 9, rows - 6) or 5
  local top, left = center(rows, cols, w, h)
  local buf = opts.value or ""
  local cursor = ansi.sgr(" ", ansi.REVERSE) -- visible block cursor
  local hint = opts.multiline and "Ctrl-s submit   Esc cancel" or "Enter submit   Esc cancel"

  while true do
    draw_box(top, left, w, h, title)
    if opts.multiline then
      local n = 0
      local lastlen = 0
      for _ in (buf .. "\n"):gmatch("(.-)\n") do lastlen = lastlen + 1 end
      n = 0
      for line in (buf .. "\n"):gmatch("(.-)\n") do
        if n < h - 3 then
          term.moveto(top + 1 + n, left + 2)
          local tail = (n == lastlen - 1) and cursor or ""
          term.out(ansi.fgtext(ansi.truncate(line, w - 5), C.text) .. tail)
        end
        n = n + 1
      end
    else
      term.moveto(top + 2, left + 3)
      term.out(ansi.fgtext("❯ ", C.sky, ansi.BOLD) .. ansi.fgtext(ansi.truncate(buf, w - 8), C.text) .. cursor)
    end
    term.moveto(top + h - 1, left + 3)
    term.out(ansi.fgtext(" " .. hint .. " ", C.overlay))

    local k = term.read_key()
    if k == "esc" then return nil end
    if opts.multiline and k == "ctrl-s" then return trim(buf) end
    if not opts.multiline and k == "enter" then return buf end
    if k == "enter" and opts.multiline then buf = buf .. "\n"
    elseif k == "bs" then buf = buf:sub(1, -2)
    elseif k == "tab" then buf = buf .. "  "
    elseif type(k) == "string" and #k == 1 and k:byte() >= 32 then buf = buf .. k end
  end
end

-- select modal. items list, opts.format(item)->string. returns item, index or nil.
function M.select(title, items, opts)
  opts = opts or {}
  local fmt = opts.format or tostring
  local rows, cols = term.size()
  local w = math.min(opts.width or 76, cols - 4)
  local body = math.min(#items, rows - 8)
  if body < 1 then body = 1 end
  local h = body + 3
  local top, left = center(rows, cols, w, h)
  local sel, scroll = 1, 0

  while true do
    if sel <= scroll then scroll = sel - 1 end
    if sel > scroll + body then scroll = sel - body end
    if scroll < 0 then scroll = 0 end
    draw_box(top, left, w, h, title)
    for i = 1, body do
      local idx = scroll + i
      local it = items[idx]
      term.moveto(top + i, left + 1)
      if it then
        local label = ansi.truncate(fmt(it), w - 4)
        if idx == sel then
          term.out(ansi.bgtext(" " .. ansi.pad(label, w - 3), C.base, C.yellow))
        else
          term.out(" " .. ansi.fgtext(label, C.text))
        end
      end
    end
    term.moveto(top + h - 1, left + 2)
    term.out(ansi.fgtext(string.format(" %d/%d   j/k move   Enter select   Esc cancel ", sel, #items), C.overlay))

    local k = term.read_key()
    if k == "esc" or k == "q" then return nil end
    if (k == "j" or k == "down" or k == "wheeldown") and sel < #items then sel = sel + 1 end
    if (k == "k" or k == "up" or k == "wheelup") and sel > 1 then sel = sel - 1 end
    if k == "enter" and items[sel] then return items[sel], sel end
  end
end

-- scrollable read-only detail box. text may contain newlines.
function M.detail(title, text)
  local rows, cols = term.size()
  local w = math.min(96, cols - 2)
  local h = rows - 2
  local top, left = center(rows, cols, w, h)
  local body = h - 2
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = ansi.width(line) > w - 4 and ansi.truncate(line, w - 4) or line
  end
  local scroll = 0
  while true do
    draw_box(top, left, w, h, title)
    for i = 1, body do
      term.moveto(top + i, left + 2)
      term.out(ansi.fgtext(lines[scroll + i] or "", C.text))
    end
    term.moveto(top + h - 1, left + 2)
    term.out(ansi.fgtext(" j/k scroll   q back ", C.overlay))
    local k = term.read_key()
    if k == "q" or k == "esc" then return end
    if (k == "j" or k == "down" or k == "wheeldown") and scroll < #lines - body then scroll = scroll + 1 end
    if (k == "k" or k == "up" or k == "wheelup") and scroll > 0 then scroll = scroll - 1 end
    if k == "g" then scroll = 0 end
    if k == "G" then scroll = math.max(0, #lines - body) end
  end
end

-- help view content (rendered inside the board body by tui, not a modal)
local HELP = {
  { "Views", {
    { "M", "My Issues" }, { "S", "Active Sprint" }, { "B", "Backlog" },
    { "→ / ←", "Cycle tabs" }, { "p", "Set / change project" },
  } },
  { "JQL", { { "J", "Run / pick from history" }, { "gj", "New query" } } },
  { "Navigation", {
    { "j / k", "Move (mouse wheel too)" }, { "o / ⏎ / Tab", "Expand / collapse" },
    { "t", "Toggle all" }, { "/", "Filter by summary" }, { "BS", "Clear filter" },
    { "g / G", "Top / bottom" }, { "x", "Show/hide resolved" },
  } },
  { "Issue", {
    { "K", "Details popup" }, { "m", "Read as markdown" },
    { "gx", "Open in browser" }, { "y", "Copy key" }, { "gs", "Sort column" },
  } },
  { "General", { { "r", "Refresh" }, { "H", "Help" }, { "q / Esc", "Quit" } } },
}

function M.help_lines(width)
  local out = {}
  local function add(s) out[#out + 1] = s end
  add("")
  for _, sec in ipairs(HELP) do
    add("  " .. ansi.fgtext(sec[1], C.yellow, ansi.BOLD))
    add("  " .. ansi.fgtext(string.rep("─", math.min(width - 4, 40)), C.overlay))
    for _, item in ipairs(sec[2]) do
      add("    " .. ansi.fgtext(ansi.pad(item[1], 14), C.sky) .. ansi.fgtext(item[2], C.text))
    end
    add("")
  end
  return out
end

return M
