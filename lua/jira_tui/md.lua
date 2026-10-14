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
      out[#out + 1] = span("│ ", ansi.fgc(C.overlay))
        .. span((line:gsub("^%s*>%s?", "")), ansi.fgc(C.subtext), ansi.ITALIC)
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

local function text_node(t, marks)
  local n = { type = "text", text = t }
  if marks then n.marks = marks end
  return n
end

local function alnum(ch) return ch ~= "" and ch:match("[%w]") ~= nil end

-- _em_ needs non-word chars around it so snake_case survives
local function inline_adf(s)
  local out, plain, i = {}, {}, 1
  local function flush()
    if #plain > 0 then out[#out + 1] = text_node(table.concat(plain)); plain = {} end
  end
  local function emit(node) flush(); out[#out + 1] = node end
  while i <= #s do
    local rest, prev = s:sub(i), s:sub(i - 1, i - 1)
    local code = rest:match("^`([^`]+)`")
    local strong = rest:match("^%*%*(.-[^%s])%*%*")
    local strike = rest:match("^~~(.-[^%s])~~")
    local lt, lu = rest:match("^%[([^%]]+)%]%(([^%)%s]+)%)")
    local url = not alnum(prev) and rest:match("^https?://[^%s<>]+")
    local em, emlen
    local d = rest:sub(1, 1)
    if (d == "_" or d == "*") and not alnum(prev) then
      em = rest:match("^%" .. d .. "([^%" .. d .. "%s][^%" .. d .. "]-)%" .. d)
      if em then
        emlen = #em + 2
        if alnum(rest:sub(emlen + 1, emlen + 1)) or em:match("%s$") then em = nil end
      end
    end
    if code then emit(text_node(code, { { type = "code" } })); i = i + #code + 2
    elseif strong then emit(text_node(strong, { { type = "strong" } })); i = i + #strong + 4
    elseif strike then emit(text_node(strike, { { type = "strike" } })); i = i + #strike + 4
    elseif lt then emit(text_node(lt, { { type = "link", attrs = { href = lu } } })); i = i + #lt + #lu + 4
    elseif url then
      url = url:gsub("[%.,;:!?%)]+$", "")
      emit(text_node(url, { { type = "link", attrs = { href = url } } })); i = i + #url
    elseif em then emit(text_node(em, { { type = "em" } })); i = i + emlen
    else plain[#plain + 1] = d; i = i + 1 end
  end
  flush()
  return out
end

-- paragraph lines joined by hardBreak (single newline in markdown = line break in jira)
local function paragraph(lines)
  local content = {}
  for n, l in ipairs(lines) do
    if n > 1 then content[#content + 1] = { type = "hardBreak" } end
    for _, node in ipairs(inline_adf(l)) do content[#content + 1] = node end
  end
  return { type = "paragraph", content = content }
end

local function list(kind, items)
  local content = {}
  for n, it in ipairs(items) do content[n] = { type = "listItem", content = { paragraph({ it }) } } end
  return { type = kind, content = content }
end

function M.to_adf(text)
  if not text or not text:match("%S") then return nil end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local blocks, para, i = {}, {}, 1
  local function flush()
    if #para > 0 then blocks[#blocks + 1] = paragraph(para); para = {} end
  end
  while i <= #lines do
    local line = lines[i]
    local fence = line:match("^%s*```%s*(%S*)%s*$")
    local hashes, htext = line:match("^(#+)%s+(.-)%s*$")
    if fence then
      flush()
      local body = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*```%s*$") do body[#body + 1] = lines[i]; i = i + 1 end
      local code = table.concat(body, "\n")
      blocks[#blocks + 1] = { type = "codeBlock", attrs = fence ~= "" and { language = fence } or nil,
        content = code ~= "" and { text_node(code) } or {} }
    elseif hashes and #hashes <= 6 then
      flush()
      blocks[#blocks + 1] = { type = "heading", attrs = { level = #hashes }, content = inline_adf(htext) }
    elseif line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") then
      flush()
      blocks[#blocks + 1] = { type = "rule" }
    elseif line:match("^%s*>") then
      flush()
      local q = {}
      while i <= #lines and lines[i]:match("^%s*>") do q[#q + 1] = lines[i]:gsub("^%s*>%s?", ""); i = i + 1 end
      i = i - 1
      local inner = M.to_adf(table.concat(q, "\n"))
      blocks[#blocks + 1] = { type = "blockquote", content = inner and inner.content or { paragraph({}) } }
    elseif line:match("^%s*[%-%*]%s+%S") or line:match("^%s*%d+[%.%)]%s+%S") then
      flush()
      local ordered = line:match("^%s*%d") ~= nil
      local pat = ordered and "^%s*%d+[%.%)]%s+(.*)$" or "^%s*[%-%*]%s+(.*)$"
      local items = {}
      while i <= #lines and lines[i]:match(pat) do items[#items + 1] = lines[i]:match(pat); i = i + 1 end
      i = i - 1
      blocks[#blocks + 1] = list(ordered and "orderedList" or "bulletList", items)
    elseif line:match("^%s*$") then
      flush()
    else
      para[#para + 1] = line
    end
    i = i + 1
  end
  flush()
  return { type = "doc", version = 1, content = blocks }
end

return M
