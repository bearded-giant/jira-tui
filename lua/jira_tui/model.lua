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
    for _, node in ipairs(nodes) do
      if with_spacers and depth == 1 and #out > 0 then
        out[#out + 1] = { spacer = true }
      end
      out[#out + 1] = { node = node, depth = depth }
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

local function decode_entities(str)
  return (str:gsub("&%w+;", html_entities):gsub("&#(%d+);", function(n)
    return string.char(tonumber(n) or 0)
  end))
end

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
        if mark.type == "link" then text = string.format("[%s](%s)", text, mark.attrs.href) end
      end
    end
    return text
  elseif node.type == "hardBreak" then
    return "\n"
  elseif node.content then
    local parts = {}
    for _, child in ipairs(node.content) do parts[#parts + 1] = parse_adf(child) end
    local joined = table.concat(parts, "")
    if node.type == "paragraph" then
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
