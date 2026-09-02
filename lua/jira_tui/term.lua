local M = {}

M.out = io.write

-- size is cached ~1s: draw + the 0.2s idle tick both call it, and each uncached
-- call forks stty. resize detection just lags up to a second.
local size_r, size_c, size_at
function M.size()
  local now = os.time()
  if size_at == now then return size_r, size_c end
  -- read the controlling tty, not the popen pipe (pipe -> bogus 24x80 fallback)
  local p = io.popen("stty size </dev/tty 2>/dev/null")
  local s = p and p:read("*a") or ""
  if p then p:close() end
  local rows, cols = s:match("(%d+)%s+(%d+)")
  size_r, size_c, size_at = tonumber(rows) or 24, tonumber(cols) or 80, now
  return size_r, size_c
end

-- raw + non-blocking reads (0.2s timeout) so the loop can wake to detect resize.
-- raw_on snapshots the real settings (stty -g) so raw_off restores them exactly
-- instead of guessing with `stty sane`.
local saved_stty
function M.raw_on()
  local p = io.popen("stty -g </dev/tty 2>/dev/null")
  local snap = p and p:read("*l")
  if p then p:close() end
  if snap and snap ~= "" then saved_stty = snap end
  os.execute("stty raw -echo min 0 time 2 </dev/tty 2>/dev/null")
end
function M.raw_off()
  os.execute("stty " .. (saved_stty or "sane") .. " </dev/tty 2>/dev/null")
end

function M.isatty()
  local ok = os.execute("test -t 0")
  return ok == true or ok == 0
end
-- alt screen + hide cursor + enable SGR mouse (wheel)
function M.enter() M.out("\27[?1049h\27[?25l\27[?1000h\27[?1006h") end
function M.leave() M.out("\27[?1000l\27[?1006l\27[?25h\27[?1049l") end
function M.clear() M.out("\27[2J\27[H") end
function M.moveto(r, c) M.out("\27[" .. r .. ";" .. (c or 1) .. "H") end

-- byte reader behind read_key; tests swap it for a string-backed one
M.read = function(n) return io.read(n) end

local FINAL = { A = "up", B = "down", C = "right", D = "left", H = "home", F = "end" }
local TILDE = { ["1"] = "home", ["4"] = "end", ["5"] = "pgup", ["6"] = "pgdn", ["7"] = "home", ["8"] = "end" }

-- consume one CSI: ESC [ params(0x30-0x3F)* final(0x40-0x7E). unknown finals return nil
-- but the whole sequence is always eaten so it can't leak bytes as keystrokes.
local function read_csi()
  local params = ""
  while true do
    local ch = M.read(1)
    if not ch then return nil end
    local b = ch:byte()
    if b >= 0x40 and b <= 0x7E then
      if params:sub(1, 1) == "<" and (ch == "M" or ch == "m") then -- SGR mouse \27[<b;x;yM
        local btn = tonumber(params:match("^<(%d+)"))
        if btn == 64 then return "wheelup" end
        if btn == 65 then return "wheeldown" end
        return nil
      end
      if ch == "M" and params == "" then M.read(3); return nil end -- x10 mouse: 3 trailing bytes
      if ch == "~" then return TILDE[params] end
      return FINAL[ch] -- modifiers (1;5A = ctrl-up) ignored; F-keys and the rest -> nil
    end
    params = params .. ch
  end
end

-- single logical-key reader. returns a printable char or one of:
-- enter esc tab bs ctrl-s ctrl-c ctrl-d ctrl-u up down left right home end pgup pgdn wheelup wheeldown.
-- nil = nothing to report: no input (timeout on a tty, EOF on a pipe) or a swallowed sequence.
function M.read_key()
  local c = M.read(1)
  if not c then return nil end
  if c == "\27" then
    -- stty `time 2`: no byte within 0.2s means a bare escape, not a sequence prefix
    local c2 = M.read(1)
    if not c2 then return "esc" end
    if c2 == "[" then return read_csi() end
    if c2 == "O" then return FINAL[M.read(1)] end -- SS3: app-mode arrows; F1-F4 -> nil
    return nil -- alt+key
  end
  if c == "\13" or c == "\10" then return "enter" end
  if c == "\9" then return "tab" end
  if c == "\127" or c == "\8" then return "bs" end
  if c == "\19" then return "ctrl-s" end
  if c == "\3" then return "ctrl-c" end
  if c == "\4" then return "ctrl-d" end
  if c == "\21" then return "ctrl-u" end
  return c
end

return M
