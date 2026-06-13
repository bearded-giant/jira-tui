-- smallest check that fails if the core logic breaks. run: luajit test/run.lua
package.path = "lua/?.lua;" .. package.path

local json = require("jira_tui.json")
local model = require("jira_tui.model")

local function eq(a, b, msg) assert(a == b, (msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a)) end

-- json round-trip + nested + null->nil
local doc = json.decode([[{"a":1,"b":[true,false,null],"c":{"d":"x\n"},"n":-2.5}]])
eq(doc.a, 1, "num")
eq(doc.b[1], true, "bool")
eq(doc.b[3], nil, "null->nil")
eq(doc.c.d, "x\n", "escaped string")
eq(doc.n, -2.5, "neg float")
eq(json.decode(json.encode({ x = 1, y = "z" })).y, "z", "encode/decode roundtrip")

-- tree build: child attaches under parent, orphan becomes root
local issues = {
  { key = "A-1", summary = "root", parent = nil, time_spent = 7200, type = "Story" },
  { key = "A-2", summary = "child", parent = "A-1", type = "Sub-task" },
  { key = "A-3", summary = "orphan", parent = "A-9", type = "Bug" },
}
local roots = model.build_issue_tree(issues)
eq(#roots, 2, "two roots (A-1, orphan A-3)")
eq(roots[1].key, "A-1", "first root order preserved")
eq(#roots[1].children, 1, "A-1 has one child")
eq(roots[1].children[1].key, "A-2", "child is A-2")

-- flatten respects expanded
roots[1].expanded = false
eq(#model.flatten(roots), 2, "collapsed: only roots visible")
roots[1].expanded = true
eq(#model.flatten(roots), 3, "expanded: child visible")

-- time format
eq(model.format_time(7200), "2", "2h integer")
eq(model.format_time(5400), "1.5", "1.5h")
eq(model.format_time(0), "0", "zero")
eq(model.format_time(nil), "0", "nil")

-- adf -> markdown
local adf = {
  type = "doc",
  content = {
    { type = "paragraph", content = { { type = "text", text = "hi", marks = { { type = "strong" } } } } },
  },
}
assert(model.adf_to_markdown(adf):find("**hi**", 1, true), "adf bold")

print("ok: all checks passed")
