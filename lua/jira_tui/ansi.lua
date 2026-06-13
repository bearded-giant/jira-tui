local M = {}

M.RESET = "\27[0m"
M.BOLD = 1
M.DIM = 2
M.ITALIC = 3
M.REVERSE = 7

-- jim's catppuccin-ish palette (hex -> truecolor). keeps the look the user tuned.
M.color = {
  text = "205;214;244",     -- #cdd6f4 root/title
  subtext = "166;173;200",  -- #a6adc8
  overlay = "108;112;134",  -- #6c7086 comment/child
  surface = "49;50;68",     -- #313244 inactive tab bg
  base = "30;30;46",        -- #1e1e2e
  red = "243;139;168",      -- #f38ba8 bug/block
  green = "166;227;161",    -- #a6e3a1 story/done
  yellow = "249;226;175",   -- #f9e2af in-progress
  blue = "137;180;250",     -- #89b4fa task/todo
  teal = "148;226;213",     -- #94e2d5 subtask
  peach = "250;179;135",    -- #fab387 test
  mauve = "203;166;247",    -- #cba6f7 design/review
  sky = "137;220;235",      -- #89dceb imp
  graytext = "147;153;178", -- #9399b2 overhead/unassigned
}

local function fg(rgb) return "38;2;" .. rgb end
local function bg(rgb) return "48;2;" .. rgb end
M.fgc = fg
M.bgc = bg

-- sgr(text, code, code, ...) wraps text, resets after. codes are sgr params.
function M.sgr(text, ...)
  local codes = { ... }
  if #codes == 0 or text == "" then return text end
  return "\27[" .. table.concat(codes, ";") .. "m" .. text .. M.RESET
end

function M.fgtext(text, rgb, ...) return M.sgr(text, fg(rgb), ...) end
function M.bgtext(text, fg_rgb, bg_rgb, ...) return M.sgr(text, fg(fg_rgb), bg(bg_rgb), ...) end

-- strip sgr for width math
function M.strip(s) return (s:gsub("\27%[[%d;?]*m", "")) end

-- display width = utf8 codepoint count (nerd glyphs render width 1 in practice).
-- ponytail: wcwidth table if CJK/emoji alignment drifts.
function M.width(s)
  s = M.strip(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

function M.truncate(s, max)
  if M.width(s) <= max then return s end
  local out, n, i = {}, 0, 1
  while i <= #s and n < max - 1 do
    local b = s:byte(i)
    local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
    out[#out + 1] = s:sub(i, i + len - 1)
    i = i + len
    n = n + 1
  end
  return table.concat(out) .. "…"
end

-- pad/truncate raw text (no sgr inside) to exactly width display cells
function M.fit(s, width)
  s = M.truncate(s, width)
  local w = M.width(s)
  if w < width then s = s .. string.rep(" ", width - w) end
  return s
end

function M.pad(s, width)
  local w = M.width(s)
  if w >= width then return s end
  return s .. string.rep(" ", width - w)
end

return M
