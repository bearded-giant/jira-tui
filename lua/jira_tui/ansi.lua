local M = {}

M.RESET = "\27[0m"

-- fg color codes
M.fg = {
  black = 30, red = 31, green = 32, yellow = 33, blue = 34,
  magenta = 35, cyan = 36, white = 37, gray = 90,
  bright_red = 91, bright_green = 92, bright_yellow = 93,
  bright_blue = 94, bright_cyan = 96, bright_white = 97,
}

M.BOLD = 1
M.DIM = 2
M.REVERSE = 7

function M.sgr(text, ...)
  local codes = { ... }
  if #codes == 0 or text == "" then return text end
  return "\27[" .. table.concat(codes, ";") .. "m" .. text .. M.RESET
end

-- display width approximated as utf8 codepoint count. nerd-font icons render
-- width 1 in practice. ponytail: wcwidth table if CJK/emoji alignment drifts.
function M.width(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

function M.truncate(s, max)
  if M.width(s) <= max then return s end
  local out, n = {}, 0
  local i = 1
  while i <= #s and n < max - 1 do
    local b = s:byte(i)
    local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
    out[#out + 1] = s:sub(i, i + len - 1)
    i = i + len
    n = n + 1
  end
  return table.concat(out) .. "…"
end

function M.pad(s, width)
  local w = M.width(s)
  if w >= width then return s end
  return s .. string.rep(" ", width - w)
end

return M
