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

-- one-line editing keys shared by input and form. returns buf, p, or nil when k isn't one of them
local function line_key(buf, p, k)
  if k == "bs" then
    if p == 0 then return buf, p end
    local a = cp_prev(buf, p)
    return buf:sub(1, a) .. buf:sub(p + 1), a
  elseif k == "del" then
    if p < #buf then buf = buf:sub(1, p) .. buf:sub(cp_next(buf, p) + 1) end
    return buf, p
  elseif k == "left" then return buf, cp_prev(buf, p)
  elseif k == "right" then return buf, cp_next(buf, p)
  elseif k == "home" then return buf, 0
  elseif k == "end" then return buf, #buf
  elseif type(k) == "string" and #k == 1 and k:byte() >= 32 then return buf:sub(1, p) .. k .. buf:sub(p + 1), p + 1 end
end

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
    elseif opts.multiline and k == "home" then p = line_start(buf, p)
    elseif opts.multiline and k == "end" then p = line_end(buf, p)
    elseif opts.multiline and (k == "up" or k == "down") then
      local t = vis[crow + (k == "up" and -1 or 1)]
      if t then p = cp_advance(buf, t[1], cp_count(buf, vis[crow][1], p), t.last and t[2] or cp_prev(buf, t[2])) end
    elseif k == "tab" then insert("  ")
    else
      local nb, np = line_key(buf, p, k)
      if nb then buf, p = nb, np end
    end
  end
end

local FORM_KIND_HINT = { text = "type to edit", pick = "⏎ choose", toggle = "⏎ / Space switch",
  editor = "⏎ open $EDITOR   BS clear" }

-- labelled form modal. fields: { name, label, kind = text|pick|toggle|editor, required, hint, options }.
-- values: name -> string, edited in place. hint is the placeholder for an empty field and its footer help.
-- opts.pick(field, values) -> value | nil, err (pick fields); opts.error shown under the fields, opts.focus its field;
-- opts.submit names the ctrl-s action; opts.backdrop repaints what's behind after a picker or $EDITOR;
-- opts.pristine is what counts as untouched for Esc (default: values as passed in).
-- returns values on ctrl-s once required fields are filled, nil on cancel.
function M.form(title, fields, values, opts)
  M._dirty = true
  opts = opts or {}
  local start = opts.pristine
  if not start then
    start = {}
    for k, v in pairs(values) do start[k] = v end
  end
  local focus = 1
  for i, f in ipairs(fields) do
    if f.required and (values[f.name] or "") == "" then focus = i; break end
  end
  for i, f in ipairs(fields) do if f.name == opts.focus then focus = i end end
  local p = #(values[fields[focus].name] or "")
  local err, note = opts.error, nil
  local armed = false
  local lw = 0
  for _, f in ipairs(fields) do lw = math.max(lw, ansi.width(f.label) + 4) end

  local function move(d)
    focus = (focus - 1 + d) % #fields + 1
    p = #(values[fields[focus].name] or "")
  end

  while true do
    local rows, cols = term.size()
    local w = math.min(90, cols - 4)
    local vw = w - lw - 6
    local lines = {}
    -- preview rows come out of what the fields leave, so a short terminal never hides a field
    local budget = math.max(0, rows - 7 - #fields)
    for i, f in ipairs(fields) do
      local v = values[f.name] or ""
      local on = i == focus
      local label = ansi.fgtext(ansi.pad(f.label .. (f.required and " *" or ""), lw), on and C.yellow or C.sky,
        on and ansi.BOLD or nil)
      local shown
      if on and f.kind == "text" then
        local a = cp_advance(v, 0, math.max(0, cp_count(v, 0, p) - vw + 1), #v)
        shown = span(v, a, cp_advance(v, a, vw, #v), p)
      elseif v == "" then
        shown = ansi.fgtext(ansi.truncate(f.hint or "", vw), C.overlay, ansi.ITALIC)
      else
        shown = ansi.fgtext(ansi.truncate(v:match("^[^\n]*"), vw), C.text)
      end
      lines[#lines + 1] = (on and ansi.fgtext(" ▌ ", C.sky, ansi.BOLD) or "   ") .. label .. shown
      if f.kind == "editor" and v ~= "" then
        local more, n = {}, 0
        for l in (v .. "\n"):gmatch("(.-)\n") do n = n + 1; if n > 1 and l:match("%S") then more[#more + 1] = l end end
        local cap = math.min(4, budget)
        local shown_n = #more > cap and math.max(0, cap - 1) or #more
        for j = 1, shown_n do
          lines[#lines + 1] = string.rep(" ", lw + 3) .. ansi.fgtext(ansi.truncate(more[j], vw), C.subtext)
        end
        if #more > shown_n and cap > 0 then
          lines[#lines + 1] = string.rep(" ", lw + 3) .. ansi.fgtext("… " .. (#more - shown_n) .. " more lines", C.overlay)
        end
      end
    end
    local h = math.min(#lines + 5, rows - 2)
    local top, left = center(rows, cols, w, h)
    draw_box(top, left, w, h, title)
    for i = 1, math.min(#lines, h - 5) do
      term.moveto(top + 1 + i, left + 1)
      term.out(ansi.cut(lines[i], w - 2))
    end
    if err or note then
      term.moveto(top + h - 2, left + 4)
      term.out(ansi.fgtext(ansi.truncate(((err or note):gsub("%s+", " ")), w - 8), err and C.red or C.yellow))
    end
    local f = fields[focus]
    term.moveto(top + h - 1, left + 3)
    local fh = f.kind == "text" and f.hint or FORM_KIND_HINT[f.kind]
    term.out(ansi.fgtext(ansi.truncate(" " .. fh .. "   Tab / ↑↓ field   Ctrl-s " .. (opts.submit or "submit")
      .. "   Esc cancel ", w - 6), C.overlay))

    local k; repeat k = term.read_key() until k
    local was_armed = armed
    armed, note = false, nil
    local v = values[f.name] or ""
    if k == "ctrl-c" then return nil
    elseif k == "esc" then
      local changed = false
      for _, fd in ipairs(fields) do if (values[fd.name] or "") ~= (start[fd.name] or "") then changed = true end end
      if not changed or was_armed then return nil end
      armed, note = true, "Esc again to discard this form"
    elseif k == "ctrl-s" then
      err = nil
      for i, fd in ipairs(fields) do
        if fd.required and (values[fd.name] or ""):match("^%s*$") then
          err = fd.label .. " is required"; focus = i; p = #(values[fd.name] or ""); break
        end
      end
      if not err then
        for _, fd in ipairs(fields) do
          if fd.kind == "text" then values[fd.name] = trim(values[fd.name] or "") end
        end
        return values
      end
    elseif k == "tab" or k == "down" then move(1)
    elseif k == "btab" or k == "up" then move(-1)
    elseif f.kind == "text" then
      if k == "enter" then move(1)
      else
        local nb, np = line_key(v, p, k)
        if nb then values[f.name], p = nb, np end
      end
    elseif f.kind == "toggle" and (k == "enter" or k == " ") then
      local choices = f.options or {}
      local idx = 0
      for i, o in ipairs(choices) do if o == v then idx = i end end
      values[f.name] = choices[idx % #choices + 1]
    elseif f.kind == "editor" and (k == "bs" or k == "del") then values[f.name] = ""
    elseif (f.kind == "pick" and (k == "enter" or k == " ")) or (f.kind == "editor" and k == "enter") then
      local nv, perr
      if f.kind == "editor" then nv = M.edit_external(v, ".md")
      elseif opts.pick then nv, perr = opts.pick(f, values) end
      if nv then values[f.name] = nv end
      if perr then err = perr end
      if opts.backdrop then opts.backdrop() end
      M._dirty = true
    end
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
-- + opts.hint for extra actions. returns item, index, action (nil on Enter) or nil.
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
-- returns the nav value of the action that ended it, else nil (q / Esc).
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
  local query, matches, mi = nil, {}, 0
  local function find_matches()
    matches = {}
    if not query then return end
    for i, l in ipairs(lines) do
      if ansi.strip(l):lower():find(query, 1, true) then matches[#matches + 1] = i end
    end
    mi = math.min(math.max(mi, 1), #matches)
  end
  local function goto_match(i)
    mi = i
    scroll = math.min(matches[i] - 1, math.max(0, #lines - body))
  end
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
    local hints = " " .. (note and note .. "   " or "")
      .. (#matches > 0 and ("match " .. mi .. "/" .. #matches .. "   ") or "")
      .. (opts.hint and opts.hint .. "   " or "") .. (opts.alt and "c comments   " or "") .. "/ search   q back"
    local tail = "   " .. pos .. " "
    term.moveto(top + h - 1, left + 2)
    term.out(ansi.fgtext(ansi.truncate(hints, w - 4 - ansi.width(tail)) .. tail, C.overlay))
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
      find_matches()
    end
    if k == "/" then
      local q = M.input("Search", { width = 50 })
      M._dirty = true
      if q and q ~= "" then
        query, mi = q:lower(), 0
        find_matches()
        if #matches == 0 then
          note, query = "no match: " .. q, nil
        else
          local first = 1
          for i, ln in ipairs(matches) do if ln > scroll then first = i; break end end
          goto_match(first)
        end
      end
    end
    if (k == "n" or k == "N") and #matches > 0 then
      goto_match((mi - 1 + (k == "n" and 1 or -1)) % #matches + 1)
    end
    local act = opts.actions and opts.actions[k]
    if act then
      local res = act() or {}
      M._dirty = true
      note = res.note
      if res.close then return end
      if res.nav then return res.nav end
      if res.reload and opts.reload then
        local t, a, ti = opts.reload()
        if t then
          text, opts.alt, title = t, a, ti or title
          if not a then alt_shown = false end
          lines = build(alt_shown and a or t)
          scroll = math.min(scroll, math.max(0, #lines - body))
          find_matches()
        end
      end
    end
  end
end

-- help view content (rendered inside the board body by tui, not a modal)
local HELP = {
  { "Views", {
    { "M", "My Issues" }, { "P", "Project: its open issues, no sprint filter" },
    { "p", "Switch project (opens its Project view)" }, { "1-9", "Saved query tabs (config queries)" },
    { "S", "Sprints: pick active, future or past, then list" }, { "B", "Backlog" },
    { "← / →", "Cycle tabs" }, { "J", "JQL history picker (e edits a past query)" },
    { "gj", "New JQL query" }, { "r", "Refresh (skips the view cache)" },
  } },
  { "Navigation", {
    { "j / k", "Move (arrows, mouse wheel; click selects)" },
    { "Ctrl-d / Ctrl-u", "Half page down / up" }, { "gg / G", "Top / bottom" },
    { "⏎", "Open detail (expands a row with subtasks)" },
    { "Space / Tab / o", "Expand / collapse" }, { "t", "Toggle all" },
    { "/", "Filter: words @who @me s: t: p: l: (all must match)" },
    { "BS", "Clear filter" }, { "x", "Show / hide resolved" },
    { "gs", "Sort by column" }, { "gi", "Go to issue by key or url" },
  } },
  { "Issue", {
    { "y / Y", "Copy key / url" }, { "gb", "Copy git branch name" },
    { "c / gc", "Create (form) in project / child of the row" },
    { "K / m", "Detail / raw markdown" }, { "s", "Change status" },
    { "e", "Edit summary, description, priority, points…" },
    { "a / A", "Assign (picker) / assign to me" }, { "C", "Comment ($EDITOR, markdown)" },
    { "w", "Log work (1h 30m, 2d, 45m)" },
    { "d", "Close (first done-ish transition)" }, { "b / gx", "Open in browser" },
  } },
  { "Detail view", {
    { "j / k, g / G", "Scroll, top / bottom" }, { "c", "Expand / collapse comments" },
    { "o", "Open an attachment" }, { "] / [", "Next / prev issue in board order" },
    { "L", "Parent / subtask / linked issue" }, { "/ n N", "Search, next / prev match" },
    { "y Y b", "Copy key / url, open in browser" }, { "s a A e d C w", "Same as the board, on the shown issue" },
    { "q / Esc", "Back (undoes L jumps first)" },
  } },
  { "Pickers, prompts, forms", {
    { "/", "Filter a picker (assign: Enter searches users)" },
    { "⏎ / Ctrl-s", "Submit (Ctrl-s in multi-line prompts and forms)" },
    { "Tab / ↑↓", "Next / prev form field (Shift-Tab back)" },
    { "Esc", "Cancel (in a picker filter: clear it)" },
  } },
  { "General", {
    { "? / H", "This help (j/k scroll, q / Esc closes)" },
    { "q", "Back (closes popups, never the app)" },
    { "Esc", "Cancel load / clear filter / clear message" },
    { "Esc Esc", "Quit" }, { "Ctrl-c", "Quit now" },
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
      add("    " .. ansi.fgtext(ansi.pad(item[1], 16), C.sky) .. ansi.fgtext(item[2], C.text))
    end
    add("")
  end
  return out
end

return M
