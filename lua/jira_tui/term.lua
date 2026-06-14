local M = {}

M.out = io.write

function M.size()
  -- read the controlling tty, not the popen pipe (pipe -> bogus 24x80 fallback)
  local p = io.popen("stty size </dev/tty 2>/dev/null")
  local s = p and p:read("*a") or ""
  if p then p:close() end
  local rows, cols = s:match("(%d+)%s+(%d+)")
  return tonumber(rows) or 24, tonumber(cols) or 80
end

function M.raw_on() os.execute("stty raw -echo 2>/dev/null") end
function M.raw_off() os.execute("stty sane 2>/dev/null") end
-- alt screen + hide cursor + enable SGR mouse (wheel)
function M.enter() M.out("\27[?1049h\27[?25l\27[?1000h\27[?1006h") end
function M.leave() M.out("\27[?1000l\27[?1006l\27[?25h\27[?1049l") end
function M.clear() M.out("\27[2J\27[H") end
function M.moveto(r, c) M.out("\27[" .. r .. ";" .. (c or 1) .. "H") end

-- single logical-key reader. swallows non-wheel mouse events (returns nil).
-- returns: printable char, "enter","esc","tab","bs","ctrl-s","up/down/left/right",
-- "wheelup","wheeldown","q"(ctrl-c), or nil (ignored mouse / unknown).
function M.read_key()
  local c = io.read(1)
  if not c then return "q" end
  if c == "\27" then
    local c2 = io.read(1)
    if c2 ~= "[" then return "esc" end
    local c3 = io.read(1)
    if c3 == "<" then -- SGR mouse: \27[<b;x;y(M|m)
      local seq = ""
      while true do
        local ch = io.read(1)
        if not ch or ch == "M" or ch == "m" then break end
        seq = seq .. ch
      end
      local b = tonumber(seq:match("^(%d+)"))
      if b == 64 then return "wheelup" end
      if b == 65 then return "wheeldown" end
      return nil
    end
    local map = { A = "up", B = "down", C = "right", D = "left" }
    return map[c3]
  end
  if c == "\13" or c == "\10" then return "enter" end
  if c == "\9" then return "tab" end
  if c == "\127" or c == "\8" then return "bs" end
  if c == "\19" then return "ctrl-s" end -- ctrl-s
  if c == "\3" then return "q" end       -- ctrl-c
  return c
end

return M
