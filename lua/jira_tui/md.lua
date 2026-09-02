local ansi = require("jira_tui.ansi")

local M = {}
local C = ansi.color

-- spans restore the popup's base text color instead of resetting to terminal
-- default, so styled fragments can sit inside a colored line
local RESTORE = ansi.RESET .. "\27[" .. ansi.fgc(C.text) .. "m"
local function span(s, ...)
  return "\27[" .. table.concat({ ... }, ";") .. "m" .. s .. RESTORE
end

local RULE = span(string.rep("─", 36), ansi.fgc(C.overlay))

local function inline(s)
  s = s:gsub("%[(.-)%]%((.-)%)", function(t, u)
    if t == u or t == "" then return span(u, ansi.fgc(C.sky), ansi.UNDERLINE) end
    return span(t, ansi.fgc(C.sky), ansi.UNDERLINE) .. span(" (" .. u .. ")", ansi.fgc(C.overlay))
  end)
  s = s:gsub("`([^`]+)`", function(c) return span(c, ansi.fgc(C.peach)) end)
  s = s:gsub("%*%*(.-)%*%*", function(b) return span(b, ansi.fgc(C.text), ansi.BOLD) end)
  return s
end

-- markdown text -> ansi-styled text for the detail popup. line-based; fences
-- are the only cross-line state. italic/strike markers left alone (snake_case
-- prose makes _..._ too ambiguous to touch).
function M.to_ansi(text)
  local out = {}
  local in_fence = false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local fence = line:match("^%s*```(.*)$")
    if fence then
      if in_fence then
        out[#out + 1] = RULE
      else
        local lang = fence ~= "" and (" " .. fence .. " ") or ""
        out[#out + 1] = span("──" .. lang .. string.rep("─", math.max(0, 34 - ansi.width(lang))), ansi.fgc(C.overlay))
      end
      in_fence = not in_fence
    elseif in_fence then
      out[#out + 1] = span("  " .. line, ansi.fgc(C.peach))
    elseif line:match("^#+%s") then
      local hashes, t = line:match("^(#+)%s+(.*)$")
      out[#out + 1] = span(t, ansi.fgc(#hashes == 1 and C.yellow or C.sky), ansi.BOLD)
    elseif line:match("^%-%-%-+%s*$") then
      out[#out + 1] = RULE
    elseif line:match("^%s*>") then
      -- adf blockquotes collapse inner newlines to '> '; split them back out
      -- ponytail: a literal '> ' inside quoted prose also splits, live with it
      local body = line:gsub("^%s*>%s?", ""):gsub("%s*>%s?", "\n")
      for piece in (body .. "\n"):gmatch("(.-)\n") do
        if piece ~= "" then
          out[#out + 1] = span("│ ", ansi.fgc(C.overlay)) .. span(piece, ansi.fgc(C.subtext), ansi.ITALIC)
        end
      end
    else
      local indent, item = line:match("^(%s*)%- (.*)$")
      if indent then
        out[#out + 1] = indent .. span("•", ansi.fgc(C.sky)) .. " " .. inline(item)
      else
        out[#out + 1] = inline(line)
      end
    end
  end
  return table.concat(out, "\n")
end

return M
