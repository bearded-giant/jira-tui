local M = {}

function M.build_issue_tree(issues)
  local key_to_node = {}
  for _, issue in ipairs(issues) do
    local node = {}
    for k, v in pairs(issue) do node[k] = v end
    node.children = {}
    node.expanded = false
    key_to_node[node.key] = node
  end

  local roots = {}
  for _, issue in ipairs(issues) do
    local node = key_to_node[issue.key]
    if node then
      if node.parent and key_to_node[node.parent] then
        table.insert(key_to_node[node.parent].children, node)
      else
        table.insert(roots, node)
      end
    end
  end
  return roots
end

-- "2026-06-01T..." -> "2026-06-01"
function M.short_date(iso)
  if type(iso) ~= "string" then return "" end
  return iso:sub(1, 10)
end

-- age from created date to now: today / Nd / Nw / Nmo / Ny
function M.age(iso)
  if type(iso) ~= "string" then return "" end
  local y, mo, d = iso:match("(%d+)-(%d+)-(%d+)")
  if not y then return "" end
  local then_t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
  local days = math.floor((os.time() - then_t) / 86400)
  if days <= 0 then return "today" end
  if days < 14 then return days .. "d" end
  if days < 60 then return math.floor(days / 7) .. "w" end
  if days < 365 then return math.floor(days / 30) .. "mo" end
  return math.floor(days / 365) .. "y"
end

-- close shortcut: first transition landing on a done-ish status, in preference order
function M.pick_done_transition(trs)
  for _, want in ipairs({ "DONE", "CLOSED", "RESOLVED", "COMPLETE", "FINISHED" }) do
    for _, t in ipairs(trs or {}) do
      local to = ((type(t.to) == "table" and t.to.name or t.name) or ""):upper():gsub("%s", "")
      if to:find(want, 1, true) then return t end
    end
  end
  return nil
end

-- "title\n---\ndescription" -> title, description. no --- : first line is the
-- title, the rest (if any) the description.
function M.split_create_input(txt)
  local title, desc = txt:match("^(.-)\n%-%-%-+\n(.*)$")
  if not title then title, desc = txt:match("^([^\n]*)\n?(.*)$") end
  title = (title or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", " ")
  desc = (desc or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return title, desc ~= "" and desc or nil
end

-- client-side board filter: plain case-insensitive substring on summary or key
function M.matches(issue, filter)
  if not filter or filter == "" then return true end
  local f = filter:lower()
  return (issue.summary or ""):lower():find(f, 1, true) ~= nil
    or (issue.key or ""):lower():find(f, 1, true) ~= nil
end

-- "PE-1472", "Add rate limit" -> "pe-1472-add-rate-limit" (capped ~50, clean tail)
function M.branch_name(key, summary)
  local name = (key or ""):lower()
  local slug = (summary or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug ~= "" then name = name .. "-" .. slug end
  if #name > 50 then
    name = name:sub(1, 50)
    name = name:match("^(.-)%-[^%-]*$") or name -- drop the cut-off word
  end
  return (name:gsub("%-+$", ""))
end

function M.format_time(seconds)
  if not seconds or seconds <= 0 then return "0" end
  local hours = seconds / 3600
  if hours % 1 == 0 then return string.format("%d", hours) end
  return string.format("%.1f", hours)
end

-- depth-first flatten of expanded nodes into a render list of {node, depth}.
-- with_spacers inserts {spacer=true} between root groups (blank visual rows).
function M.flatten(roots, with_spacers)
  local out = {}
  local function walk(nodes, depth)
    for i, node in ipairs(nodes) do
      if with_spacers and depth == 1 and #out > 0 then
        out[#out + 1] = { spacer = true }
      end
      out[#out + 1] = { node = node, depth = depth, last = i == #nodes }
      if node.expanded and node.children and #node.children > 0 then
        walk(node.children, depth + 1)
      end
    end
  end
  walk(roots, 1)
  return out
end

local html_entities = {
  ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
  ["&quot;"] = '"', ["&#39;"] = "'", ["&apos;"] = "'", ["&nbsp;"] = " ",
}

-- luajit has no utf8.char; string.char throws above 255 (smart quotes are &#8217;)
local function utf8_char(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40) end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  if n < 0x110000 then
    return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
      0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return ""
end
M.utf8_char = utf8_char

local function decode_entities(str)
  return (str:gsub("&%w+;", html_entities)
    :gsub("&#[xX](%x+);", function(h) return utf8_char(tonumber(h, 16)) end)
    :gsub("&#(%d+);", function(n) return utf8_char(tonumber(n)) end))
end
M.decode_entities = decode_entities

local function parse_adf(node)
  if not node then return "" end
  if node.type == "text" then
    local text = decode_entities(node.text or "")
    if node.marks then
      for _, mark in ipairs(node.marks) do
        if mark.type == "strong" then text = "**" .. text .. "**" end
        if mark.type == "em" then text = "_" .. text .. "_" end
        if mark.type == "code" then text = "`" .. text .. "`" end
        if mark.type == "strike" then text = "~~" .. text .. "~~" end
        if mark.type == "link" then
          local href = mark.attrs and mark.attrs.href
          if href then text = string.format("[%s](%s)", text, href) end
        end
      end
    end
    return text
  elseif node.type == "hardBreak" then
    return "\n"
  elseif node.type == "mention" or node.type == "emoji" or node.type == "status" then
    local a = node.attrs or {}
    return a.text or a.shortName or a.name or ""
  elseif node.type == "inlineCard" or node.type == "embedCard" then
    local a = node.attrs or {}
    return a.url or ""
  elseif node.type == "media" then
    local a = node.attrs or {}
    return "[media" .. (a.alt and (": " .. a.alt) or "") .. "]"
  elseif node.content then
    local parts = {}
    for _, child in ipairs(node.content) do parts[#parts + 1] = parse_adf(child) end
    if node.type == "tableRow" then
      local cells = {}
      for _, cell in ipairs(parts) do cells[#cells + 1] = (cell:gsub("%s+$", "")) end
      return table.concat(cells, " | ") .. "\n"
    end
    local joined = table.concat(parts, "")
    if node.type == "table" then
      return joined .. "\n"
    elseif node.type == "paragraph" then
      return joined .. "\n\n"
    elseif node.type == "heading" then
      local level = node.attrs and node.attrs.level or 1
      return string.rep("#", level) .. " " .. joined .. "\n\n"
    elseif node.type == "listItem" then
      return joined
    elseif node.type == "bulletList" then
      local lp = {}
      for _, child in ipairs(node.content) do lp[#lp + 1] = "- " .. parse_adf(child) end
      return table.concat(lp, "") .. "\n"
    elseif node.type == "orderedList" then
      local lp = {}
      for i, child in ipairs(node.content) do lp[#lp + 1] = i .. ". " .. parse_adf(child) end
      return table.concat(lp, "") .. "\n"
    elseif node.type == "codeBlock" then
      local lang = node.attrs and node.attrs.language or ""
      return "```" .. lang .. "\n" .. joined .. "\n```\n\n"
    elseif node.type == "blockquote" then
      return "> " .. joined:gsub("\n", "> ") .. "\n\n"
    elseif node.type == "rule" then
      return "---\n\n"
    end
    return joined
  end
  return ""
end

function M.adf_to_markdown(adf)
  if not adf then return "" end
  return parse_adf(adf)
end

return M
