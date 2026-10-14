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

-- replace the row with row.key in place; index or nil when absent
function M.replace_row(raw, row)
  for i, r in ipairs(raw) do
    if r.key == row.key then raw[i] = row; return i end
  end
end

-- replace the row with row.key in place, else append. returns its index.
function M.upsert_row(raw, row)
  local i = M.replace_row(raw, row)
  if i then return i end
  raw[#raw + 1] = row
  return #raw
end

-- ttl seconds; 0 / nil disables
function M.cache_fresh(entry, ttl, now)
  return entry ~= nil and (ttl or 0) > 0 and now - entry.at < ttl
end

-- embedded fields.comment is oldest first and capped (100). returns up to n newest first,
-- plus true when total > page, i.e. the newest comments aren't in it.
function M.recent_comments(field, n)
  if type(field) ~= "table" or type(field.comments) ~= "table" then return {}, false end
  local cs, out = field.comments, {}
  for i = #cs, math.max(1, #cs - n + 1), -1 do out[#out + 1] = cs[i] end
  return out, (tonumber(field.total) or #cs) > #cs
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

function M.split_labels(s)
  local out = {}
  for w in (s or ""):gmatch("[^,%s]+") do out[#out + 1] = w end
  return out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function M.parse_points(s)
  local n = tonumber(s)
  if not n or n < 0 then return nil, "points must be a number >= 0" end
  return n
end

-- jira duration ("1h 30m", "2d", "1h30m") -> normalized "1h 30m", or nil when malformed / zero
function M.valid_duration(s)
  local compact = (s or ""):lower():gsub("%s+", "")
  if compact == "" then return nil end
  local parts, pos, total = {}, 1, 0
  while pos <= #compact do
    local n, unit, nxt = compact:match("^(%d+)([wdhm])()", pos)
    if not n then return nil end
    parts[#parts + 1] = n .. unit
    total = total + tonumber(n)
    pos = nxt
  end
  return total > 0 and table.concat(parts, " ") or nil
end

-- parent, subtasks, then issue links (labelled from this issue's side) as { rel, key, summary, status }
function M.related(fields)
  local out = {}
  local function add(rel, iss)
    if type(iss) ~= "table" or not iss.key then return end
    local f = type(iss.fields) == "table" and iss.fields or {}
    out[#out + 1] = { rel = rel, key = iss.key, summary = f.summary or "",
      status = type(f.status) == "table" and f.status.name or "" }
  end
  fields = fields or {}
  add("parent", fields.parent)
  for _, sub in ipairs(type(fields.subtasks) == "table" and fields.subtasks or {}) do add("subtask", sub) end
  for _, l in ipairs(type(fields.issuelinks) == "table" and fields.issuelinks or {}) do
    local t = type(l.type) == "table" and l.type or {}
    if l.outwardIssue then add(t.outward or t.name or "links to", l.outwardIssue)
    else add(t.inward or t.name or "links to", l.inwardIssue) end
  end
  return out
end

function M.valid_key(s)
  local k = (s or ""):gsub("^%s+", ""):gsub("%s+$", ""):upper()
  return k:match("^%u[%u%d_]*%-%d+$") and k or nil
end

-- true when markdown can't carry this doc through an edit (adf -> markdown -> adf) unchanged.
-- whitelist of what md.to_adf rebuilds, so unknown node types count as lossy too.
local SAFE_NODES = { doc = true, paragraph = true, text = true, hardBreak = true, heading = true, bulletList = true,
  orderedList = true, listItem = true, codeBlock = true, blockquote = true, rule = true }
local SAFE_MARKS = { strong = true, em = true, code = true, strike = true, link = true }
function M.adf_lossy(node, in_list)
  if type(node) ~= "table" then return false end
  if not SAFE_NODES[node.type] then return true end
  if node.marks and (#node.marks > 1 or not SAFE_MARKS[node.marks[1].type]) then return true end
  local list = node.type == "bulletList" or node.type == "orderedList"
  if list and in_list then return true end
  if node.type == "listItem" then
    local c = node.content or {}
    if #c > 1 or (c[1] and c[1].type ~= "paragraph") then return true end
  end
  for _, child in ipairs(node.content or {}) do
    if M.adf_lossy(child, in_list or list) then return true end
  end
  return false
end

M.CREATE_TEMPLATE = "\nlabels: \npoints: \npriority: \n---\n"
local CREATE_FIELDS = { labels = true, points = true, priority = true }

-- create template -> { summary, labels, points, priority, description } or nil, err.
-- line 1 = summary; "key: value" lines up to "---" are fields; the rest is the markdown body.
-- without "---" everything after line 1 is the body.
function M.parse_create(text)
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  local out = { summary = trim(lines[1] or "") }
  if out.summary == "" then return nil, "summary (first line) is empty" end
  local sep
  for i = 2, #lines do if lines[i]:match("^%-%-%-%s*$") then sep = i; break end end
  for i = 2, (sep or 1) - 1 do
    if lines[i]:match("%S") then
      local k, v = lines[i]:match("^%s*(%a+):%s*(.-)%s*$")
      k = k and k:lower()
      if not k or not CREATE_FIELDS[k] then return nil, "unknown field line: " .. trim(lines[i]) end
      if v ~= "" then
        if k == "labels" then out.labels = M.split_labels(v)
        elseif k == "points" then
          local perr
          out.points, perr = M.parse_points(v)
          if not out.points then return nil, perr end
        else out.priority = v end
      end
    end
  end
  local body = trim(table.concat(lines, "\n", (sep or 1) + 1))
  out.description = body ~= "" and body or nil
  return out
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
  elseif node.type == "rule" then
    return "---\n\n"
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
      return (joined:gsub("\n+$", "")) .. "\n"
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
      return "> " .. (joined:gsub("\n+$", ""):gsub("\n", "\n> ")) .. "\n\n"
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
