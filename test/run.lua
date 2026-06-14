-- no-framework test harness. run: luajit test/run.lua  (exit 1 on any failure)
package.path = "lua/?.lua;" .. package.path

local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    io.write("  FAIL: " .. tostring(msg) .. "\n")
  end
end
local function eq(a, b, msg)
  ok(a == b, (msg or "") .. " -- expected " .. tostring(b) .. " got " .. tostring(a))
end

local json = require("jira_tui.json")
local model = require("jira_tui.model")
local ansi = require("jira_tui.ansi")
local sprint = require("jira_tui.sprint")

-- ---- json ----
do
  local d = json.decode([[{"a":1,"b":[true,false,null],"c":{"d":"x\n"},"n":-2.5,"e":2e3}]])
  eq(d.a, 1, "json int")
  eq(d.b[1], true, "json true")
  eq(d.b[2], false, "json false")
  eq(d.b[3], nil, "json null -> nil")
  eq(d.c.d, "x\n", "json escaped newline")
  eq(d.n, -2.5, "json negative float")
  eq(d.e, 2000, "json exponent")
  eq(#json.decode("[]"), 0, "json empty array")
  eq(next(json.decode("{}")), nil, "json empty object")
  eq(json.decode([["A"]]), "A", "json unicode escape")
  local rt = json.decode(json.encode({ x = 1, y = "z", arr = { 1, 2, 3 } }))
  eq(rt.y, "z", "json roundtrip string")
  eq(rt.arr[3], 3, "json roundtrip array")
  ok(not pcall(json.decode, "{bad}"), "json rejects garbage")
end

-- ---- normalize_jql ----
do
  eq(sprint.normalize_jql("REF-372"), "key = REF-372", "bare key -> lookup")
  eq(sprint.normalize_jql("ref-5"), "key = REF-5", "bare key uppercased")
  eq(sprint.normalize_jql("project = X"), "project = X", "real jql passthrough")
  eq(sprint.normalize_jql("  ABC-1  "), "key = ABC-1", "trims then matches")
  eq(sprint.normalize_jql(""), "", "empty passthrough")
end

-- ---- ansi width / truncate / pad ----
do
  eq(ansi.width("hello"), 5, "ascii width")
  eq(ansi.width("héllo"), 5, "multibyte counts codepoints")
  eq(ansi.truncate("hello", 10), "hello", "truncate noop when short")
  eq(ansi.width(ansi.truncate("hello world", 5)), 5, "truncate to width incl ellipsis")
  ok(ansi.truncate("hello world", 5):find("…"), "truncate adds ellipsis")
  eq(ansi.width(ansi.pad("hi", 6)), 6, "pad to width")
  eq(ansi.pad("toolong", 3), "toolong", "pad noop when over")
end

-- ---- model tree / flatten / time ----
do
  local issues = {
    { key = "A-1", summary = "root", parent = nil, time_spent = 7200, type = "Story" },
    { key = "A-2", summary = "child", parent = "A-1", type = "Sub-task" },
    { key = "A-3", summary = "orphan parent missing", parent = "A-9", type = "Bug" },
  }
  local roots = model.build_issue_tree(issues)
  eq(#roots, 2, "two roots (A-1 + orphan)")
  eq(roots[1].key, "A-1", "order preserved")
  eq(#roots[1].children, 1, "A-1 one child")
  eq(roots[1].children[1].key, "A-2", "child is A-2")

  roots[1].expanded = false
  eq(#model.flatten(roots), 2, "collapsed hides child")
  roots[1].expanded = true
  eq(#model.flatten(roots), 3, "expanded shows child")
  eq(model.flatten(roots)[2].depth, 2, "child depth 2")

  eq(model.short_date("2026-06-01T12:00:00.000+0000"), "2026-06-01", "short_date strips time")
  eq(model.short_date(nil), "", "short_date nil")
  eq(model.age(nil), "", "age nil")
  ok(model.age("2000-01-01"):find("y"), "age of 2000 is in years")
  eq(model.age(os.date("%Y-%m-%dT00:00:00")), "today", "age of today")

  eq(model.format_time(7200), "2", "2h integer")
  eq(model.format_time(5400), "1.5", "1.5h")
  eq(model.format_time(0), "0", "zero")
  eq(model.format_time(nil), "0", "nil")
end

-- ---- adf -> markdown ----
do
  local function md(content)
    return model.adf_to_markdown({ type = "doc", content = content })
  end
  ok(md({ { type = "paragraph", content = { { type = "text", text = "hi", marks = { { type = "strong" } } } } } })
    :find("**hi**", 1, true), "adf bold")
  ok(md({ { type = "heading", attrs = { level = 2 }, content = { { type = "text", text = "H" } } } })
    :find("## H", 1, true), "adf heading")
  ok(md({ { type = "bulletList", content = { { type = "listItem", content = { { type = "text", text = "x" } } } } } })
    :find("- x", 1, true), "adf bullet")
  ok(md({ { type = "codeBlock", attrs = { language = "lua" }, content = { { type = "text", text = "y" } } } })
    :find("```lua", 1, true), "adf codeblock")
  eq(model.adf_to_markdown(nil), "", "adf nil -> empty")
end

-- ---- my-issues jql builder ----
do
  eq(sprint.my_issues_jql(nil, nil),
    "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC",
    "my issues, no project scope")
  eq(sprint.my_issues_jql({ "SEC", "PE", "ME" }, nil),
    "project in (SEC, PE, ME) AND assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC",
    "my issues scoped to projects")
  ok(sprint.my_issues_jql({ "SEC" }, "auth"):find('summary ~ "auth"', 1, true), "my issues with filter")
end

-- ---- jql history dedup/cap (state) ----
do
  local state = require("jira_tui.state")
  state.save = function() end -- don't touch disk in tests
  state.data.jql_history = {}
  state.add_jql("a")
  state.add_jql("b")
  state.add_jql("a") -- re-add moves to front, no dupe
  eq(state.data.jql_history[1], "a", "re-added jql moves to front")
  eq(#state.data.jql_history, 2, "no duplicate entries")
  for i = 1, 60 do state.add_jql("q" .. i) end
  ok(#state.data.jql_history <= 50, "history capped at 50")
  eq(state.data.jql_history[1], "q60", "newest first")
end

-- ---- curl -K config quoting (regression: data = "@/path", @ inside quotes) ----
do
  local api = require("jira_tui.api")
  local lines = api._config_lines(
    { base = "https://x.atlassian.net", email = "e@x.com", token = "tok" },
    "POST", "/rest/api/3/search/jql", "/tmp/data.json")
  local data_line, url_line
  for _, l in ipairs(lines) do
    if l:sub(1, 4) == "data" then data_line = l end
    if l:sub(1, 3) == "url" then url_line = l end
  end
  eq(data_line, 'data = "@/tmp/data.json"', "data line wraps @path inside quotes")
  eq(url_line, 'url = "https://x.atlassian.net/rest/api/3/search/jql"', "url line quoted")
  -- no data file -> no data line
  local nolines = api._config_lines({ base = "b", email = "e", token = "t" }, "GET", "/x", nil)
  for _, l in ipairs(nolines) do ok(l:sub(1, 4) ~= "data", "GET has no data line") end
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
