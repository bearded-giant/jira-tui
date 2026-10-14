local term = require("jira_tui.term")
local ansi = require("jira_tui.ansi")
local render = require("jira_tui.render")

local M = {}
local C = ansi.color

-- modals overlay the board; set on open so the diff renderer forces a full repaint after
M._dirty = false
function M.consume_dirty() local d = M._dirty; M._dirty = false; return d end

local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local function center(rows, cols, w, h)
  return math.max(1, math.floor((rows - h) / 2)), math.max(1, math.floor((cols - w) / 2))
end

-- rounded box, bright border + title. fills interior blank.
local function draw_box(top, left, w, h, title)
  local function row(r, s) term.moveto(r, left); term.out(s) end
  row(top, render.box_top(w, title))
  local side = ansi.fgtext("│", C.sky)
  for r = 1, h - 2 do
    row(top + r, side .. string.rep(" ", w - 2) .. side)
  end
  row(top + h - 1, ansi.fgtext("╰" .. string.rep("─", w - 2) .. "╯", C.sky))
end
M.draw_box = draw_box
M.center = center

-- cursor positions are byte offsets between codepoints (0..#s); stepping skips
-- utf-8 continuation bytes so edits never split a multibyte char.
-- shortcut: one codepoint = one cell, wide chars (cjk/emoji) misalign the cursor; fine for jql.
local function is_cont(s, i) local b = s:byte(i); return b and b >= 0x80 and b < 0xC0 end
local function cp_prev(s, p)
  p = p - 1
  while p > 0 and is_cont(s, p + 1) do p = p - 1 end
  return math.max(p, 0)
end
local function cp_next(s, p)
  p = p + 1
  while p < #s and is_cont(s, p + 1) do p = p + 1 end
  return math.min(p, #s)
end
local function cp_advance(s, p, n, limit)
  for _ = 1, n do if p >= limit then break end; p = cp_next(s, p) end
  return p
end
local function cp_count(s, a, b) return select(2, s:sub(a + 1, b):gsub("[^\128-\191]", "")) end
local function line_start(s, p) while p > 0 and s:sub(p, p) ~= "\n" do p = p - 1 end; return p end
local function line_end(s, p) local i = s:find("\n", p + 1, true); return i and i - 1 or #s end

-- bytes (a, b] of s, with the codepoint at cursor p reversed when a <= p <= b
local function span(s, a, b, p)
  if p < a or p > b then return ansi.fgtext(s:sub(a + 1, b), C.text) end
  local n = cp_next(s, p)
  local at = (p < #s and s:sub(p + 1, p + 1) ~= "\n") and s:sub(p + 1, n) or " "
  return ansi.fgtext(s:sub(a + 1, p), C.text) .. ansi.sgr(at, ansi.REVERSE)
    .. ansi.fgtext(p < b and s:sub(n + 1, b) or "", C.text)
end

-- text input modal. opts: {value, multiline, width, height, error}. returns string or nil (cancel).
-- multiline soft-wraps and scrolls; single-line scrolls horizontally.
function M.input(title, opts)
  M._dirty = true
  opts = opts or {}
  local rows, cols = term.size()
  local w = math.min(opts.width or 76, cols - 6)
  local h = opts.multiline and math.min(opts.height or 9, rows - 6) or 5
  local top, left = center(rows, cols, w, h)
  local buf = opts.value or ""
  local p = #buf
  local scroll = 0
  local vis, crow = {}, 1 -- wrapped rows from the last draw; up/down walk these, not logical lines
  local hint = opts.multiline and "Ctrl-s submit   Esc cancel" or "Enter submit   Esc cancel"

  local function insert(t) buf = buf:sub(1, p) .. t .. buf:sub(p + 1); p = p + #t end

  while true do
    draw_box(top, left, w, h, title)
    if opts.multiline then
      local tw, body = w - 5, h - 3
      vis, crow = {}, 1
      local ls = 0
      while true do
        local le = line_end(buf, ls)
        local a = ls
        repeat
          local b = cp_advance(buf, a, tw, le)
          local sp = b < le and buf:sub(a + 1, b):match(".*() ")
          if sp and sp > 1 then b = a + sp end
          vis[#vis + 1] = { a, b, last = b == le }
          if p >= a and (p < b or (p == b and b == le)) then crow = #vis end
          a = b
        until a >= le
        if le >= #buf then break end
        ls = le + 1
      end
      if crow <= scroll then scroll = crow - 1 end
      if crow > scroll + body then scroll = crow - body end
      for i = 1, body do
        local r = vis[scroll + i]
        if r then
          term.moveto(top + i, left + 2)
          term.out(span(buf, r[1], r[2], p))
        end
      end
    else
      local tw = w - 8
      local col = cp_count(buf, 0, p)
      if col < scroll then scroll = col end
      if col - scroll > tw then scroll = col - tw end
      local a = cp_advance(buf, 0, scroll, #buf)
      term.moveto(top + 2, left + 3)
      term.out(ansi.fgtext("❯ ", C.sky, ansi.BOLD) .. span(buf, a, cp_advance(buf, a, tw, #buf), p))
    end
    if opts.error then
      term.moveto(top + h - 2, left + 3)
      term.out(ansi.fgtext(ansi.truncate((opts.error:gsub("%s+", " ")), w - 6), C.red))
    end
    term.moveto(top + h - 1, left + 3)
    term.out(ansi.fgtext(" " .. hint .. " ", C.overlay))

    local k; repeat k = term.read_key() until k
    if k == "esc" or k == "ctrl-c" then return nil end
    if opts.multiline and k == "ctrl-s" then return trim(buf) end
    if not opts.multiline and k == "enter" then return trim(buf) end
    if k == "enter" and opts.multiline then insert("\n")
    elseif k == "bs" then
      if p > 0 then local a = cp_prev(buf, p); buf = buf:sub(1, a) .. buf:sub(p + 1); p = a end
    elseif k == "del" then
      if p < #buf then buf = buf:sub(1, p) .. buf:sub(cp_next(buf, p) + 1) end
    elseif k == "left" then p = cp_prev(buf, p)
    elseif k == "right" then p = cp_next(buf, p)
    elseif k == "home" then p = opts.multiline and line_start(buf, p) or 0
    elseif k == "end" then p = opts.multiline and line_end(buf, p) or #buf
    elseif opts.multiline and (k == "up" or k == "down") then
      local t = vis[crow + (k == "up" and -1 or 1)]
      if t then p = cp_advance(buf, t[1], cp_count(buf, vis[crow][1], p), t.last and t[2] or cp_prev(buf, t[2])) end
    elseif k == "tab" then insert("  ")
    elseif type(k) == "string" and #k == 1 and k:byte() >= 32 then insert(k) end
  end
end

local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function env(name) local v = os.getenv(name); return v ~= "" and v or nil end

-- swapped in tests. $VISUAL/$EDITOR may carry args ("code -w"), so they go unquoted.
M._run_editor = function(path)
  local ed = env("VISUAL") or env("EDITOR")
  if not ed then
    local ok = os.execute("command -v nvim >/dev/null 2>&1")
    ed = (ok == true or ok == 0) and "nvim" or "vi"
  end
  os.execute(ed .. " " .. shq(path))
end

-- edit text in the user's editor, outside raw mode + alt screen.
-- returns the new text, or nil when blank, unchanged, or the temp file failed.
function M.edit_external(initial, ext)
  initial = initial or ""
  local p = io.popen("umask 077; mktemp 2>/dev/null")
  local tmp = p and p:read("*l")
  if p then p:close() end
  if not tmp or tmp == "" then return nil end
  local path = tmp .. (ext or ".md")
  if not os.rename(tmp, path) then os.remove(tmp); return nil end
  local f = io.open(path, "w")
  if not f then os.remove(path); return nil end
  f:write(initial)
  f:close()
  term.leave(); term.raw_off()
  local ok = pcall(M._run_editor, path)
  term.raw_on(); term.enter()
  M._dirty = true
  f = io.open(path, "r")
  local text = f and f:read("*a") or nil
  if f then f:close() end
  os.remove(path)
  if not ok or not text then return nil end
  text = text:gsub("%s+$", "")
  if text == "" or text == initial:gsub("%s+$", "") then return nil end
  return text
end

-- select modal. items list, opts.format(item)->string, opts.keys {key = action}
-- + opts.hint for extra actions. "/" filters by case-insensitive substring; with
-- opts.on_filter(q) -> items, Enter in filter mode asks it for a new list instead.
-- returns item, index, action (nil on Enter) or nil.
function M.select(title, items, opts)
  M._dirty = true
  opts = opts or {}
  local fmt = opts.format or tostring
  local rows, cols = term.size()
  local w = math.min(opts.width or 76, cols - 4)
  local body = math.min(#items, rows - 8)
  if body < 1 then body = 1 end
  local h = body + 3
  local top, left = center(rows, cols, w, h)
  local sel, scroll = 1, 0
  local filter, filtering, shown = "", false, {}

  local function refilter()
    shown = {}
    local q = filter:lower()
    for i, it in ipairs(items) do
      if q == "" or fmt(it):lower():find(q, 1, true) then shown[#shown + 1] = i end
    end
    sel, scroll = 1, 0
  end
  refilter()

  while true do
    if sel <= scroll then scroll = sel - 1 end
    if sel > scroll + body then scroll = sel - body end
    if scroll < 0 then scroll = 0 end
    draw_box(top, left, w, h, title)
    for i = 1, body do
      local idx = scroll + i
      local it = shown[idx] and items[shown[idx]]
      term.moveto(top + i, left + 1)
      if it then
        local label = ansi.truncate(fmt(it), w - 4)
        if idx == sel then
          term.out(ansi.bgtext(" " .. ansi.pad(label, w - 3), C.base, C.yellow))
        else
          term.out(" " .. ansi.fgtext(label, C.text))
        end
      elseif i == 1 and #shown == 0 then
        term.out(" " .. ansi.fgtext("(no matches)", C.overlay, ansi.ITALIC))
      end
    end
    term.moveto(top + h - 1, left + 2)
    local foot
    if filtering then
      foot = string.format(" /%s   %d match%s   Enter %s   Esc clear ", filter, #shown, #shown == 1 and "" or "es",
        opts.on_filter and "search" or "keep")
    else
      foot = string.format(" %s%d/%d   j/k move   Enter select   / filter   %sEsc cancel ",
        filter ~= "" and ("/" .. filter .. "  ") or "", #shown > 0 and sel or 0, #shown,
        opts.hint and opts.hint .. "   " or "")
    end
    term.out(ansi.fgtext(ansi.truncate(foot, w - 4), C.overlay))

    local k; repeat k = term.read_key() until k
    local cur = shown[sel]
    if filtering then
      if k == "ctrl-c" then return nil
      elseif k == "esc" then filtering, filter = false, ""; refilter()
      elseif k == "enter" then
        filtering = false
        if opts.on_filter then items = opts.on_filter(filter) or items; filter = "" end
        refilter()
      elseif k == "bs" then filter = filter:gsub("[^\128-\191][\128-\191]*$", ""); refilter()
      elseif k == "down" and sel < #shown then sel = sel + 1
      elseif k == "up" and sel > 1 then sel = sel - 1
      elseif #k == 1 and k:byte() >= 32 then filter = filter .. k; refilter()
      end
    else
      if k == "esc" or k == "q" or k == "ctrl-c" then return nil end
      if k == "/" then filtering = true
      elseif opts.keys and opts.keys[k] and cur then return items[cur], cur, opts.keys[k] end
      if (k == "j" or k == "down" or k == "wheeldown") and sel < #shown then sel = sel + 1 end
      if (k == "k" or k == "up" or k == "wheelup") and sel > 1 then sel = sel - 1 end
      if k == "enter" and cur then return items[cur], cur end
    end
  end
end

-- detail popup width, shared with render.detail_text separator sizing
function M.detail_width(cols)
  return math.min(math.max(96, math.floor(cols * 0.7)), cols - 2)
end

-- scrollable detail box. text may contain newlines.
-- opts: alt = second text ("c" toggles, comments collapsed view),
--       actions = { [key] = fn -> { note, reload, close, nav } | nil },
--       reload = fn -> text, alt, title (nil keeps the current text), hint = footer hint for actions.
-- returns true when an action asked to navigate away, else nil.
function M.detail(title, text, opts)
  M._dirty = true
  opts = opts or {}
  local rows, cols = term.size()
  local w = M.detail_width(cols)
  local h = rows - 2
  local top, left = center(rows, cols, w, h)
  local body = h - 2
  local function build(t)
    local ls = {}
    for line in (t .. "\n"):gmatch("(.-)\n") do
      for _, wl in ipairs(ansi.wrap(line, w - 4)) do ls[#ls + 1] = wl end
    end
    return ls
  end
  local lines, alt_shown = build(text), false
  local scroll, note = 0, nil
  while true do
    draw_box(top, left, w, h, title)
    for i = 1, body do
      term.moveto(top + i, left + 2)
      term.out(ansi.fgtext(lines[scroll + i] or "", C.text))
    end
    local pos
    if #lines <= body then pos = "all"
    elseif scroll <= 0 then pos = "top"
    elseif scroll >= #lines - body then pos = "bot"
    else pos = math.floor((scroll + body) / #lines * 100) .. "%" end
    local hints = " j/k scroll"
      .. (opts.alt and "   c comments" or "") .. (opts.hint and "   " .. opts.hint or "")
      .. "   q back   " .. (note and note .. "   " or "") .. pos .. " "
    term.moveto(top + h - 1, left + 2)
    term.out(ansi.fgtext(ansi.truncate(hints, w - 4), C.overlay))
    local k; repeat k = term.read_key() until k
    note = nil
    if k == "q" or k == "esc" or k == "ctrl-c" then return end
    if (k == "j" or k == "down" or k == "wheeldown") and scroll < #lines - body then scroll = scroll + 1 end
    if (k == "k" or k == "up" or k == "wheelup") and scroll > 0 then scroll = scroll - 1 end
    if k == "ctrl-d" or k == "pgdn" then scroll = math.min(math.max(0, #lines - body), scroll + math.floor(body / 2)) end
    if k == "ctrl-u" or k == "pgup" then scroll = math.max(0, scroll - math.floor(body / 2)) end
    if k == "g" then scroll = 0 end
    if k == "G" then scroll = math.max(0, #lines - body) end
    if k == "c" and opts.alt then
      alt_shown = not alt_shown
      lines = build(alt_shown and opts.alt or text)
      scroll = math.min(scroll, math.max(0, #lines - body))
    end
    local act = opts.actions and opts.actions[k]
    if act then
      local res = act() or {}
      M._dirty = true
      note = res.note
      if res.close then return end
      if res.nav then return true end
      if res.reload and opts.reload then
        local t, a, ti = opts.reload()
        if t then
          text, opts.alt, title = t, a, ti or title
          if not a then alt_shown = false end
          lines = build(alt_shown and a or t)
          scroll = math.min(scroll, math.max(0, #lines - body))
        end
      end
    end
  end
end

-- help view content (rendered inside the board body by tui, not a modal)
local HELP = {
  { "Views", {
    { "M", "My Issues" }, { "1-9", "Saved query tabs (config queries)" },
    { "S", "Active Sprint" }, { "B", "Backlog" },
    { "→ / ←", "Cycle tabs" }, { "p", "Set / change project" },
  } },
  { "JQL", { { "J", "Pick from history / new (e edits a past query)" }, { "gj", "New query" } } },
  { "Navigation", {
    { "j / k", "Move (mouse wheel too)" }, { "⏎", "Open issue (expand if it has subtasks)" },
    { "Space / Tab / o", "Expand / collapse" }, { "Ctrl-d / Ctrl-u", "Half page down / up" },
    { "t", "Toggle all" }, { "/", "Filter loaded rows (summary / key, instant)" }, { "BS", "Clear filter" },
    { "gg / G", "Top / bottom" }, { "x", "Show/hide resolved" },
  } },
  { "Issue", {
    { "K / m", "Details + comments / raw markdown" },
    { "c / o (detail)", "Expand comments / open attachment" },
    { "] / [ (detail)", "Next / prev issue in board order" },
    { "in detail", "s a A e d C y Y b act on the shown issue" }, { "s", "Change status" },
    { "e", "Edit (summary / append description / status)" },
    { "c / gc", "Create (type picker, $EDITOR template) / child of the row" },
    { "d", "Close (first done-ish transition)" },
    { "a / A", "Assign (picker) / assign to me" }, { "C", "Comment ($EDITOR, markdown)" }, { "b / gx", "Open in browser" },
    { "y / Y", "Copy key / url" }, { "gb", "Copy git branch name" }, { "gs", "Sort column" },
  } },
  { "General", {
    { "r", "Refresh" }, { "H / ?", "Help (q / Esc closes it)" },
    { "/ (picker)", "Filter the list; in the assign picker Enter searches all users" },
    { "q", "Back (closes popups, never the app)" }, { "Esc", "Quit" },
  } },
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
