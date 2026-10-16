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

  -- fallbacks for node types that used to vanish silently
  ok(md({ { type = "paragraph", content = { { type = "mention", attrs = { text = "@ann" } } } } })
    :find("@ann", 1, true), "adf mention emits attrs.text")
  ok(md({ { type = "paragraph", content = { { type = "inlineCard", attrs = { url = "http://x" } } } } })
    :find("http://x", 1, true), "adf inlineCard emits url")
  ok(md({ { type = "paragraph", content = { { type = "emoji", attrs = { shortName = ":+1:" } } } } })
    :find(":+1:", 1, true), "adf emoji emits shortName")
  eq(md({ { type = "paragraph", content = { { type = "mention" } } } }), "\n\n", "attr-less mention no throw")
  local trow = md({ { type = "table", content = { { type = "tableRow", content = {
    { type = "tableCell", content = { { type = "paragraph", content = { { type = "text", text = "a" } } } } },
    { type = "tableCell", content = { { type = "paragraph", content = { { type = "text", text = "b" } } } } },
  } } } } })
  ok(trow:find("a | b", 1, true), "adf table cells joined with |")

  -- regression: string.char(8217) threw and killed the whole tui on a smart apostrophe
  eq(model.decode_entities("it&#8217;s"), "it\226\128\153s", "numeric entity >= 256 utf-8 encoded")
  eq(model.decode_entities("&#x2019;"), "\226\128\153", "hex entity utf-8 encoded")
  eq(model.decode_entities("a &amp; b &#65;"), "a & b A", "named + ascii numeric entities")
  eq(model.decode_entities("&#1114112;"), "", "out-of-range codepoint dropped, no throw")
  eq(model.utf8_char(0x20AC), "\226\130\172", "3-byte euro")
  eq(model.utf8_char(0x1F600), "\240\159\152\128", "4-byte emoji")
  local link_no_attrs = md({ { type = "paragraph", content = {
    { type = "text", text = "x", marks = { { type = "link" } } } } } })
  ok(link_no_attrs:find("x", 1, true), "link mark with nil attrs renders text, no throw")
  local link_ok = md({ { type = "paragraph", content = {
    { type = "text", text = "x", marks = { { type = "link", attrs = { href = "http://h" } } } } } } })
  ok(link_ok:find("[x](http://h)", 1, true), "link mark with href renders markdown link")
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

  -- one quote/escape path for every interpolated string (regression: embedded quote -> invalid jql, cryptic 400)
  eq(sprint.jql_quote('a"b\\c'), '"a\\"b\\\\c"', "jql_quote escapes quote and backslash")
  ok(sprint.my_issues_jql({ "SEC" }, 'x"y'):find('summary ~ "x\\"y"', 1, true), "my issues filter escaped")
  eq(sprint.sprint_jql("REF", nil), "project = REF AND sprint in openSprints() ORDER BY Rank ASC", "sprint jql")
  ok(sprint.sprint_jql("REF", 'a"b'):find('AND summary ~ "a\\"b" ORDER BY', 1, true), "sprint filter escaped, before ORDER BY")
  ok(sprint.backlog_jql("REF", "z"):find('statusCategory != Done AND summary ~ "z" ORDER BY Rank ASC', 1, true), "backlog filter escaped")

  ok(sprint.valid_project("SEC"), "valid project SEC")
  ok(sprint.valid_project("A_B2"), "valid project with underscore/digit")
  ok(not sprint.valid_project("sec"), "lowercase rejected")
  ok(not sprint.valid_project("REF "), "trailing space rejected")
  ok(not sprint.valid_project("1AB"), "leading digit rejected")
  ok(not sprint.valid_project("S"), "single char rejected")
  local _, perr = sprint.get_active_sprint_issues("REF ", nil)
  eq(perr, "invalid project key: REF ", "sprint loader rejects bad key before hitting jira")
  _, perr = sprint.get_my_issues({ "SEC", "bad" }, nil)
  eq(perr, "invalid project key: bad", "my issues rejects bad configured key")

  -- JQL views honor the / filter: wrap the body, keep ORDER BY last (footer used to lie)
  eq(sprint.with_filter("project = X ORDER BY Rank ASC", "auth"),
    '(project = X) AND summary ~ "auth" ORDER BY Rank ASC', "with_filter keeps ORDER BY last")
  eq(sprint.with_filter("project = X", 'a"b'), '(project = X) AND summary ~ "a\\"b"', "with_filter no order, escaped")
  eq(sprint.with_filter("project = X\n  order by created", "z"),
    '(project = X) AND summary ~ "z" order by created', "with_filter multiline + lowercase order by")
  eq(sprint.with_filter("project = X", nil), "project = X", "with_filter nil passthrough")
  eq(sprint.with_filter("project = X", ""), "project = X", "with_filter empty passthrough")
end

-- ---- launch contract (README: no args -> My Issues, PROJECT -> its open issues) ----
do
  local init = require("jira_tui.init")
  local l = init.resolve_launch({}, nil)
  eq(l.view, "My Issues", "no args -> My Issues"); eq(l.project, nil, "no args, no project")
  l = init.resolve_launch({}, "SEC")
  eq(l.view, "My Issues", "no args ignores last_view; still My Issues"); eq(l.project, "SEC", "last project seeds S/B")
  l = init.resolve_launch({ "ref" }, "SEC")
  eq(l.view, "Project", "project arg opens the Project view, not a sprint"); eq(l.project, "REF", "project arg uppercased, beats last")
  l = init.resolve_launch({ "REF", "--sprint" }, nil)
  eq(l.view, "Active Sprint", "--sprint opens every open sprint")
  l = init.resolve_launch({ "REF", "--backlog" }, nil)
  eq(l.view, "Backlog", "--backlog flag wins")
  l = init.resolve_launch({ "--my" }, "SEC")
  eq(l.view, "My Issues", "--my flag")
  l = init.resolve_launch({ "--jql", "status = X" }, nil)
  eq(l.view, "JQL:status = X", "--jql flag carries query")
  ok(init.resolve_launch({ "-h" }, nil).help, "-h -> help")
  ok(init.resolve_launch({ "REF", "--help" }, nil).help, "--help anywhere -> help")
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
  local joined = table.concat(lines, "\n")
  ok(joined:find("connect%-timeout = %d+"), "curl has connect-timeout (hung connect can't freeze raw-mode tui)")
  ok(joined:find("max%-time = %d+"), "curl has max-time")
  ok(joined:find('write%-out = "__http=%%{http_code}"'), "curl reports http status (204 vs auth/404)")
  -- no data file -> no data line
  local nolines = api._config_lines({ base = "b", email = "e", token = "t" }, "GET", "/x", nil)
  for _, l in ipairs(nolines) do ok(l:sub(1, 4) ~= "data", "GET has no data line") end
end

-- ---- render smoke (guards the layout) ----
do
  local render = require("jira_tui.render")
  local function plain(s) return (s:gsub("\27%[[%d;]*m", "")) end

  local hdr = plain(render.column_header(120))
  ok(hdr:find("Created") and hdr:find("Age") and hdr:find("Status"), "column header has Created/Age/Status")

  local bar = plain(render.tab_bar("My Issues", render.tabs(nil, { ["Active Sprint"] = true, ["Backlog"] = true }), 100))
  ok(bar:find("My Issues") and bar:find("JQL") and bar:find("Help"), "tab bar has visible tabs")
  ok(not bar:find("Sprint") and not bar:find("Backlog"), "hidden tabs dropped (old 'Active Sprint' name hides Sprint)")
  ok(bar:find("JQL.*%s%s%s+.*Help"), "Help pushed right of JQL")

  local root = plain(render.issue_line({ key = "A-1", summary = "s", type = "Bug", status = "Backlog" }, 1, 120, false, true))
  ok(root:find("A%-1"), "issue row has key")
  local child = plain(render.issue_line({ key = "A-2", summary = "c", type = "Bug", status = "Done" }, 2, 120, false, true))
  ok(child:find("└─"), "last child uses └─ connector")

  -- regression: stripped/empty type glyphs shifted whole rows left of the header
  local function key_col(line, key)
    local i = line:find(key, 1, true)
    return ansi.width(line:sub(1, i - 1))
  end
  local glyphed = plain(render.issue_line({ key = "B-1", summary = "s", type = "Story", status = "Backlog" }, 1, 120, false, true))
  local fallback = plain(render.issue_line({ key = "B-2", summary = "s", type = "Vulnerability", status = "Backlog" }, 1, 120, false, true))
  eq(key_col(glyphed, "B-1"), key_col(fallback, "B-2"), "key column aligned across icon variants")

  -- detail sections: attachments listed, comment bodies hideable
  local dissue = { key = "A-1", fields = { summary = "s",
    attachment = { { filename = "shot.png", size = 2048, mimeType = "image/png" } } } }
  local dcms = { { author = { displayName = "Dev" }, created = "2026-01-01T00:00:00.000+0000", body = "hello body" } }
  local dfull = plain(render.detail_text(dissue, {}, "fields", dcms, { rule_w = 40 }))
  ok(dfull:find("Attachments %(1%)") and dfull:find("shot%.png", 1, false), "attachments section listed")
  ok(dfull:find("hello body", 1, true), "comment body shown when expanded")
  local dcoll = plain(render.detail_text(dissue, {}, "fields", dcms, { rule_w = 40, comments_collapsed = true }))
  ok(dcoll:find("Comments %(1%)") and not dcoll:find("hello body", 1, true), "collapsed comments hide bodies")

  -- regression: at 80 cols rows rendered 91 cells into a 76-cell interior and wrapped
  local node = { key = "PROJ-12345", summary = string.rep("long title ", 20), assignee = "Somebody Longname",
    created = "2026-01-01T00:00:00.000+0000", type = "Story", status = "In Progress" }
  for iw = 70, 200, 5 do
    ok(ansi.width(render.issue_line(node, 1, iw, true, true)) <= iw, "issue row fits interior at iw=" .. iw)
    ok(ansi.width(render.issue_line(node, 2, iw, false, false)) <= iw, "child row fits interior at iw=" .. iw)
    ok(ansi.width(render.column_header(iw, "key", "asc")) <= iw, "column header fits at iw=" .. iw)
    ok(ansi.width(render.hint_line("My Issues", nil, iw)) <= iw, "hint line fits at iw=" .. iw)
  end
  -- gs sort menu = render.COLUMNS: every entry must be a rendered column (no dead time/points)
  local fields = {}
  for _, c in ipairs(render.COLUMNS) do fields[#fields + 1] = c.f end
  eq(table.concat(fields, ","), "key,summary,assignee,created,age,status", "COLUMNS = rendered sortable fields")
  for _, c in ipairs(render.COLUMNS) do
    ok(c.f == "summary" or render.COL[c.f], "column has a width: " .. c.f)
    ok(c.l and #c.l > 0, "column has a label: " .. c.f)
  end

  -- view routing: JQL views carry the query in st.view; the tab bar must match on the label
  eq(render.view_label("JQL:project = X ORDER BY x"), "JQL", "view_label strips jql query")
  eq(render.view_label("My Issues"), "My Issues", "view_label passthrough")
  eq(render.jql_query(render.jql_view("key = X-1")), "key = X-1", "jql_view/jql_query roundtrip")
  eq(render.jql_query("Backlog"), nil, "jql_query nil for plain views")
  ok(ansi.width(render.box_top(40, "T")) == 40, "box_top exact width with title")
  ok(ansi.width(render.box_top(40)) == 40, "box_top exact width without title")
  ok(ansi.width(render.box_top(20, string.rep("long title ", 5))) == 20, "box_top truncates long title")
  local active_jql = "48;2;" .. ansi.color.yellow .. ";1m JQL (J) "
  ok(render.tab_bar(render.view_label("JQL:project = X"), render.tabs(), 100):find(active_jql, 1, true), "JQL tab highlighted for a JQL:<q> view")
  ok(not render.tab_bar(render.view_label("My Issues"), render.tabs(), 100):find(active_jql, 1, true), "JQL tab plain on My Issues")

  ok(not plain(render.column_header(76)):find("Created"), "Created dropped at 76 (80-col terminal)")
  ok(plain(render.column_header(100)):find("Created"), "Created shown at 100")
  ok(plain(render.hint_line("x", nil, 60)):find("Esc quit", 1, true), "narrow hint keeps Esc quit")
end

-- ---- status badge colors ----
do
  local render = require("jira_tui.render")
  eq(render.status_bg("To Do"), ansi.color.blue, "jira 'To Do' (with space) gets the todo color")
  eq(render.status_bg("TODO"), ansi.color.blue, "TODO")
  eq(render.status_bg("In Progress"), ansi.color.yellow, "In Progress")
  eq(render.status_bg("Ready for QA"), ansi.color.surface2, "Ready for wins over QA")
  eq(render.status_bg("Done"), ansi.color.green, "Done")
  eq(render.status_bg(nil), ansi.color.surface2, "nil -> default")
  local _, soft_fg = render.status_bg("Groomed")
  eq(soft_fg, ansi.color.text, "unmatched status gets readable fg")
  local _, done_fg = render.status_bg("Done")
  eq(done_fg, ansi.color.base, "colored status keeps dark fg")
end

-- ---- crud helpers ----
do
  local api = require("jira_tui.api")
  local model = require("jira_tui.model")
  local json = require("jira_tui.json")

  local adf = require("jira_tui.md").to_adf("line one\n\nline two")
  eq(#adf.content, 2, "blank line separates paragraphs")

  local appended = api.append_to_adf(adf, "line three")
  eq(#appended.content, 3, "append adds a paragraph")
  eq(appended.content[3].content[1].text, "line three", "appended text")
  local fresh = api.append_to_adf(nil, "solo")
  eq(fresh.content[1].content[1].text, "solo", "append to nil starts a new doc")

  local trs = {
    { id = "1", name = "Start", to = { name = "In Progress" } },
    { id = "2", name = "Close it", to = { name = "Closed" } },
    { id = "3", name = "Finish", to = { name = "Done" } },
  }
  eq(model.pick_done_transition(trs).id, "3", "Done preferred over Closed")
  eq(model.pick_done_transition({ trs[1], trs[2] }).id, "2", "Closed when no Done")
  eq(model.pick_done_transition({ trs[1] }), nil, "nil when nothing done-ish")
  eq(model.pick_done_transition(nil), nil, "nil transitions tolerated")

  eq(table.concat(model.split_labels(" a,,b  c "), "|"), "a|b|c", "split_labels")
end

-- ---- fetch_all truncation flag ----
do
  local api = require("jira_tui.api")
  local config = require("jira_tui.config")
  local orig_si, orig_limit = api.search_issues, config.options.jira.limit
  config.options.jira.limit = 2
  api.search_issues = function()
    return { issues = { { key = "T-1", fields = {} }, { key = "T-2", fields = {} } }, nextPageToken = "more" }
  end
  local all, _, trunc = sprint.get_my_issues(nil, nil)
  eq(#all, 2, "limit caps results")
  eq(trunc, true, "truncated flag set when more pages exist")
  api.search_issues = function() return { issues = { { key = "T-1", fields = {} } } } end
  local _, _, trunc2 = sprint.get_my_issues(nil, nil)
  eq(trunc2, nil, "no truncation flag when last page fetched")
  api.search_issues, config.options.jira.limit = orig_si, orig_limit
end

-- ---- ui.input trims single-line input (project key "REF " broke jql) ----
do
  local term = require("jira_tui.term")
  local ui = require("jira_tui.ui")
  local o_out, o_move, o_size, o_read = term.out, term.moveto, term.size, term.read
  term.out = function() end
  term.moveto = function() end
  term.size = function() return 24, 80 end
  local function feed(s)
    local i = 0
    term.read = function(cnt)
      cnt = cnt or 1
      if i >= #s then return nil end
      local r = s:sub(i + 1, i + cnt); i = i + cnt; return r
    end
  end
  feed(" REF \13")
  eq(ui.input("Project key", {}), "REF", "single-line input trimmed")
  feed("a\27")
  eq(ui.input("Project key", {}), nil, "esc cancels")  -- \27 then exhaustion -> esc
  feed("h\195\169\127\13") -- h, é, backspace, enter
  eq(ui.input("x", {}), "h", "backspace drops whole utf-8 codepoint")

  -- cursor editing (regression: arrows ignored, buffer was append-only)
  feed("ac\27[Db\13")
  eq(ui.input("x", {}), "abc", "left then insert mid-string")
  feed("\27[Dz\13")
  eq(ui.input("x", { value = "abc" }), "abzc", "prefilled value: cursor starts at end")
  feed("abc\27[H\27[3~\27[F!\13")
  eq(ui.input("x", {}), "bc!", "home, delete, end")
  feed("\195\169x\27[D\27[D\127\13")
  eq(ui.input("x", {}), "\195\169x", "left steps a whole utf-8 codepoint, bs at 0 is a no-op")
  feed("ab\13cd\27[A\27[Dx\19")
  eq(ui.input("x", { multiline = true }), "axb\ncd", "up keeps column, left, insert")
  feed("\27[A\27[A\27[B\27[B\27[Hy\19")
  eq(ui.input("x", { multiline = true, value = "abc\nd\nefg" }), "abc\nd\nyefg", "up/down clamp to line length, home is line start")
  -- width 20 -> 15-col rows: "aaaa bbbb cccc " / "dddd eeee" (breaks after the space)
  feed("\27[AX\19")
  eq(ui.input("x", { multiline = true, width = 20, value = "aaaa bbbb cccc dddd eeee" }), "aaaa bbbbX cccc dddd eeee",
    "up moves by wrapped row inside one long line, keeping column")
  feed("\27[A\27[A\27[HZ\19")
  eq(ui.input("x", { multiline = true, width = 20, value = "aaaa bbbb cccc dddd eeee" }), "Zaaaa bbbb cccc dddd eeee",
    "up on top row is a no-op, home goes to line start")
  local long = string.rep("project = REF AND ", 20)
  local drawn = {}
  term.out = function(s) drawn[#drawn + 1] = s end
  feed("\19")
  eq(ui.input("x", { multiline = true, value = long, width = 40, height = 8 }), (long:gsub("%s+$", "")), "long query survives")
  local cursor_seen = false
  for _, s in ipairs(drawn) do
    ok(ansi.width(ansi.strip(s)) <= 40, "editor row fits box")
    if s:find(ansi.sgr(" ", ansi.REVERSE), 1, true) then cursor_seen = true end
  end
  ok(cursor_seen, "editor scrolls so the end-of-buffer cursor is drawn")
  term.out = function() end

  feed("je")
  local it, idx, act = ui.select("t", { "a", "b" }, { keys = { e = "edit" } })
  eq(it, "b", "select action key returns item"); eq(idx, 2, "select action index"); eq(act, "edit", "select action name")
  feed("\13")
  it, idx, act = ui.select("t", { "a" }, { keys = { e = "edit" } })
  eq(act, nil, "Enter returns no action")
  term.out, term.moveto, term.size, term.read = o_out, o_move, o_size, o_read
end

-- ---- term.read_key (string-backed reader) ----
do
  local term = require("jira_tui.term")
  local function feed(s)
    local i = 0
    term.read = function(n)
      n = n or 1
      if i >= #s then return nil end
      local out = s:sub(i + 1, i + n); i = i + n; return out
    end
  end
  local function keys(s)
    feed(s)
    local out = {}
    for _ = 1, 8 do local k = term.read_key(); if k == nil then break end; out[#out + 1] = k end
    return table.concat(out, ",")
  end
  eq(keys("a"), "a", "printable passthrough")
  eq(keys("\27"), "esc", "bare esc (timeout -> nil after ESC)")
  eq(keys("\27[A"), "up", "csi arrow")
  eq(keys("\27[Z"), "btab", "shift-tab")
  eq(keys("\27OA"), "up", "ss3 arrow (app mode)")
  eq(keys("\27[1;5A"), "up", "ctrl-arrow modifiers ignored")
  eq(keys("\27[<64;10;5M"), "wheelup", "sgr wheel up")
  eq(keys("\27[<65;10;5m"), "wheeldown", "sgr wheel down")
  eq(keys("\27[5~"), "pgup", "pgup")
  eq(keys("\27[6~"), "pgdn", "pgdn")
  eq(keys("\3"), "ctrl-c", "ctrl-c has its own token, not 'q'")
  eq(keys("\4"), "ctrl-d", "ctrl-d")
  eq(keys("\21"), "ctrl-u", "ctrl-u")
  -- swallowed sequences: read_key returns nil once but the stream is fully consumed,
  -- so the key after them still comes through cleanly (regression: F1 quit the app, F5 leaked "15~")
  local function after(s) feed(s); local first = term.read_key(); return first, term.read_key() end
  local f, n = after("\27OPa"); eq(f, nil, "F1 (ss3) swallowed"); eq(n, "a", "byte after F1 intact")
  f, n = after("\27[15~a"); eq(f, nil, "F5 (csi ~) swallowed"); eq(n, "a", "byte after F5 intact")
  f, n = after("\27[<0;10;5Ma"); eq(f, "click", "left press -> click"); eq(n, "a", "byte after click intact")
  eq(term.mouse and term.mouse.row, 5, "click row"); eq(term.mouse and term.mouse.col, 10, "click col")
  f, n = after("\27[<0;10;5ma"); eq(f, nil, "left release swallowed"); eq(n, "a", "byte after release intact")
  f, n = after("\27[<2;10;5Ma"); eq(f, nil, "right press swallowed"); eq(n, "a", "byte after right press intact")
  f, n = after("\27[<32;10;5Ma"); eq(f, nil, "drag swallowed"); eq(n, "a", "byte after drag intact")
  f, n = after("\27xa"); eq(f, nil, "alt+x swallowed"); eq(n, "a", "byte after alt+x intact")
  f, n = after("\27[Mabca"); eq(f, nil, "x10 mouse swallowed"); eq(n, "a", "x10 3 trailing bytes eaten")
  eq(keys("\27[A\27[B"), "up,down", "two sequences back to back")
  term.read = function(count) return io.read(count) end
end

-- ---- ansi.wrap + render.detail_text ----
do
  local render = require("jira_tui.render")
  local function plain(s) return (s:gsub("\27%[[%d;]*m", "")) end
  eq(#ansi.wrap("short", 20), 1, "wrap passthrough")
  local w = ansi.wrap("the quick brown fox jumps over the lazy dog", 10)
  ok(#w > 1, "wrap splits long line")
  for _, l in ipairs(w) do ok(ansi.width(l) <= 10, "wrapped line fits: " .. l) end
  eq(table.concat(w, " "), "the quick brown fox jumps over the lazy dog", "wrap loses no words")
  local hard = ansi.wrap("https://example.com/a/very/long/path/that/never/breaks", 12)
  for _, l in ipairs(hard) do ok(ansi.width(l) <= 12, "overlong word hard-split fits") end
  eq(table.concat(hard, ""), "https://example.com/a/very/long/path/that/never/breaks", "hard split loses no chars")
  eq(#ansi.wrap("", 10), 1, "empty line stays one blank line")

  -- sgr-aware: styled overlong token splits at display cells, not bytes
  local styled_url = ansi.fgtext("https://example.com/very/long/styled/path/segment", ansi.color.sky, ansi.UNDERLINE)
  local sw2 = ansi.wrap("see " .. styled_url .. " end", 14)
  for _, l in ipairs(sw2) do ok(ansi.width(l) <= 14, "styled wrap line fits: " .. ansi.strip(l)) end
  eq(ansi.strip(table.concat(sw2, "")):gsub(" ", ""), "seehttps://example.com/very/long/styled/path/segmentend",
    "styled wrap loses no visible chars")

  local issue = { key = "X-1", fields = {
    summary = "Sum", status = { name = "In Progress" }, issuetype = { name = "Story" },
    priority = { name = "High" }, assignee = { displayName = "Ann" }, created = "2026-01-01T00:00:00.000+0000",
    customfield_10035 = 5, project = { key = "X" },
    description = { type = "doc", content = { { type = "paragraph", content = { { type = "text", text = "body text" } } } } },
    customfield_10016 = { type = "doc", content = { { type = "paragraph", content = { { type = "text", text = "must pass" } } } } },
  } }
  local pc = { story_point_field = "customfield_10035", acceptance_criteria_field = "customfield_10016" }
  local fielded = plain(render.detail_text(issue, pc, "fields"))
  ok(fielded:find("Status    In Progress", 1, true), "fielded: status row")
  ok(fielded:find("Assignee  Ann", 1, true), "fielded: assignee row")
  ok(fielded:find("Points    5", 1, true), "fielded: points row")
  ok(fielded:find("Priority  High", 1, true), "fielded: priority row")
  ok(fielded:find("Description", 1, true) and fielded:find("body text", 1, true), "fielded: description section")
  ok(fielded:find("Acceptance Criteria", 1, true) and fielded:find("must pass", 1, true), "fielded: AC section")
  local md = render.detail_text(issue, pc, "markdown")
  ok(md:sub(1, 9) == "# X-1 Sum", "markdown: title heading")
  ok(md:find("## Acceptance Criteria", 1, true), "markdown: AC heading")
  ok(not md:find("Status", 1, true), "markdown: no fielded header")
  local bare = plain(render.detail_text({ key = "X-2", fields = {} }, pc, "fields"))
  ok(bare:find("(no description)", 1, true), "empty issue: no description placeholder")
  ok(not bare:find("Acceptance", 1, true), "empty issue: no AC section")
end

-- ---- board filter + branch names ----
do
  ok(model.matches({ summary = "Add Cloud Armor", key = "SEC-1" }, "cloud"), "filter matches summary, case-insensitive")
  ok(model.matches({ summary = "x", key = "SEC-4046" }, "4046"), "filter matches key")
  ok(model.matches({ summary = "x", key = "K-1" }, nil), "nil filter matches all")
  ok(model.matches({ summary = "x", key = "K-1" }, ""), "empty filter matches all")
  ok(not model.matches({ summary = "abc", key = "K-1" }, "zzz"), "filter miss")
  ok(model.matches({ key = "K-1" }, "k-1"), "nil summary safe")
  local iss = { key = "PE-9", summary = "Fix cache stampede", assignee = "Ann Lee", status = "In Progress",
    type = "Bug", priority = "High", labels = { "perf", "backend" } }
  ok(model.matches(iss, "@ann"), "filter @assignee")
  ok(not model.matches(iss, "@bob"), "filter @assignee miss")
  ok(model.matches(iss, "s:prog"), "filter s:status")
  ok(model.matches(iss, "t:BUG"), "filter t:type case-insensitive")
  ok(model.matches(iss, "p:hi"), "filter p:priority")
  ok(model.matches(iss, "l:back"), "filter l:label any")
  ok(not model.matches(iss, "l:front"), "filter l:label miss")
  ok(model.matches(iss, "@ann s:prog cache"), "filter tokens AND-ed")
  ok(not model.matches(iss, "@ann s:done cache"), "filter one token miss fails all")
  ok(model.matches(iss, "cache fix"), "filter bare words any order")
  ok(model.matches(iss, "pe-9 stampede"), "filter key + word")
  ok(model.matches({ key = "X-1", summary = "see a:b" }, "a:b"), "filter unknown prefix = plain word")
  ok(not model.matches({ key = "X-1", summary = "s" }, "l:x"), "filter l: without labels")
  ok(not model.matches({ key = "X-1" }, "@x"), "filter @ without assignee")
  local mine = { key = "X-2", summary = "s", assignee = "Ann Lee", assignee_account_id = "acc-1" }
  ok(model.matches(mine, "@me", "acc-1"), "filter @me matches the current user's id")
  ok(not model.matches(mine, "@me", "acc-2"), "filter @me misses another user")
  ok(not model.matches({ key = "X-3", assignee = "Unassigned" }, "@me", "acc-1"), "filter @me skips unassigned")
  ok(model.matches({ key = "X-4", assignee = "Mel" }, "@me"), "filter @me without a resolved user falls back to name")

  eq(model.branch_name("PE-1472", "Add rate limit"), "pe-1472-add-rate-limit", "branch name basic")
  eq(model.branch_name("REF-9", "Fix: weird (chars) & stuff!!"), "ref-9-fix-weird-chars-stuff", "branch name strips punctuation")
  local long = model.branch_name("SEC-3577", "Upgrade pyjwt in customcheckout to >= 2.12.0 and more words here")
  ok(#long <= 50, "branch name capped at 50")
  ok(not long:match("%-$"), "branch name no trailing dash")
  eq(model.branch_name("X-1", ""), "x-1", "branch name empty summary is just the key")
end

-- ---- detail comments section ----
do
  local render = require("jira_tui.render")
  local function plain(s) return (s:gsub("\27%[[%d;?]*m", "")) end
  local issue = { key = "X-1", fields = { summary = "S" } }
  local pc = { story_point_field = "sp", acceptance_criteria_field = "ac" }
  local comments = {
    { author = { displayName = "Ann" }, created = "2026-08-31T10:00:00.000-0400",
      body = { type = "doc", content = { { type = "paragraph", content = { { type = "text", text = "looks good" } } } } } },
    { author = { displayName = "Bob" }, created = "2026-07-01T10:00:00.000-0400", body = "plain string body" },
  }
  local out = plain(render.detail_text(issue, pc, "fields", comments))
  ok(out:find("Comments (2)", 1, true), "comments section header with count")
  ok(out:find("Ann · 2026%-08%-31"), "comment author + date")
  ok(out:find("looks good", 1, true), "adf comment body rendered")
  ok(out:find("Bob", 1, true) and out:find("plain string body", 1, true), "string comment body passes through")
  ok(not plain(render.detail_text(issue, pc, "fields", nil)):find("Comments", 1, true), "no comments -> no section")
  ok(not plain(render.detail_text(issue, pc, "fields", {})):find("Comments", 1, true), "empty comments -> no section")
end

-- ---- markdown -> ansi (detail popup rendering) ----
do
  local mdr = require("jira_tui.md")
  local function plain(s) return (s:gsub("\27%[[%d;?]*m", "")) end

  eq(plain(mdr.to_ansi("## Context")), "Context", "heading hashes stripped")
  eq(plain(mdr.to_ansi("# Top")), "Top", "h1 hashes stripped")
  eq(plain(mdr.to_ansi("[https://x.com/a](https://x.com/a)")), "https://x.com/a", "text==url link deduped")
  eq(plain(mdr.to_ansi("see [docs](https://x.com)")), "see docs (https://x.com)", "text!=url keeps both")
  eq(plain(mdr.to_ansi("run `make check` now")), "run make check now", "inline code markers stripped")
  eq(plain(mdr.to_ansi("**bold** rest")), "bold rest", "bold markers stripped")
  ok(mdr.to_ansi("**b**"):find(";1m"), "bold styled")
  eq(plain(mdr.to_ansi("- item one")), "• item one", "bullet glyph")
  eq(plain(mdr.to_ansi("rate_limit_x and _snake_case_ safe")), "rate_limit_x and _snake_case_ safe",
    "underscores untouched (no italic mangling)")
  ok(plain(mdr.to_ansi("---")):find("──────", 1, true), "hr becomes rule")

  local fenced = plain(mdr.to_ansi("```lua\nlocal x = 1\n```"))
  ok(fenced:find("── lua "), "fence open shows language")
  ok(fenced:find("  local x = 1", 1, true), "fence content indented, no backticks")
  ok(not fenced:find("```", 1, true), "fence markers gone")

  local q = plain(mdr.to_ansi("> quoted one\n> quoted two"))
  ok(q:find("│ quoted one", 1, true) and q:find("│ quoted two", 1, true), "quote lines get a bar each")
  eq(plain(mdr.to_ansi("> a > b")), "│ a > b", "literal > inside a quote stays")

  -- fields detail runs the description through md
  local render = require("jira_tui.render")
  local issue = { key = "X-1", fields = { summary = "S",
    description = { type = "doc", content = { { type = "heading", attrs = { level = 2 },
      content = { { type = "text", text = "Ctx" } } } } } } }
  local pc = { story_point_field = "sp", acceptance_criteria_field = "ac" }
  ok(not plain(render.detail_text(issue, pc, "fields")):find("## Ctx", 1, true), "fields mode renders markdown")
  ok(render.detail_text(issue, pc, "markdown"):find("## Ctx", 1, true), "markdown mode stays raw")
end

-- ---- ansi.cut / fitline (sgr-aware truncation) ----
do
  local styled = ansi.fgtext("hello", ansi.color.red) .. ansi.bgtext(" world", ansi.color.base, ansi.color.blue)
  eq(ansi.width(ansi.cut(styled, 7)), 7, "cut to 7 cells")
  eq(ansi.cut(styled, 50), styled, "cut noop when it fits")
  ok(ansi.cut(styled, 7):sub(-4) == ansi.RESET, "cut closes open style with reset")
  eq(ansi.width(ansi.fitline(styled, 30)), 30, "fitline pads short")
  eq(ansi.width(ansi.fitline(styled, 4)), 4, "fitline cuts long")
  eq(ansi.width(ansi.cut("héllo wörld", 6)), 6, "cut counts multibyte as one cell")
end

-- ---- headless tui harness ----
-- stub(mod, { name = fn }) swaps module functions and logs every call as { name, args... }.
-- returns log, restore.
local function stub(mod, fns)
  local log, saved = {}, {}
  for name, fn in pairs(fns) do
    saved[name] = mod[name]
    mod[name] = function(...)
      log[#log + 1] = { name, ... }
      return fn(...)
    end
  end
  return log, function() for name, fn in pairs(saved) do mod[name] = fn end end
end

local function calls(log, name)
  local out = {}
  for _, c in ipairs(log) do if c[1] == name then out[#out + 1] = c end end
  return out
end

-- key names pass through as tokens; any other string is typed one char at a time
local KEY_NAMES = {}
for k in ("enter esc tab btab bs del ctrl-s ctrl-c ctrl-d ctrl-u up down left right home end pgup pgdn wheelup wheeldown")
  :gmatch("%S+") do KEY_NAMES[k] = true end
local function keyseq(...)
  local out = {}
  for _, k in ipairs({ ... }) do
    if KEY_NAMES[k] or #k == 1 then out[#out + 1] = k
    else for ch in k:gmatch(".") do out[#out + 1] = ch end end
  end
  return out
end

local TUI_FIXTURE = {
  { key = "PE-1", summary = "alpha root", status = "To Do", type = "Story", assignee = "Ann", priority = "High",
    created = "2026-10-01T10:00:00.000+0000", status_category = "To Do" },
  { key = "PE-2", summary = "beta parent", status = "In Progress", type = "Story", assignee = "Unassigned",
    priority = "Medium", created = "2026-10-02T10:00:00.000+0000", status_category = "In Progress" },
  { key = "PE-3", summary = "gamma child", status = "To Do", type = "Sub-task", assignee = "Bob", parent = "PE-2",
    priority = "Low", created = "2026-10-03T10:00:00.000+0000", status_category = "To Do" },
  { key = "PE-4", summary = "delta root", status = "Review", type = "Bug", assignee = "Ann", priority = "Low",
    created = "2026-10-04T10:00:00.000+0000", status_category = "In Progress" },
}

-- run_tui(keys, opts): drive tui.run headless. keys = token list (keyseq). read_key yields
-- the tokens, then nil once (non-interactive main loop quits), then errors so a modal or
-- chord left waiting fails loudly instead of spinning forever.
-- opts: issues (fixture rows), view, project, api (stub fns for jira_tui.api), load (fn override).
-- opts.sprint / opts.ui: stub fns for jira_tui.sprint / jira_tui.ui. opts.state: persist fake (fake_state()).
-- opts.queries / opts.hidden_tabs / opts.cache_ttl / opts.refresh_interval / opts.clock: as passed by init.
-- opts.tty: read_key acts like a tty -- "tick" tokens are idle timeouts, function tokens run then
-- tick, and the feed ends with ctrl-c instead of EOF. { "click", row = r } clicks screen row r.
-- returns { ok, err, out = captured output, loads = loader calls, api / sprint = call logs }
local function run_tui(keys, opts)
  opts = opts or {}
  local term = require("jira_tui.term")
  local api = require("jira_tui.api")
  local tui = require("jira_tui.tui")
  local issues = opts.issues or TUI_FIXTURE
  local out, loads = {}, {}
  local i, exhausted = 0, false
  local _, restore_term = stub(term, {
    raw_on = function() end, raw_off = function() end, enter = function() end, leave = function() end,
    clear = function() end, moveto = function() end,
    out = function(s) out[#out + 1] = s end,
    size = function() return 30, 120 end,
    isatty = function() return opts.tty == true end,
    read_key = function()
      i = i + 1
      local tok = keys[i]
      if type(tok) == "function" then tok(); return nil end
      if type(tok) == "table" then term.mouse = { row = tok.row, col = tok.col or 1 }; return tok[1] end
      if tok == "tick" then return nil end
      if tok then return tok end
      if exhausted then error("feed exhausted") end
      exhausted = true
      if opts.tty then return "ctrl-c" end
      return nil
    end,
  })
  local api_log, restore_api = stub(api, opts.api or {})
  local sprint_log, restore_sprint = stub(require("jira_tui.sprint"), opts.sprint or {})
  local _, restore_ui = stub(require("jira_tui.ui"), opts.ui or {})
  local o_stderr = io.stderr
  io.stderr = { write = function() end }
  local ok_, err_ = tui.run({
    load = function(view, filter, project)
      loads[#loads + 1] = { view = view, filter = filter, project = project }
      if opts.load then return opts.load(view, filter, project) end
      local copy = {}
      for n, r in ipairs(issues) do copy[n] = r end
      return copy, nil, false
    end,
    project = opts.project or "PE",
    initial_view = opts.view or "My Issues",
    my_projects = {},
    hidden_tabs = opts.hidden_tabs or {},
    queries = opts.queries,
    cache_ttl = opts.cache_ttl,
    refresh_interval = opts.refresh_interval,
    clock = opts.clock,
    state = opts.state,
  })
  io.stderr = o_stderr
  restore_api(); restore_sprint(); restore_ui(); restore_term()
  return { ok = ok_, err = err_, out = table.concat(out), loads = loads, api = api_log, sprint = sprint_log }
end

do
  local r = run_tui(keyseq())
  ok(r.ok, "harness: empty feed exits cleanly (" .. tostring(r.err) .. ")")
  eq(#r.loads, 1, "harness: initial load once")
  ok(r.out:find("alpha root", 1, true), "harness: board rows drawn")
  ok(r.out:find("(4)", 1, true), "harness: title count = 4 issues")

  r = run_tui(keyseq("/"))
  ok(not r.ok and tostring(r.err):find("feed exhausted"), "harness: modal waiting on input fails loudly")

  -- Enter on a leaf opens detail; q closes it
  local issue = { key = "PE-1", fields = { summary = "alpha root", status = { name = "To Do" },
    issuetype = { name = "Story" }, project = { key = "PE" } } }
  r = run_tui(keyseq("enter", "q"), { api = {
    get_issue = function() return issue end,
    get_comments = function() return {} end,
  } })
  ok(r.ok, "harness: enter/q flow ok (" .. tostring(r.err) .. ")")
  local gi = calls(r.api, "get_issue")
  eq(#gi, 1, "enter opens detail: one get_issue")
  eq(gi[1] and gi[1][2], "PE-1", "enter opens detail for the cursor row")
  ok(r.out:find("PE-1  alpha root", 1, true), "detail popup title drawn")

  -- / filter narrows the visible count
  r = run_tui(keyseq("/", "delta", "enter"))
  ok(r.ok, "harness: filter flow ok (" .. tostring(r.err) .. ")")
  ok(r.out:find("(1)", 1, true), "filter narrows title count to 1")
  eq(#r.loads, 1, "filter is client-side: no extra load")

  -- s picks a transition and sends its id
  r = run_tui(keyseq("s", "j", "enter"), { api = {
    get_transitions = function() return { { id = "11", name = "To Do" }, { id = "21", name = "Start", to = { name = "In Progress" } } } end,
    transition_issue = function() return true end,
  }, sprint = { get_issue_row = function() return { key = "PE-1", summary = "alpha root", status = "In Progress" } end } })
  ok(r.ok, "harness: status flow ok (" .. tostring(r.err) .. ")")
  local tr = calls(r.api, "transition_issue")
  eq(#tr, 1, "s: one transition_issue call")
  eq(tr[1] and tr[1][2], "PE-1", "s: transition targets cursor row")
  eq(tr[1] and tr[1][3], "21", "s: transition id = picked item")
  eq(#r.loads, 1, "s: no full reload after transition")
  ok(r.out:find("PE-1 → In Progress", 1, true), "s: success message shown")
end

-- ---- api.myself memo ----
do
  local api = require("jira_tui.api")
  api._me = nil
  local fail = true
  local log, restore = stub(api, { request = function()
    if fail then return nil, "http 500" end
    return { accountId = "acc-1", displayName = "Me", emailAddress = "x" }
  end })
  local me, err = api.myself()
  ok(me == nil and err == "http 500", "myself: failure returns err")
  fail = false
  me = api.myself()
  eq(me and me.accountId, "acc-1", "myself: accountId")
  eq(me and me.displayName, "Me", "myself: displayName")
  api.myself()
  eq(#calls(log, "request"), 2, "myself: failure not cached, success cached (2 requests for 3 calls)")
  eq(log[1][3], "/rest/api/3/myself", "myself endpoint")
  restore(); api._me = nil
end

-- ---- detail: one request + per-key cache ----
do
  local api = require("jira_tui.api")
  local log, restore = stub(api, { request = function() return { key = "PE-1", fields = {} } end })
  api.get_issue("PE-1", { "summary", "comment", "customfield_1" })
  eq(log[1][3], "/rest/api/3/issue/PE-1?fields=summary,comment,customfield_1", "get_issue fields -> query string")
  api.get_issue("PE-1")
  eq(log[2][3], "/rest/api/3/issue/PE-1", "get_issue without fields = all fields")
  restore()

  local cs = {}
  for i = 1, 20 do cs[i] = { id = tostring(i) } end
  local rc, more = model.recent_comments({ comments = cs, total = 20, maxResults = 100 }, 15)
  eq(#rc, 15, "recent_comments caps at n")
  eq(rc[1].id, "20", "recent_comments newest first")
  eq(rc[15].id, "6", "recent_comments drops oldest")
  eq(more, false, "recent_comments: page holds all")
  rc, more = model.recent_comments({ comments = cs, total = 185, maxResults = 100 }, 15)
  eq(more, true, "recent_comments: total > page -> fallback needed")
  rc, more = model.recent_comments(nil, 15)
  ok(#rc == 0 and more == false, "recent_comments: missing field")

  local function issue_with(comment)
    return { key = "PE-1", fields = { summary = "alpha root", status = { name = "To Do" }, comment = comment } }
  end
  local small = { comments = { { id = "1", body = "old" }, { id = "2", body = "new" } }, total = 2 }
  local r = run_tui(keyseq("enter", "q", "enter", "q"), { api = {
    get_issue = function() return issue_with(small) end,
    get_comments = function() return {} end,
  } })
  ok(r.ok, "detail cache flow ok (" .. tostring(r.err) .. ")")
  eq(#calls(r.api, "get_issue"), 1, "detail: reopen served from cache")
  eq(#calls(r.api, "get_comments"), 0, "detail: comments embedded, no second request")
  local gi = calls(r.api, "get_issue")[1] or {}
  local fl = table.concat(gi[3] or {}, ",")
  ok(fl:find("comment", 1, true) and fl:find("issuelinks", 1, true), "detail: fields include comment + links")
  ok(r.out:find("Comments (2)", 1, true), "detail: embedded comments rendered")

  local big = { comments = small.comments, total = 185 }
  r = run_tui(keyseq("enter", "q"), { api = {
    get_issue = function() return issue_with(big) end,
    get_comments = function() return { { id = "185", body = "newest" } } end,
  } })
  eq(#calls(r.api, "get_comments"), 1, "detail: total > page -> one get_comments fallback")
  ok(r.out:find("Comments (1)", 1, true), "detail: fallback comments used")

  -- mutation invalidates; r clears all
  r = run_tui(keyseq("enter", "q", "A", "enter", "q", "r", "enter", "q"), {
    api = { get_issue = function() return issue_with(small) end, get_comments = function() return {} end,
      myself = function() return { accountId = "me1", displayName = "Me" } end,
      assign_issue = function() return true end },
    sprint = { get_issue_row = function(key) return { key = key, summary = "alpha root", status = "To Do" } end },
  })
  ok(r.ok, "detail invalidation flow ok (" .. tostring(r.err) .. ")")
  eq(#calls(r.api, "get_issue"), 3, "detail: refetch after mutation and after r")

  r = run_tui(keyseq("enter"), { api = { get_issue = function() return nil, "http 404" end } })
  ok(r.out:find("PE-1: http 404", 1, true), "detail: fetch error shown")
end

-- ---- bad jql keeps the editor open ----
do
  local function fake_state(hist)
    local added = {}
    return { data = { jql_history = hist or {} }, remember = function() end, save = function() end,
      add_jql = function(q) added[#added + 1] = q end }, added
  end
  local function jql_loader(fail_n)
    local n = 0
    return function(view)
      if view:sub(1, 4) ~= "JQL:" then return {}, nil end
      n = n + 1
      if n <= fail_n then return nil, "Error in the JQL Query: bad" end
      return { TUI_FIXTURE[1] }, nil
    end
  end

  local stt, added = fake_state()
  local r = run_tui(keyseq("g", "j", "project = X", "ctrl-s", "ctrl-s"), { load = jql_loader(1), state = stt })
  ok(r.ok, "bad jql flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 3, "bad jql: initial + failed + retried load")
  eq(r.loads[2].view, "JQL:project = X", "bad jql: first attempt")
  eq(r.loads[3].view, r.loads[2].view, "bad jql: editor reopened prefilled with the same query")
  ok(r.out:find("Error in the JQL Query: bad", 1, true), "bad jql: error shown in editor")
  eq(#added, 1, "bad jql: history gets the query once")
  eq(added[1], "project = X", "bad jql: history gets the working query")

  stt, added = fake_state()
  r = run_tui(keyseq("g", "j", "nope", "ctrl-s", "esc", "r"), { load = jql_loader(99), state = stt })
  ok(r.ok, "bad jql esc flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 3, "bad jql: esc stops retrying (then r)")
  eq(#added, 0, "bad jql: failed query not saved")
  eq(r.loads[3].view, "My Issues", "bad jql: board view unchanged after esc")

  -- picking a failing history entry lands in the editor on that query
  stt, added = fake_state({ "status = Broken" })
  r = run_tui(keyseq("J", "j", "enter", "ctrl-s"), { load = jql_loader(1), state = stt })
  ok(r.ok, "history fail flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 3, "history fail: retry from editor")
  eq(r.loads[3].view, "JQL:status = Broken", "history fail: editor prefilled with picked query")
  ok(r.out:find("Edit JQL", 1, true), "history fail: editor opened")
end

-- ---- saved query tabs ----
do
  local config = require("jira_tui.config")
  local render = require("jira_tui.render")
  local init = require("jira_tui.init")
  local function plain(s) return (s:gsub("\27%[[%d;]*m", "")) end

  local qs = assert(config.parse_queries({ { name = "Review", jql = "status = Review" },
    { name = "Bugs", jql = "type = Bug", key = 5 }, { name = "Mine", jql = "assignee = currentUser()" } }))
  eq(qs[1].key, "1", "queries: key defaults to position")
  eq(qs[2].key, "5", "queries: explicit numeric key -> string")
  eq(qs[3].key, "3", "queries: third gets 3")
  local bad, berr = config.parse_queries({ { name = "Backlog", jql = "x" } })
  ok(bad == nil and berr:find("taken"), "queries: built-in name rejected")
  bad, berr = config.parse_queries({ { name = "A", jql = "x" }, { name = "A", jql = "y" } })
  ok(bad == nil and berr:find("taken"), "queries: duplicate name rejected")
  bad = config.parse_queries({ { name = "A", jql = "x" }, { name = "B", jql = "y", key = "1" } })
  eq(bad, nil, "queries: key collision rejected")
  bad = config.parse_queries({ { name = "A", jql = "x", key = "0" } })
  eq(bad, nil, "queries: key must be 1-9")
  bad = config.parse_queries({ { name = "A" } })
  eq(bad, nil, "queries: jql required")
  eq(#assert(config.parse_queries(nil)), 0, "queries: nil -> empty")

  local names = {}
  for _, t in ipairs(render.tabs(qs, { Backlog = true, Help = true })) do names[#names + 1] = t.name end
  eq(table.concat(names, ","), "My Issues,Project,Review,Bugs,Mine,JQL,Sprint,Help", "tabs: order, hidden dropped, Help kept")
  local bar = render.tab_bar("Bugs", render.tabs(qs), 140)
  ok(bar:find("48;2;" .. ansi.color.yellow .. ";1m Bugs (5) ", 1, true), "tabs: active query chip highlighted")
  ok(plain(bar):find("Review (1)", 1, true), "tabs: query chip shows jump key")

  local log, restore = stub(sprint, { get_issues_by_jql = function() return {} end, get_my_issues = function() return {} end,
    get_project_issues = function() return {} end, get_sprint_issues = function() return {} end })
  local load = init.make_loader("PE", {}, qs)
  load("Bugs", nil, nil)
  load("My Issues", nil, nil)
  load("Project", nil, "OPS")
  load(render.sprint_view(42, "OPS Sprint 3"), nil, "OPS")
  eq((calls(log, "get_project_issues")[1] or {})[2], "OPS", "loader: Project view -> project's open issues")
  local si = calls(log, "get_sprint_issues")[1] or {}
  eq(si[3], 42, "loader: picked sprint -> its id"); eq(si[2], "OPS", "loader: sprint keeps the project")
  ok(not config.parse_queries({ { name = "Project", jql = "x" } }), "queries: Project is reserved")
  ok(not config.parse_queries({ { name = "Sprint:1:x", jql = "x" } }), "queries: Sprint: prefix is reserved")
  local jl = calls(log, "get_issues_by_jql")
  eq(#jl, 1, "loader: query view routed to jql")
  eq(jl[1] and jl[1][3], "type = Bug", "loader: query jql passed")
  eq(jl[1] and jl[1][2], "PE", "loader: default project passed")
  restore()

  local r = run_tui(keyseq("2", "5", "?", "1", "right"), { queries = qs })
  ok(r.ok, "query tabs flow ok (" .. tostring(r.err) .. ")")
  local seen = {}
  for _, l in ipairs(r.loads) do seen[#seen + 1] = l.view end
  eq(table.concat(seen, ","), "My Issues,Bugs,Review,Bugs", "digits jump (2 unbound), work over help, right cycles to next query")
end

-- ---- per-view cache ----
do
  eq(model.cache_fresh(nil, 300, 100), false, "cache_fresh: no entry")
  eq(model.cache_fresh({ at = 100 }, 300, 399), true, "cache_fresh: inside ttl")
  eq(model.cache_fresh({ at = 100 }, 300, 400), false, "cache_fresh: expired at ttl")
  eq(model.cache_fresh({ at = 100 }, 0, 100), false, "cache_fresh: ttl 0 disables")
  eq(model.cache_fresh({ at = 100 }, nil, 100), false, "cache_fresh: nil ttl disables")
  local raw = { { key = "A-1" } }
  eq(model.replace_row(raw, { key = "A-2" }), nil, "replace_row: absent -> nil, no append")
  eq(#raw, 1, "replace_row: length kept")

  local stt = { data = { jql_history = { "project = X" } }, remember = function() end, save = function() end,
    add_jql = function() end }
  local r = run_tui(keyseq("J", "j", "enter", "M"), { cache_ttl = 300, state = stt })
  ok(r.ok, "cache flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 2, "cache: M -> J query -> M = 2 loader calls")
  ok(r.out:find("updated 0m ago", 1, true), "cache: footer shows fetch age")
  r = run_tui(keyseq("J", "j", "enter", "M", "r"), { cache_ttl = 300, state = stt })
  eq(#r.loads, 3, "cache: r forces a fetch")
  r = run_tui(keyseq("J", "j", "enter", "M"), { state = stt })
  eq(#r.loads, 3, "cache: off without cache_ttl")

  -- project view for another project is a different cache entry; p lands on the Project view
  r = run_tui(keyseq("P", "p", "OPS", "enter"), { cache_ttl = 300, view = "Project" })
  eq(#r.loads, 2, "cache: project switch refetches the same view id")
  eq(r.loads[2] and r.loads[2].view, "Project", "p: opens the Project view")
  eq(r.loads[2] and r.loads[2].project, "OPS", "p: for the new project")
  r = run_tui(keyseq("p", "pe x", "enter", "r"), { view = "Project" })
  ok(r.out:find("not a project key: PE X", 1, true), "p: malformed key refused before it reaches a url")
  eq(r.loads[2] and r.loads[2].project, "PE", "p: refused key leaves the project alone")

  -- a row patch reaches other cached views holding that key. PE-1 sits on row 1 in the
  -- query view and row 2 in My Issues, so the second paint is a fresh row.
  local function last_row_with(out, needle)
    local pos, from = nil, 1
    while true do
      local i = out:find(needle, from, true)
      if not i then break end
      pos, from = i, i + 1
    end
    if not pos then return "" end
    local nxt = out:find("\27%[%d+;%d+H", pos)
    return out:sub(pos, nxt and nxt - 1 or -1)
  end
  r = run_tui(keyseq("J", "j", "enter", "A", "M"), { cache_ttl = 300, state = stt,
    load = function(view)
      if view == "My Issues" then return { TUI_FIXTURE[4], TUI_FIXTURE[1] }, nil end
      return { TUI_FIXTURE[1] }, nil
    end,
    api = { myself = function() return { accountId = "me1", displayName = "Me" } end,
      assign_issue = function() return true end },
    sprint = { get_issue_row = function(key)
      return { key = key, summary = "alpha root", status = "Patched", status_category = "In Progress" } end },
  })
  ok(r.ok, "cache patch flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 2, "cache patch: back to M served from cache")
  ok(last_row_with(r.out, "alpha root"):find("Patched", 1, true), "cache patch: cached My Issues shows patched row")
end

-- ---- markdown -> adf ----
do
  local mdm = require("jira_tui.md")
  local json = require("jira_tui.json")
  local function rt(x) return (model.adf_to_markdown(mdm.to_adf(x)):gsub("%s+$", "")) end
  local cases = {
    { "plain paragraph", "para" },
    { "two paragraphs", "one\n\ntwo" },
    { "line break", "a\nb" },
    { "h1", "# Title" }, { "h3", "### Sub" },
    { "bullets", "- a\n- b" },
    { "ordered", "1. a\n2. b" },
    { "fence + lang", "```lua\nlocal x = 1\nprint(x)\n```" },
    { "fence no lang", "```\nraw\n```" },
    { "quote", "> q1\n> q2" },
    { "rule", "a\n\n---\n\nb" },
    { "bold", "a **b** c" }, { "em", "a _e_ c" }, { "code", "use `x()` here" },
    { "strike", "~~gone~~" }, { "link", "see [docs](https://x.io/d)" },
    { "mixed", "# H\n\nintro **b**\n\n- one\n- two\n\n```sh\nls\n```\n\n> q\n\nend" },
  }
  for _, c in ipairs(cases) do eq(rt(c[2]), c[2], "md round-trip: " .. c[1]) end

  eq(rt("*star em*"), "_star em_", "md: *em* normalizes to _em_")
  eq(rt("* a\n* b"), "- a\n- b", "md: * bullets normalize to -")
  eq(rt("snake_case_name and 2*3*4"), "snake_case_name and 2*3*4", "md: word-internal _ and * stay literal")
  local doc = mdm.to_adf("go to https://x.io/a/b.")
  local para = doc.content[1].content
  eq(para[2].text, "https://x.io/a/b", "md: bare url, trailing punctuation dropped")
  eq(para[2].marks[1].attrs.href, "https://x.io/a/b", "md: bare url -> link mark")
  eq(para[3].text, ".", "md: punctuation stays as text")
  eq(mdm.to_adf("   \n"), nil, "md: blank -> nil")
  ok(json.encode(mdm.to_adf("```\n```").content[1].content) == "[]", "md: empty code block content encodes as []")
  eq(mdm.to_adf("```py\nx").content[1].content[1].text, "x", "md: unclosed fence runs to end")
end

-- ---- ui.edit_external ----
do
  local term = require("jira_tui.term")
  local ui = require("jira_tui.ui")
  local order = {}
  local function rec(name) return function() order[#order + 1] = name end end
  local _, restore = stub(term, { leave = rec("leave"), raw_off = rec("raw_off"), raw_on = rec("raw_on"), enter = rec("enter") })
  local o_run = ui._run_editor
  local seen_path, seen_initial
  local write = "## New\n\nbody\n\n"
  ui._run_editor = function(path)
    order[#order + 1] = "editor"
    seen_path = path
    local f = io.open(path, "r"); seen_initial = f:read("*a"); f:close()
    f = io.open(path, "w"); f:write(write); f:close()
  end
  eq(ui.edit_external("old", ".md"), "## New\n\nbody", "edit_external returns edited text, trailing ws trimmed")
  eq(seen_initial, "old", "edit_external seeds the file")
  ok(seen_path and seen_path:sub(-3) == ".md", "edit_external keeps the extension")
  eq(table.concat(order, ","), "leave,raw_off,editor,raw_on,enter", "edit_external restores the terminal around the editor")
  ok(io.open(seen_path, "r") == nil, "edit_external removes the temp file")
  write = "old\n"
  eq(ui.edit_external("old"), nil, "edit_external: unchanged -> nil")
  write = "  \n"
  eq(ui.edit_external(""), nil, "edit_external: blank -> nil")
  ui._run_editor = function() error("editor blew up") end
  order = {}
  eq(ui.edit_external("x"), nil, "edit_external: editor error -> nil")
  eq(table.concat(order, ","), "leave,raw_off,raw_on,enter", "edit_external: terminal restored on editor error")
  ui._run_editor = o_run
  restore()
end

-- ---- comment (C) ----
do
  local api = require("jira_tui.api")
  local log, restore = stub(api, { request = function() return { id = "1" } end })
  api.add_comment("PE-1", { type = "doc", version = 1, content = {} })
  eq(log[1][2], "POST", "add_comment method")
  eq(log[1][3], "/rest/api/3/issue/PE-1/comment", "add_comment endpoint")
  eq(log[1][4].body.type, "doc", "add_comment wraps adf in body")
  restore()

  local issue = { key = "PE-1", fields = { summary = "alpha root", status = { name = "To Do" } } }
  local r = run_tui(keyseq("enter", "q", "C", "enter", "q"), {
    ui = { edit_external = function() return "- one\n- `two`" end },
    api = { add_comment = function() return { id = "9" } end, get_issue = function() return issue end },
  })
  ok(r.ok, "comment flow ok (" .. tostring(r.err) .. ")")
  local ac = calls(r.api, "add_comment")
  eq(#ac, 1, "C: one add_comment call")
  eq(ac[1] and ac[1][2], "PE-1", "C: comments on cursor row")
  eq(ac[1] and ac[1][3].content[1].type, "bulletList", "C: body converted from markdown")
  ok(r.out:find("commented on PE-1", 1, true), "C: success message")
  eq(#calls(r.api, "get_issue"), 2, "C: detail cache invalidated")

  r = run_tui(keyseq("C"), { ui = { edit_external = function() return nil end },
    api = { add_comment = function() return true end } })
  eq(#calls(r.api, "add_comment"), 0, "C: empty editor -> no call")

  r = run_tui(keyseq("C"), { ui = { edit_external = function() return "x" end },
    api = { add_comment = function() return nil, "http 403" end } })
  ok(r.out:find("comment failed: http 403", 1, true), "C: failure surfaced")
end

-- ---- actionable detail popup ----
do
  local function issue_for(key)
    for _, r in ipairs(TUI_FIXTURE) do
      if r.key == key then
        return { key = key, fields = { summary = r.summary, status = { name = r.status }, project = { key = "PE" } } }
      end
    end
  end
  local base_api = {
    get_issue = function(key) return issue_for(key) end,
    get_transitions = function() return { { id = "11", name = "To Do" }, { id = "21", name = "Start", to = { name = "In Progress" } } } end,
    transition_issue = function() return true end,
  }
  local row = { get_issue_row = function(key) return { key = key, summary = "alpha root", status = "In Progress" } end }

  -- s inside detail: transition sent, detail refetched, popup stays up, board doesn't paint the message
  local r = run_tui(keyseq("enter", "s", "j", "enter", "q"), { api = base_api, sprint = row })
  ok(r.ok, "detail s flow ok (" .. tostring(r.err) .. ")")
  local tr = calls(r.api, "transition_issue")
  eq(#tr, 1, "detail s: one transition")
  eq(tr[1] and tr[1][2], "PE-1", "detail s: acts on shown issue")
  eq(#calls(r.api, "get_issue"), 2, "detail s: detail refetched after mutation")
  ok(r.out:find(" PE-1 → In Progress   y copy key", 1, true), "detail s: handler message shown as popup note")
  ok(not r.out:find("moving PE-1", 1, true), "detail s: board footer not painted while popup is up")

  -- ] / [ walk board order (skipping spacers), q leaves cursor on the last viewed issue
  r = run_tui(keyseq("enter", "]", "]", "[", "q", "s", "enter"), { api = base_api, sprint = row })
  ok(r.ok, "detail nav flow ok (" .. tostring(r.err) .. ")")
  local keys_seen = {}
  for _, c in ipairs(calls(r.api, "get_issue")) do keys_seen[#keys_seen + 1] = c[2] end
  eq(table.concat(keys_seen, ","), "PE-1,PE-2,PE-3", "detail nav: ] ] [ fetches next issues, [ served from cache")
  ok(r.out:find("PE-3  gamma child", 1, true), "detail nav: next issue title drawn")
  tr = calls(r.api, "transition_issue")
  eq(tr[1] and tr[1][2], "PE-2", "detail nav: q returns with cursor on last viewed (PE-2)")

  -- [ on the first row stays put with a note
  r = run_tui(keyseq("enter", "[", "q"), { api = base_api })
  eq(#calls(r.api, "get_issue"), 1, "detail nav: [ on first row doesn't move")
  ok(r.out:find("first issue", 1, true), "detail nav: first issue note")

  -- C from the popup posts and reloads with the new comment
  r = run_tui(keyseq("enter", "C", "q"), { api = {
    get_issue = function(key) return issue_for(key) end, add_comment = function() return { id = "1" } end },
    ui = { edit_external = function() return "hi" end } })
  eq(#calls(r.api, "add_comment"), 1, "detail C: comment posted")
  eq(#calls(r.api, "get_issue"), 2, "detail C: reloaded after comment")
end

-- ---- filterable picker + assignable search ----
do
  local term = require("jira_tui.term")
  local ui = require("jira_tui.ui")
  local api = require("jira_tui.api")
  local function pick(keys, items, opts)
    local i = 0
    local _, restore = stub(term, { out = function() end, moveto = function() end, size = function() return 30, 120 end,
      read_key = function() i = i + 1; if keys[i] then return keys[i] end; error("feed exhausted") end })
    local res = { pcall(ui.select, "t", items, opts) }
    restore()
    local up = unpack or table.unpack
    return up(res)
  end
  local fruit = { "apple", "Banana", "cherry", "blueberry" }
  local okp, it, idx = pick(keyseq("/", "b", "enter", "enter"), fruit)
  ok(okp, "select filter flow ok (" .. tostring(it) .. ")")
  eq(it, "Banana", "select filter: case-insensitive substring, first match")
  eq(idx, 2, "select filter: index into the original list")
  local _
  _, it = pick(keyseq("/", "b", "enter", "j", "enter"), fruit)
  eq(it, "blueberry", "select filter: j moves within matches")
  _, it = pick(keyseq("/", "bx", "bs", "e", "enter", "enter"), fruit)
  eq(it, "blueberry", "select filter: bs edits the filter")
  _, it = pick(keyseq("/", "zzz", "esc", "j", "enter"), fruit)
  eq(it, "Banana", "select filter: esc clears filter, picker stays open")
  _, it = pick(keyseq("/", "q", "enter", "enter"), { "aq", "b" })
  eq(it, "aq", "select filter: q types in filter mode")
  _, it = pick(keyseq("/", "zzz", "enter", "enter", "esc"), fruit)
  eq(it, nil, "select filter: enter on no matches selects nothing")
  local queries = {}
  _, it = pick(keyseq("/", "bry", "enter", "enter"), fruit, { on_filter = function(q)
    queries[#queries + 1] = q; return { "Bryan G" } end })
  eq(queries[1], "bry", "select on_filter gets the query on enter")
  eq(it, "Bryan G", "select on_filter: new list replaces items")

  eq(api.urlencode("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9", "urlencode")
  eq(api.urlencode("bry.an-x_y~z"), "bry.an-x_y~z", "urlencode keeps unreserved")
  local log, restore = stub(api, { request = function() return {} end })
  api.get_assignable("PE-1", "bry g")
  api.get_assignable("PE-1")
  eq(log[1][3], "/rest/api/3/user/assignable/search?issueKey=PE-1&maxResults=50&query=bry%20g", "get_assignable query")
  eq(log[2][3], "/rest/api/3/user/assignable/search?issueKey=PE-1&maxResults=50", "get_assignable no query")
  restore()

  local r = run_tui(keyseq("a", "/", "bry", "enter", "enter"), {
    api = { get_assignable = function(_, q)
        if q then return { { accountId = "b1", displayName = "Bryan G" } } end
        return { { accountId = "a1", displayName = "Ann" } }
      end,
      assign_issue = function() return true end },
    sprint = { get_issue_row = function(key) return { key = key, summary = "alpha root", status = "To Do" } end },
  })
  ok(r.ok, "assign search flow ok (" .. tostring(r.err) .. ")")
  local ga = calls(r.api, "get_assignable")
  eq(#ga, 2, "assign search: initial list + one search")
  eq(ga[2] and ga[2][3], "bry", "assign search: server query passed")
  local aa = calls(r.api, "assign_issue")
  eq(aa[1] and aa[1][3], "b1", "assign search: picks the searched user")
end

-- ---- typed create + child create ----
do
  local api = require("jira_tui.api")
  local config = require("jira_tui.config")
  api._create_types = {}
  local log, restore = stub(api, { request = function(_, ep)
    if ep:find("createmeta") then return { issueTypes = { { id = "10001", name = "Story", subtask = false } } } end
    return { key = "PE-50" }
  end })
  eq(api.get_create_types("PE")[1].name, "Story", "get_create_types returns issueTypes")
  api.get_create_types("PE")
  eq(#log, 1, "get_create_types cached per project")
  eq(log[1][3], "/rest/api/3/issue/createmeta/PE/issuetypes", "get_create_types endpoint")
  api.create_issue("PE", "S", { id = "10003" }, { parent = "PE-2", labels = { "x" }, points = 2, priority = "High",
    description = "**b**", assignee_account_id = "me" })
  local f = log[2][4].fields
  eq(f.issuetype.id, "10003", "create: issuetype by id")
  eq(f.parent.key, "PE-2", "create: parent key")
  eq(f.labels[1], "x", "create: labels")
  eq(f[config.get_project_config("PE").story_point_field], 2, "create: points on the project's field")
  eq(f.priority.name, "High", "create: priority by name")
  eq(f.description.content[1].content[1].marks[1].type, "strong", "create: description from markdown")
  api.create_issue("PE", "S", "Story")
  eq(log[3][4].fields.issuetype.name, "Story", "create: type name still accepted")
  restore(); api._create_types = {}

  local TYPES = { { id = "1", name = "Epic", subtask = false }, { id = "2", name = "Story", subtask = false },
    { id = "3", name = "Sub-task", subtask = true }, { id = "4", name = "Sub-defect", subtask = true } }
  local function created(keys, extra)
    extra = extra or {}
    local a = { get_create_types = function(p) return p == "OPS" and { { id = "9", name = "Task", subtask = false } } or TYPES end,
      myself = function() return { accountId = "me1" } end,
      get_priorities = function() return { { id = "1", name = "Highest" }, { id = "3", name = "Medium" } } end,
      create_issue = function() return { key = "PE-77" } end }
    for k, fn in pairs(extra.api or {}) do a[k] = fn end
    local r = run_tui(keys, { issues = extra.issues, ui = extra.ui, api = a, cache_ttl = extra.cache_ttl,
      sprint = { get_issue_row = function(key) return { key = key, summary = "Child", status = "To Do" } end } })
    return r, calls(r.api, "create_issue")
  end
  -- form fields: 1 project, 2 type, 3 summary, 4 description, 5 priority, 6 labels, 7 assignee, 8 parent.
  -- it opens on summary, the first empty required field
  local r, cs = created(keyseq("c", "Fix it", "ctrl-s"))
  ok(r.ok, "c flow ok (" .. tostring(r.err) .. ")")
  local c = cs[1]
  eq(c and c[2], "PE", "c: project prefilled")
  eq(c and c[3], "Fix it", "c: summary typed straight into the focused field")
  eq(c and c[4].id, "2", "c: default type prefers Task, then Story")
  eq(c and c[5].parent, nil, "c: no parent")
  eq(c and c[5].assignee_account_id, "me1", "c: assigned to me by default")
  ok(r.out:find("Summary *", 1, true) and r.out:find("Description", 1, true) and r.out:find("Ctrl-s create", 1, true),
    "c: form labels every field and says how to submit")
  ok(r.out:find("created PE-77  ·  y copies the key", 1, true), "c: success names the key and how to copy it")
  -- gc on a story: type picker only offers sub-task types, parent = that story
  r, cs = created(keyseq("g", "c", "up", "enter", "j", "enter", "down", "Child", "down", "down", "down", "t1, t2", "ctrl-s"))
  ok(r.ok, "gc flow ok (" .. tostring(r.err) .. ")")
  c = cs[1]
  eq(c and c[4].id, "4", "gc on story: picker offers sub-task types only (2nd = Sub-defect)")
  eq(c and c[5].parent, "PE-1", "gc on story: parent = row")
  eq(c and table.concat(c[5].labels, "|"), "t1|t2", "gc: labels field split")
  ok(r.out:find("New child of PE-1", 1, true), "gc: form title names the parent")
  -- gc on a sub-task row -> sibling under the same parent
  r, cs = created(keyseq("j", "j", "g", "c", "Kid", "ctrl-s"))
  eq(cs[1] and cs[1][5].parent, "PE-2", "gc on sub-task: parent = its parent")
  eq(cs[1] and cs[1][4].id, "3", "gc on sub-task: first sub-task type")
  -- gc on an epic -> standard types
  r, cs = created(keyseq("g", "c", "x", "ctrl-s"), { issues = { { key = "PE-9", summary = "epic", type = "Epic", status = "To Do" } } })
  eq(cs[1] and cs[1][4].id, "2", "gc on epic: standard type")
  eq(cs[1] and cs[1][5].parent, "PE-9", "gc on epic: parent = epic")
  -- empty summary is caught in the form, nothing sent until it's filled
  r, cs = created(keyseq("c", "ctrl-s", "x", "ctrl-s"))
  ok(r.out:find("Summary is required", 1, true), "c: required field named")
  eq(#cs, 1, "c: one create once summary is filled")
  -- jira rejecting the create reopens the form with the error and everything typed
  local n = 0
  r, cs = created(keyseq("c", "Fix", "ctrl-s", "ctrl-s"), { api = { create_issue = function()
    n = n + 1
    if n == 1 then return nil, "HTTP 400: priority: invalid" end
    return { key = "PE-77" }
  end } })
  eq(#cs, 2, "c: failed create reopens the form")
  eq(cs[2] and cs[2][3], "Fix", "c: reopened form kept the summary")
  ok(r.out:find("create failed: HTTP 400: priority: invalid", 1, true), "c: jira error shown in the form")
  local reopened = ansi.strip(r.out:sub(1, (r.out:find("create failed", 1, true))))
  reopened = reopened:sub(reopened:match(".*()New issue"))
  ok(reopened:find("▌ Priority", 1, true), "c: reopened form focuses the field jira rejected")
  -- switching project to one without the chosen type flips to its default and says so
  r, cs = created(keyseq("c", "up", "up", "bs", "bs", "ops", "down", "down", "x", "ctrl-s", "ctrl-s"))
  ok(r.out:find("OPS has no Story type; switched to Task", 1, true), "c: type missing in new project explained")
  eq(cs[1] and cs[1][2], "OPS", "c: project field uppercased")
  eq(cs[1] and cs[1][4].id, "9", "c: created with the new project's type")
  r, cs = created(keyseq("c", "x", "up", "up", "-", "ctrl-s", "esc", "esc"))
  ok(r.out:find("PE-: not a project key", 1, true), "c: malformed project caught in the form")
  eq(#calls(r.api, "get_create_types"), 1, "c: malformed project never sent to jira")
  -- priority picker, assignee toggle, description via $EDITOR
  r, cs = created(keyseq("c", "x", "down", "enter", "down", "enter", "j", "j", "enter", "down", "down", "enter", "ctrl-s"),
    { ui = { edit_external = function() return "see https://example.com/repo" end } })
  c = cs[1]
  eq(c and c[5].description, "see https://example.com/repo", "c: description from $EDITOR")
  eq(c and c[5].priority, "Medium", "c: priority picked from jira's list")
  eq(c and c[5].assignee_account_id, nil, "c: assignee toggled to unassigned")
  ok(r.out:find("see https://example.com/repo", 1, true), "c: description previewed in the form")
  -- Esc on an untouched form closes it; with input it asks first
  r, cs = created(keyseq("c", "esc", "r"))
  eq(#cs, 0, "c: esc on untouched form sends nothing"); eq(#r.loads, 2, "c: board live after esc")
  r, cs = created(keyseq("c", "x", "esc", "esc", "r"))
  ok(r.out:find("Esc again to discard", 1, true), "c: esc with input asks before discarding")
  eq(#cs, 0, "c: discarded"); eq(#r.loads, 2, "c: second esc closes the form, not the app")
  local tries = 0
  r, cs = created(keyseq("c", "Fix", "ctrl-s", "esc", "ctrl-s"), { api = { create_issue = function()
    tries = tries + 1
    if tries == 1 then return nil, "HTTP 400: boom" end
    return { key = "PE-77" }
  end } })
  eq(#calls(r.api, "create_issue"), 2, "c: esc on a form reopened after an error asks first instead of discarding")
  -- other cached views refetch after a create, so the new issue isn't stale-cached away
  r, cs = created(keyseq("P", "M", "c", "x", "ctrl-s", "P"), { cache_ttl = 300 })
  local views = {}
  for _, l in ipairs(r.loads) do views[#views + 1] = l.view end
  eq(table.concat(views, ","), "My Issues,Project,Project", "c: cached Project view refetched after create")
end

-- ---- project view + sprint picker ----
do
  local api = require("jira_tui.api")
  local render = require("jira_tui.render")
  eq(sprint.project_jql("PE"), "project = PE AND statusCategory != Done ORDER BY updated DESC", "project jql: open, no sprint clause")
  eq(render.view_label(render.sprint_view(7, "S 7")), "Sprint", "sprint view lights the Sprint tab")
  eq(render.view_label("Active Sprint"), "Sprint", "Active Sprint lights the Sprint tab")
  eq(render.view_title(render.sprint_view(7, "PE Sprint 7")), "PE Sprint 7", "sprint view titled by name")
  eq(render.view_title("Project"), "Open issues", "Project view title")
  eq(render.sprint_of("Sprint:12:a:b"), 12, "sprint_of: id"); eq(select(2, render.sprint_of("Sprint:12:a:b")), "a:b", "sprint_of: name keeps colons")

  local log, restore = stub(api, { request = function(_, ep)
    if ep:find("/board?", 1, true) then return { values = { { id = 1 } } } end
    if ep:find("startAt=0", 1, true) then return { values = { { id = 1 }, { id = 2 } }, isLast = false } end
    return { values = { { id = 3 } }, isLast = true }
  end })
  eq(#api.get_boards("PE"), 1, "get_boards: values")
  ok(log[1][3]:find("type=scrum", 1, true) and log[1][3]:find("projectKeyOrId=PE", 1, true), "get_boards: scrum boards of the project")
  eq(#api.get_sprints(1, "closed"), 3, "get_sprints: pages until isLast")
  ok(log[3][3]:find("startAt=2", 1, true) and log[3][3]:find("state=closed", 1, true), "get_sprints: second page starts after the first")
  restore()

  log, restore = stub(api, {
    get_boards = function() return { { id = 1 }, { id = 2 } } end,
    get_sprints = function(b)
      if b == 1 then return { { id = 12, state = "future" }, { id = 10, state = "active" }, { id = 4, state = "closed" } } end
      return { { id = 10, state = "active" }, { id = 11, state = "future" }, { id = 6, state = "closed" } }
    end })
  local ss, _, boards = sprint.list_sprints("PE", "active,future,closed")
  local ids = {}
  for _, sp in ipairs(ss) do ids[#ids + 1] = sp.id end
  eq(table.concat(ids, ","), "10,11,12,6,4", "list_sprints: deduped, active, future, then newest closed")
  eq(boards, 2, "list_sprints: board count")
  restore()

  local SPRINTS = { { id = 10, name = "PE Sprint 10", state = "active", startDate = "2026-10-06T00:00:00.000Z",
    endDate = "2026-10-20T00:00:00.000Z" }, { id = 11, name = "PE Sprint 11", state = "future" } }
  local function sprints(keys, list)
    return run_tui(keys, { sprint = { list_sprints = list or function(_, state)
      if state == "closed" then return { { id = 3, name = "Old one", state = "closed" } }, nil, 1 end
      return SPRINTS, nil, 1
    end } })
  end
  local r = sprints(keyseq("S", "enter"))
  ok(r.ok, "S flow ok (" .. tostring(r.err) .. ")")
  eq(r.loads[2] and r.loads[2].view, "Sprint:10:PE Sprint 10", "S: active sprint first, Enter lists it")
  ok(r.out:find("PE Sprint 10   - Project: PE", 1, true), "S: board titled by sprint name")
  ok(r.out:find("2026-10-06 → 2026-10-20", 1, true), "S: picker shows sprint dates")
  r = sprints(keyseq("S", "j", "j", "enter", "enter"))
  eq(r.loads[2] and r.loads[2].view, "Sprint:3:Old one", "S: past sprints load on demand")
  eq(#calls(r.sprint, "list_sprints"), 2, "S: closed sprints fetched only when asked")
  r = sprints(keyseq("S", "j", "j", "j", "enter"))
  eq(r.loads[2] and r.loads[2].view, "Active Sprint", "S: every open sprint")
  r = sprints(keyseq("S"), function() return {}, nil, 0 end)
  ok(r.out:find("PE has no scrum board", 1, true), "S: project without sprints says so")
  eq(#r.loads, 1, "S: nothing loaded without a board")
  r = run_tui(keyseq("P"))
  eq(r.loads[2] and r.loads[2].view, "Project", "P: Project view")
  ok(r.out:find("Open issues   - Project: PE", 1, true), "P: titled Open issues")

  -- @me filter resolves the current user once
  local MINE = { { key = "PE-1", summary = "a", assignee = "Me", assignee_account_id = "me1", status = "To Do" },
    { key = "PE-2", summary = "b", assignee = "Ann", assignee_account_id = "ann", status = "To Do" } }
  r = run_tui(keyseq("/", "@me", "enter"), { issues = MINE, api = { myself = function() return { accountId = "me1" } end } })
  ok(r.out:find("(1)", 1, true), "@me narrows to the current user's issues")

  -- an empty board says when resolved issues are hiding
  r = run_tui(keyseq(), { issues = { { key = "PE-1", summary = "x", status = "Done", status_category = "Done" } } })
  ok(r.out:find("(no issues · 1 resolved hidden, x shows them)", 1, true), "empty board explains hidden resolved")

  -- e menu reads as label / current value
  r = run_tui(keyseq("e", "esc"))
  ok(r.out:find("Summary             alpha root", 1, true), "e menu: summary value beside its label")
  ok(r.out:find("Priority            High", 1, true), "e menu: priority value")
  ok(r.out:find("Status              To Do", 1, true), "e menu: status value")
end

-- ---- ui.form ----
do
  local term = require("jira_tui.term")
  local ui = require("jira_tui.ui")
  local function run_form(keys, fields, values)
    local i, out = 0, {}
    local _, restore = stub(term, { size = function() return 30, 120 end, moveto = function() end,
      out = function(x) out[#out + 1] = x end,
      read_key = function() i = i + 1; if keys[i] then return keys[i] end; error("feed exhausted") end })
    local okf, res = pcall(ui.form, "T", fields, values, {})
    restore()
    return okf, res, table.concat(out)
  end
  local F = { { name = "a", label = "Alpha", kind = "text", required = true },
    { name = "b", label = "Beta", kind = "text", hint = "optional thing" },
    { name = "who", label = "Who", kind = "toggle", options = { "me", "unassigned" } } }
  local okf, res, out = run_form(keyseq(" x ", "ctrl-s"), F, { a = "", b = "", who = "me" })
  ok(okf, "form ok (" .. tostring(res) .. ")")
  eq(res and res.a, "x", "form: text trimmed on submit")
  ok(out:find("optional thing", 1, true), "form: empty field shows its hint")
  okf, res = run_form(keyseq("tab", "y", "btab", "z", "ctrl-s"), F, { a = "", b = "", who = "me" })
  eq(res and res.b, "y", "form: tab moves to the next field"); eq(res and res.a, "z", "form: shift-tab moves back")
  okf, res = run_form(keyseq("up", " ", "ctrl-s"), F, { a = "q", b = "", who = "me" })
  eq(res and res.who, "unassigned", "form: up wraps to the last field, space toggles")
  okf, res = run_form(keyseq("ctrl-s", "k", "ctrl-s"), F, { a = "", b = "", who = "me" })
  eq(res and res.a, "k", "form: blocked submit focuses the missing field")
  okf, res = run_form(keyseq("esc"), F, { a = "", b = "", who = "me" })
  ok(okf and res == nil, "form: esc on untouched form cancels")
  okf, res = run_form(keyseq("x", "esc", "y", "ctrl-s"), F, { a = "", b = "", who = "me" })
  eq(res and res.a, "xy", "form: a key after one esc disarms the discard")
end

-- ---- configurable columns + status width ----
do
  local render = require("jira_tui.render")
  local api = require("jira_tui.api")
  local function plain(x) return (x:gsub("\27%[[%d;]*m", "")) end
  local bad, berr = render.set_columns({ "key", "summary", "nope" })
  ok(bad == nil and berr:find("nope"), "set_columns: unknown column rejected")
  bad, berr = render.set_columns({ "key", "status" })
  ok(bad == nil and berr:find("required"), "set_columns: summary required")
  eq(table.concat((function() local o = {} for _, c in ipairs(render.COLUMNS) do o[#o + 1] = c.f end return o end)(), ","),
    "key,summary,assignee,created,age,status", "set_columns: failed call keeps previous columns")

  local node = { key = "PE-12", summary = string.rep("long title ", 20), assignee = "Somebody", type = "Story",
    created = "2026-01-01T00:00:00.000+0000", updated = "2026-10-01T00:00:00.000+0000", status = "In Progress",
    priority = "Medium", story_points = 3.0, labels = { "api", "perf" } }
  local configs = {
    { "key", "summary", "status" },
    { "key", "summary", "assignee", "updated", "priority", "points", "labels", "status" },
    { "key", "summary", "points", "assignee", "created", "age", "status" },
  }
  for _, cfg in ipairs(configs) do
    assert(render.set_columns(cfg))
    for _, iw in ipairs({ 100, 140, 200 }) do
      eq(ansi.width(render.issue_line(node, 1, iw, false, true)), iw, "row width == iw: " .. table.concat(cfg, ",") .. " @" .. iw)
      eq(ansi.width(render.issue_line(node, 2, iw, true, false)), iw, "child row width == iw: " .. #cfg .. " cols @" .. iw)
      eq(ansi.width(render.column_header(iw)), iw, "header width == iw: " .. #cfg .. " cols @" .. iw)
    end
    ok(ansi.width(render.issue_line(node, 1, 72, false, true)) <= 72, "narrow row fits: " .. #cfg .. " cols")
  end
  assert(render.set_columns(configs[2]))
  local wide = plain(render.issue_line(node, 1, 200, false, true))
  ok(wide:find("api,perf", 1, true) and wide:find("Medium", 1, true), "labels + priority rendered")
  ok(wide:find(" 3 ", 1, true) and not wide:find("3.0", 1, true), "points drop the trailing .0")
  local hdr = plain(render.column_header(100))
  ok(not hdr:find("Labels") and hdr:find("Status"), "narrow: rightmost optional columns drop first")

  eq(render.status_width({}), 10, "status width floor")
  eq(render.status_width({ { status = "In Progress" }, { status = "Done" } }), 13, "status width = longest + 2")
  eq(render.status_width({ { status = string.rep("x", 40) } }), 22, "status width cap")

  local log, restore = stub(api, { get_issue = function()
    return { key = "PE-7", fields = { updated = "2026-10-10T00:00:00.000+0000", labels = { "a" } } } end })
  local row = sprint.get_issue_row("PE-7")
  eq(row.updated, "2026-10-10T00:00:00.000+0000", "row maps updated")
  eq(row.labels[1], "a", "row maps labels")
  ok(table.concat(log[1][3], ","):find("updated,labels", 1, true), "row fields include updated + labels")
  restore()

  -- gs menu = active columns; sorting a list column (labels) works
  local issues = {
    { key = "PE-1", summary = "a", status = "To Do", labels = { "zeta" } },
    { key = "PE-2", summary = "b", status = "To Do", labels = { "alpha" } },
  }
  local menu
  local r = run_tui(keyseq("g", "s"), { issues = issues, ui = { select = function(_, items)
    menu = {}
    for _, c in ipairs(items) do menu[#menu + 1] = c.l end
    return items[7]
  end } })
  ok(r.ok, "labels sort ok (" .. tostring(r.err) .. ")")
  eq(table.concat(menu or {}, ","), "Key,Title,Assignee,Updated,Priority,Pts,Labels,Status", "gs menu = active columns")
  local function last_pos(needle)
    local pos, from = nil, 1
    while true do local i = r.out:find(needle, from, true); if not i then return pos end; pos, from = i, i + 1 end
  end
  ok(last_pos("PE-2") < last_pos("PE-1"), "labels sort: alpha row repainted above zeta row")

  assert(render.set_columns())
  render.COL.status = 14
end

-- ---- e menu field edits ----
do
  local api = require("jira_tui.api")
  local config = require("jira_tui.config")
  eq(model.parse_points("3"), 3, "parse_points int"); eq(model.parse_points("0.5"), 0.5, "parse_points float")
  ok(model.parse_points("x") == nil and model.parse_points("-1") == nil, "parse_points rejects junk / negative")
  eq(model.valid_key(" pe-12 "), "PE-12", "valid_key trims + uppercases")
  eq(model.valid_key("PE12"), nil, "valid_key rejects no dash")
  eq(model.valid_key("my_proj-1"), "MY_PROJ-1", "valid_key allows underscore")

  local function doc(...) return { type = "doc", content = { ... } } end
  local function p(...) return { type = "paragraph", content = { ... } } end
  local function t(x, marks) return { type = "text", text = x, marks = marks } end
  local function li(...) return { type = "listItem", content = { ... } } end
  ok(not model.adf_lossy(doc(p(t("a", { { type = "strong" } })), { type = "bulletList", content = { li(p(t("x"))) } },
    { type = "codeBlock", content = { t("c") } }, { type = "blockquote", content = { p(t("q")) } }, { type = "rule" })),
    "adf_lossy: markdown-safe doc")
  ok(not model.adf_lossy(nil) and not model.adf_lossy(false), "adf_lossy: no description")
  local lossy = {
    { "table", doc({ type = "table", content = {} }) },
    { "mention", doc(p({ type = "mention", attrs = { text = "@a" } })) },
    { "media", doc({ type = "mediaSingle", content = { { type = "media" } } }) },
    { "panel", doc({ type = "panel", content = { p(t("x")) } }) },
    { "expand", doc({ type = "expand", content = {} }) },
    { "status", doc(p({ type = "status" })) }, { "emoji", doc(p({ type = "emoji" })) },
    { "inlineCard", doc(p({ type = "inlineCard" })) }, { "taskList", doc({ type = "taskList", content = {} }) },
    { "decisionList", doc({ type = "decisionList", content = {} }) },
    { "nested list", doc({ type = "bulletList", content = { li(p(t("a")), { type = "bulletList", content = { li(p(t("b"))) } }) } }) },
    { "two marks", doc(p(t("a", { { type = "strong" }, { type = "em" } }))) },
    { "text color", doc(p(t("a", { { type = "textColor" } }))) },
  }
  for _, c in ipairs(lossy) do ok(model.adf_lossy(c[2]), "adf_lossy: " .. c[1]) end

  local row = { get_issue_row = function(key) return { key = key, summary = "alpha root", status = "To Do" } end }
  local function edit(keys, extra)
    local a = { update_issue = function() return true end,
      get_issue = function() return { key = "PE-1", fields = { description = doc(p(t("old"))) } } end,
      get_priorities = function() return { { id = "1", name = "Highest" }, { id = "3", name = "Medium" } } end }
    for k, v in pairs(extra and extra.api or {}) do a[k] = v end
    local r = run_tui(keys, { api = a, sprint = row, ui = extra and extra.ui })
    return r, calls(r.api, "update_issue")
  end
  local r, u = edit(keyseq("e", "enter", "X", "enter"))
  ok(r.ok, "edit summary ok (" .. tostring(r.err) .. ")")
  eq(u[1] and u[1][3].summary, "alpha rootX", "e summary")
  r, u = edit(keyseq("e", "j", "enter"), { ui = { edit_external = function(initial)
    return initial == "old" and "new **desc**" or nil end } })
  eq(u[1] and u[1][3].description.content[1].content[2].marks[1].type, "strong", "e description: full edit via editor")
  eq(calls(r.api, "get_issue")[1][3][1], "description", "e description: fetches description only")
  r, u = edit(keyseq("e", "j", "enter"), { api = { get_issue = function()
    return { key = "PE-1", fields = { description = doc({ type = "table", content = {} }) } } end } })
  eq(#u, 0, "e description: lossy doc refused")
  ok(r.out:find("use Append", 1, true), "e description: points to Append")
  r, u = edit(keyseq("e", "j", "j", "enter", "more", "ctrl-s"))
  eq(#u[1][3].description.content, 2, "e append: paragraph added to existing doc")
  r, u = edit(keyseq("e", "j", "j", "j", "enter", "j", "enter"))
  eq(u[1] and u[1][3].priority.id, "3", "e priority: picked id")
  r, u = edit(keyseq("e", "j", "j", "j", "j", "enter", "5", "enter"))
  eq(u[1] and u[1][3][config.get_project_config("PE").story_point_field], 5, "e points: project field")
  r, u = edit(keyseq("e", "j", "j", "j", "j", "enter", "x", "enter"))
  eq(#u, 0, "e points: junk rejected")
  ok(r.out:find("points must be a number", 1, true), "e points: error shown")
  r, u = edit(keyseq("e", "j", "j", "j", "j", "j", "enter", "a, b c", "enter"))
  eq(u[1] and table.concat(u[1][3].labels, "|"), "a|b|c", "e labels: split")
  r, u = edit(keyseq("e", "j", "j", "j", "j", "j", "j", "enter", "pe-2", "enter"))
  eq(u[1] and u[1][3].parent.key, "PE-2", "e parent: key normalized")
  r, u = edit(keyseq("e", "j", "j", "j", "j", "j", "j", "enter", "nope", "enter"))
  eq(#u, 0, "e parent: invalid key rejected")
  r, u = edit(keyseq("e", "j", "j", "j", "j", "j", "j", "j", "enter", "esc"), { api = {
    get_transitions = function() return { { id = "1", name = "x" } } end } })
  eq(#calls(r.api, "get_transitions"), 1, "e change status: opens transitions")
end

-- ---- worklog (w) ----
do
  local api = require("jira_tui.api")
  eq(model.valid_duration("1h 30m"), "1h 30m", "duration: spaced")
  eq(model.valid_duration("1H30M"), "1h 30m", "duration: compact, case-insensitive")
  eq(model.valid_duration(" 2d "), "2d", "duration: trimmed")
  eq(model.valid_duration("1w 2d 3h 4m"), "1w 2d 3h 4m", "duration: all units")
  eq(model.valid_duration("90"), nil, "duration: unit required")
  eq(model.valid_duration("1x"), nil, "duration: unknown unit")
  eq(model.valid_duration("0m"), nil, "duration: zero rejected")
  eq(model.valid_duration("1h foo"), nil, "duration: trailing junk")
  eq(model.valid_duration(""), nil, "duration: empty")

  local log, restore = stub(api, { request = function() return {} end })
  api.add_worklog("PE-1", "1m")
  eq(log[1][3], "/rest/api/3/issue/PE-1/worklog", "add_worklog endpoint")
  eq(log[1][4].timeSpent, "1m", "add_worklog body")
  restore()

  local row = { get_issue_row = function(key) return { key = key, summary = "alpha root", status = "To Do" } end }
  local r = run_tui(keyseq("w", "1h30m", "enter"), { api = { add_worklog = function() return {} end }, sprint = row })
  ok(r.ok, "w flow ok (" .. tostring(r.err) .. ")")
  local wl = calls(r.api, "add_worklog")
  eq(wl[1] and wl[1][2], "PE-1", "w: cursor row")
  eq(wl[1] and wl[1][3], "1h 30m", "w: normalized duration sent")
  ok(r.out:find("logged 1h 30m on PE-1", 1, true), "w: message")
  r = run_tui(keyseq("w", "soon", "enter"), { api = { add_worklog = function() return {} end } })
  eq(#calls(r.api, "add_worklog"), 0, "w: invalid -> no call")
  ok(r.out:find("not a duration: soon", 1, true), "w: invalid message")
  r = run_tui(keyseq("enter", "w", "5m", "enter", "q"), { sprint = row, api = {
    add_worklog = function() return {} end,
    get_issue = function() return { key = "PE-1", fields = { summary = "alpha root" } } end } })
  eq(#calls(r.api, "add_worklog"), 1, "w in detail: logged")
  ok(r.out:find("logged 5m on PE-1", 1, true), "w in detail: note")
end

-- ---- links section + L jump ----
do
  local render = require("jira_tui.render")
  local function plain(x) return (x:gsub("\27%[[%d;]*m", "")) end
  local function iss(key, summary, status) return { key = key, fields = { summary = summary, status = { name = status } } } end
  local fields = {
    summary = "alpha root", status = { name = "To Do" }, project = { key = "PE" },
    parent = iss("PE-40", "the epic", "In Progress"),
    subtasks = { iss("PE-41", "a sub", "Done") },
    issuelinks = {
      { type = { name = "Blocks", inward = "is blocked by", outward = "blocks" }, outwardIssue = iss("PE-50", "linked one", "To Do") },
      { type = { name = "Blocks", inward = "is blocked by", outward = "blocks" }, inwardIssue = iss("OPS-9", "upstream", "Review") },
    },
  }
  local rel = model.related(fields)
  local got = {}
  for _, r in ipairs(rel) do got[#got + 1] = r.rel .. ":" .. r.key end
  eq(table.concat(got, ","), "parent:PE-40,subtask:PE-41,blocks:PE-50,is blocked by:OPS-9", "related: order + link sides")
  eq(rel[3].status, "To Do", "related: status")
  eq(#model.related({}), 0, "related: none")
  local txt = plain(render.detail_text({ key = "PE-1", fields = fields }, {}, "fields", nil, { rule_w = 60 }))
  ok(txt:find("Links (4)", 1, true), "detail: links section")
  ok(txt:find("is blocked by%s+OPS%-9"), "detail: inward label")
  ok(txt:find("blocks%s+PE%-50"), "detail: outward label")
  ok(not plain(render.detail_text({ key = "X", fields = { summary = "s" } }, {}, "fields")):find("Links", 1, true),
    "detail: no links section when empty")

  local function getter(key)
    if key == "PE-1" then return { key = "PE-1", fields = fields } end
    return iss(key, key == "PE-50" and "linked one" or "other", "To Do")
  end
  local row = { get_issue_row = function(key) return { key = key, summary = "x", status = "To Do" } end }
  local r = run_tui(keyseq("enter", "L", "j", "j", "enter", "q", "q", "s", "enter"), { sprint = row, api = {
    get_issue = getter, get_transitions = function() return { { id = "5", name = "Go" } } end,
    transition_issue = function() return true end } })
  ok(r.ok, "L flow ok (" .. tostring(r.err) .. ")")
  local seen = {}
  for _, c in ipairs(calls(r.api, "get_issue")) do seen[#seen + 1] = c[2] end
  eq(table.concat(seen, ","), "PE-1,PE-50", "L: linked issue fetched, origin served from cache on q")
  local p50 = r.out:find("PE-50  linked one", 1, true)
  ok(p50, "L: linked issue title drawn")
  ok(p50 and r.out:find("PE-1  alpha root", p50, true), "L: q pops back to the origin issue")
  eq((calls(r.api, "transition_issue")[1] or {})[2], "PE-1", "L: second q returns to board, cursor unchanged")

  -- acting on a linked issue doesn't add it to the board
  r = run_tui(keyseq("enter", "L", "j", "j", "enter", "A", "q", "q"), { sprint = row, api = {
    get_issue = getter, myself = function() return { accountId = "m", displayName = "Me" } end,
    assign_issue = function() return true end } })
  ok(r.ok, "L act flow ok (" .. tostring(r.err) .. ")")
  eq((calls(r.api, "assign_issue")[1] or {})[2], "PE-50", "L: actions target the linked issue")
  ok(not r.out:find("(5)", 1, true), "L: linked issue not appended to board")

  r = run_tui(keyseq("enter", "L", "q"), { api = { get_issue = function() return iss("PE-1", "alpha root", "To Do") end } })
  ok(r.out:find("no links", 1, true), "L: no links note")
end

-- ---- gi go to issue ----
do
  eq(model.parse_issue_ref("PE-12"), "PE-12", "issue ref: key")
  eq(model.parse_issue_ref(" pe-12 "), "PE-12", "issue ref: lowercase + spaces")
  eq(model.parse_issue_ref("https://x.atlassian.net/browse/PE-12?focusedCommentId=9"), "PE-12", "issue ref: browse url")
  eq(model.parse_issue_ref("https://x.atlassian.net/browse/pe-7"), "PE-7", "issue ref: url lowercase key")
  eq(model.parse_issue_ref("hello"), nil, "issue ref: garbage")
  eq(model.parse_issue_ref("https://x.atlassian.net/jira/your-work"), nil, "issue ref: url without key")
  eq(model.parse_issue_ref(nil), nil, "issue ref: nil")

  local r = run_tui(keyseq("g", "i", "ops-77", "enter", "q", "r"), { api = { get_issue = function(key)
    return { key = key, fields = { summary = "far away", status = { name = "Done" } } } end } })
  ok(r.ok, "gi flow ok (" .. tostring(r.err) .. ")")
  eq((calls(r.api, "get_issue")[1] or {})[2], "OPS-77", "gi: fetches the parsed key")
  ok(r.out:find("OPS-77  far away", 1, true), "gi: title from fields.summary")
  eq(#r.loads, 2, "gi: no board load (only initial + r)")
  eq(r.loads[2].view, "My Issues", "gi: board view unchanged")
  r = run_tui(keyseq("g", "i", "nope", "enter"), { api = { get_issue = function() return {} end } })
  eq(#calls(r.api, "get_issue"), 0, "gi: bad ref -> no fetch")
  ok(r.out:find("not an issue key or url: nope", 1, true), "gi: bad ref message")
end

-- ---- async requests + non-blocking loads ----
do
  local api = require("jira_tui.api")
  local config = require("jira_tui.config")

  local r, e = api.parse_response('{"a":1}', 200, 0)
  eq(r and r.a, 1, "parse_response: 200 json")
  r, e = api.parse_response("", 204, 0)
  ok(r == true and e == nil, "parse_response: 204 empty -> true")
  r, e = api.parse_response('{"errorMessages":["nope"]}', 404, 0)
  ok(r == nil and e == "HTTP 404: nope", "parse_response: jira error message")
  r, e = api.parse_response("", 0, 28)
  ok(r == nil and e:find("timed out", 1, true), "parse_response: curl exit code")
  r, e = api.parse_response("<html>", 200, 0)
  ok(r == nil and e:find("failed to parse json", 1, true), "parse_response: bad json")
  r, e = api.parse_response(nil, nil, nil)
  eq(e, "curl failed to run", "parse_response: no output")

  -- real request_async / poll / cancel against a fake curl (no network)
  local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p " .. dir)
  local fake = dir .. "/fake_curl.sh"
  local f = io.open(fake, "w")
  f:write([[
out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; esac; shift; done
[ -n "$FAKE_SLEEP" ] && sleep "$FAKE_SLEEP"
printf '{"ok":true}' > "$out"; printf '__http=200'
]])
  f:close()
  local o_env, o_curl = config.options.jira, api._curl
  config.options.jira = { base = "https://x", email = "e", token = "t" }
  api._curl = "sh " .. fake
  local h = assert(api.request_async("POST", "/x", { q = 1 }))
  ok(h.pid and h.cfg and h.data, "request_async: handle with pid + temp files")
  local done, res, rerr
  for _ = 1, 100 do
    done, res, rerr = api.poll(h)
    if done then break end
    os.execute("sleep 0.05")
  end
  ok(done and type(res) == "table" and res.ok == true and rerr == nil, "poll: parsed result once curl exits")
  local left = 0
  for _, path in ipairs({ h.cfg, h.data, h.body, h.code, h.rc, h.rc .. ".tmp" }) do
    if io.open(path, "r") then left = left + 1 end
  end
  eq(left, 0, "poll: every temp file removed (incl. the -K file with the token)")
  api._curl = "FAKE_SLEEP=5 sh " .. fake
  h = assert(api.request_async("GET", "/slow"))
  eq(api.poll(h), false, "poll: false while running")
  api.cancel(h)
  local alive = os.execute("kill -0 " .. h.pid .. " 2>/dev/null")
  ok(not (alive == true or alive == 0), "cancel: subshell killed")
  left = 0
  for _, path in ipairs({ h.cfg, h.body, h.code, h.rc }) do if io.open(path, "r") then left = left + 1 end end
  eq(left, 0, "cancel: temp files removed")
  config.options.jira, api._curl = o_env, o_curl
  os.remove(fake); os.remove(dir)

  -- inside a registered coroutine, requests yield until poll lands; fetch_all pages through
  local polls = {}
  local log, restore = stub(api, {
    request_async = function(_, _, data) return { token = data.nextPageToken } end,
    poll = function(hh)
      polls[hh] = (polls[hh] or 0) + 1
      if polls[hh] < 3 then return false end
      if hh.token == "" then return true, { issues = { { key = "A-1", fields = {} } }, nextPageToken = "p2" } end
      return true, { issues = { { key = "A-2", fields = {} } } }
    end,
  })
  local co = coroutine.create(function() return sprint.get_my_issues(nil, nil) end)
  api._async[co] = true
  local yields, out = 0, nil
  while true do
    local okc, a = coroutine.resume(co)
    assert(okc, a)
    if coroutine.status(co) == "dead" then out = a; break end
    yields = yields + 1
  end
  eq(yields, 4, "async fetch_all: yields while each page is in flight (2 pages x 2)")
  eq(out and #out, 2, "async fetch_all: both pages collected")
  eq(#calls(log, "request_async"), 2, "async fetch_all: one request per page")
  restore()
  local plain_co = coroutine.create(function() return api.request("GET", "/x") end)
  local o_req_async = api.request_async
  api.request_async = function() error("must not go async outside registered coroutines") end
  local okp = coroutine.resume(plain_co)
  api.request_async = o_req_async
  ok(okp, "unregistered coroutine keeps blocking requests")

  -- tui: load in flight keeps the board live, result applies when it lands
  local function slow_loader(n_yields, rows)
    return function(view)
      if view == "My Issues" and n_yields.first then n_yields.first = false; return TUI_FIXTURE, nil end
      for i = 1, n_yields.n do coroutine.yield({ fake = i }) end
      return rows, nil
    end
  end
  local cancels = {}
  local rt = run_tui(keyseq("r", "j", "j"), { load = slow_loader({ first = true, n = 2 }, { TUI_FIXTURE[4] }),
    api = { cancel = function(hh) cancels[#cancels + 1] = hh end } })
  ok(rt.ok, "async load flow ok (" .. tostring(rt.err) .. ")")
  ok(rt.out:find("loading My Issues", 1, true), "async load: footer shows loading")
  ok(rt.out:find(" 2/4 ", 1, true), "async load: j moved the cursor on old rows while loading")
  ok(rt.out:find("(1)", 1, true), "async load: result applied when it lands")

  -- switching views mid-load cancels the old job and never applies it
  cancels = {}
  local calls_n = 0
  rt = run_tui(keyseq("r", "M"), {
    load = function()
      calls_n = calls_n + 1
      if calls_n == 2 then
        for i = 1, 5 do coroutine.yield({ fake = i }) end
        return { { key = "ZZ-1", summary = "stale" } }, nil
      end
      return TUI_FIXTURE, nil
    end,
    api = { cancel = function(hh) cancels[#cancels + 1] = hh end },
  })
  ok(rt.ok, "async supersede flow ok (" .. tostring(rt.err) .. ")")
  eq(#cancels, 1, "async supersede: in-flight handle cancelled")
  ok(not rt.out:find("ZZ-1", 1, true), "async supersede: stale result never applied")
end

-- ---- detail prefetch + auto-refresh ----
do
  local T = 1000
  local clock = function() return T end
  local getter = function(key) return { key = key, fields = { summary = "alpha root", status = { name = "To Do" } } } end
  local r = run_tui({ "tick", "tick", "tick", "tick", "enter", "q" }, { tty = true, clock = clock,
    api = { get_issue = getter } })
  ok(r.ok, "prefetch flow ok (" .. tostring(r.err) .. ")")
  local gi = calls(r.api, "get_issue")
  eq(#gi, 1, "prefetch: one fetch on idle, enter served from cache")
  eq(gi[1] and gi[1][2], "PE-1", "prefetch: cursor row")
  ok(r.out:find("PE-1  alpha root", 1, true), "prefetch: detail opens")

  r = run_tui({ "tick", "j", "tick", "j", "tick" }, { tty = true, clock = clock, api = { get_issue = getter } })
  eq(#calls(r.api, "get_issue"), 0, "prefetch: needs 2 idle ticks on the same row")

  r = run_tui({ "tick", "tick", "tick", "tick" }, { tty = true, clock = clock,
    api = { get_issue = function() return nil, "http 500" end } })
  eq(#calls(r.api, "get_issue"), 1, "prefetch: failure not retried every tick")

  local slow = 0
  r = run_tui({ "tick", "tick", "j", "k", "tick", "tick", "tick", "tick", "tick", "tick" }, { tty = true, clock = clock,
    api = { get_issue = function(key)
      slow = slow + 1
      if slow == 1 then coroutine.yield({ fake = 1 }) end
      return getter(key)
    end, cancel = function() end } })
  eq(#calls(r.api, "get_issue"), 2, "prefetch: cancelled by a key, retried once idle again")

  T = 1000
  r = run_tui({ "tick", function() T = 1200 end, "tick", function() T = 1301 end, "tick", "tick" },
    { tty = true, clock = clock, refresh_interval = 300, api = { get_issue = getter } })
  ok(r.ok, "auto-refresh flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 2, "auto-refresh: reloads once after the interval")
  ok(r.out:find("updated 3m ago", 1, true), "auto-refresh: footer age before reload")
  ok(r.out:find("updated 0m ago", 1, true), "auto-refresh: footer resets after reload")

  T = 1000
  r = run_tui({ "j", "tick", function() T = 1400 end, "tick", "tick" }, { tty = true, clock = clock,
    refresh_interval = 300, api = { get_issue = getter } })
  eq(#r.loads, 2, "auto-refresh: fires")
  ok(r.out:find(" 2/4 ", 1, true), "auto-refresh: cursor kept on the same row")
  r = run_tui({ "tick", function() T = 99999 end, "tick" }, { tty = true, clock = clock, api = { get_issue = getter } })
  eq(#r.loads, 1, "auto-refresh: off without refresh_interval")
end

-- ---- Esc semantics ----
do
  local r = run_tui(keyseq("esc", "r"))
  ok(r.ok, "esc flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 2, "esc: single Esc keeps running")
  ok(r.out:find("Esc again to quit", 1, true), "esc: arms with a message")
  r = run_tui(keyseq("esc", "esc", "r"))
  eq(#r.loads, 1, "esc: double Esc quits")
  r = run_tui(keyseq("esc", "j", "esc", "r"))
  eq(#r.loads, 2, "esc: another key disarms")
  r = run_tui(keyseq("/", "delta", "enter", "esc", "r"))
  eq(#r.loads, 2, "esc: with a filter, clears it and keeps running")
  local p1 = r.out:find("(1)", 1, true)
  ok(p1 and r.out:find("(4)", p1, true), "esc: filter cleared (count back to 4)")
  r = run_tui(keyseq("w", "zz", "enter", "esc", "esc", "r"))
  eq(#r.loads, 2, "esc: first clears a message, second arms")
  local cancelled = 0
  local n = 0
  r = run_tui(keyseq("r", "esc", "esc", "r"), {
    load = function()
      n = n + 1
      if n == 2 then for i = 1, 9 do coroutine.yield({ fake = i }) end end
      return TUI_FIXTURE, nil
    end,
    api = { cancel = function() cancelled = cancelled + 1 end } })
  ok(r.out:find("load cancelled", 1, true), "esc: cancels a running load")
  eq(cancelled, 1, "esc: in-flight handle cancelled")
  eq(#r.loads, 3, "esc: cancel then arm, app still running")
  r = run_tui(keyseq("ctrl-c", "r"))
  eq(#r.loads, 1, "ctrl-c: instant quit")
end

-- ---- mouse click ----
do
  -- 30x120 harness: board top = 1, body starts on screen row 6. flat: PE-1, spacer, PE-2, PE-3, spacer, PE-4
  local tr = { get_transitions = function() return { { id = "1", name = "Go" } } end, transition_issue = function() return true end }
  local row = { get_issue_row = function(key) return { key = key, summary = "x", status = "To Do" } end }
  local function target(click_row)
    local r = run_tui({ { "click", row = click_row }, "s", "enter" }, { api = tr, sprint = row })
    return (calls(r.api, "transition_issue")[1] or {})[2]
  end
  eq(target(11), "PE-4", "click selects the clicked row")
  eq(target(9), "PE-3", "click selects a child row")
  eq(target(7), "PE-1", "click on a spacer leaves the cursor")
  eq(target(3), "PE-1", "click on the tab bar leaves the cursor")
  eq(target(25), "PE-1", "click below the rows leaves the cursor")
  require("jira_tui.term").mouse = nil
end

-- ---- search inside detail ----
do
  local term = require("jira_tui.term")
  local ui = require("jira_tui.ui")
  local buf = {}
  for i = 1, 100 do buf[i] = "line " .. i .. ((i == 40 or i == 80) and " has FOO here" or "") end
  local text = table.concat(buf, "\n")
  local function run(keys)
    local i, row, at = 0, nil, {}
    local out = {}
    local _, restore = stub(term, {
      size = function() return 30, 120 end,
      moveto = function(r) row = r end,
      out = function(x) out[#out + 1] = x; if row then at[row] = x end end,
      read_key = function() i = i + 1; if keys[i] then return keys[i] end; error("feed exhausted") end,
    })
    local okd, derr = pcall(ui.detail, "T", text, {})
    restore()
    return okd, derr, at, table.concat(out)
  end
  -- 30 rows: popup top = 1, body rows on screen 2..27 (26 lines)
  local okd, derr, at, out = run(keyseq("/", "foo", "enter", "q"))
  ok(okd, "detail search ok (" .. tostring(derr) .. ")")
  ok(ansi.strip(at[2] or ""):find("line 40 has FOO", 1, true), "detail /: scrolls the first match to the top")
  ok(out:find("match 1/2", 1, true), "detail /: footer match count")
  local _
  _, _, at, out = run(keyseq("/", "foo", "enter", "n", "q"))
  ok(out:find("match 2/2", 1, true), "detail n: next match")
  ok(ansi.strip(at[2] or ""):find("line 75", 1, true), "detail n: scroll clamps at the bottom")
  _, _, at, out = run(keyseq("/", "foo", "enter", "n", "n", "q"))
  ok(ansi.strip(at[2] or ""):find("line 40 has FOO", 1, true), "detail n: wraps to the first match")
  _, _, at = run(keyseq("/", "foo", "enter", "N", "q"))
  ok(ansi.strip(at[2] or ""):find("line 75", 1, true), "detail N: wraps backwards to the last match")
  _, _, at, out = run(keyseq("G", "/", "foo", "enter", "q"))
  ok(out:find("match 2/2", 1, true), "detail /: starts from the current scroll position")
  _, _, _, out = run(keyseq("/", "zzz", "enter", "n", "q"))
  ok(out:find("no match: zzz", 1, true), "detail /: no match note")
end

-- ---- help overlay scrolls ----
do
  local ui = require("jira_tui.ui")
  local r = run_tui(keyseq("?"))
  ok(r.ok, "help flow ok (" .. tostring(r.err) .. ")")
  ok(r.out:find("This help", 1, true) == nil, "help: bottom rows past a 30-row screen aren't drawn")
  ok(r.out:find("j/k scroll   q / Esc / ? close   lines 1-22 of " .. #ui.help_lines(116), 1, true), "help: footer position")
  r = run_tui(keyseq("?", "G"))
  ok(r.out:find("Quit now", 1, true), "help: G scrolls to the last row")
  r = run_tui(keyseq("?", "G", "g", "j"))
  ok(r.out:find("lines 2-23", 1, true), "help: g back to top, j scrolls one")
  r = run_tui(keyseq("?", "G", "q", "?"))
  ok(r.out:find("lines 1-22", 1, true), "help: reopening starts at the top")
  r = run_tui(keyseq("?", "q", "r"))
  eq(#r.loads, 2, "help: q closes, board keys work again")
  local keys = {}
  for _, l in ipairs(ui.help_lines(116)) do keys[#keys + 1] = ansi.strip(l) end
  local txt = table.concat(keys, "\n")
  for _, k in ipairs({ "1-9", "gc", "gi", "] / [", "/ n N", "Esc Esc", "Ctrl-c", "s a A e d C w", "y Y b", "L ", "P ", "@me",
    "Shift-Tab" }) do
    ok(txt:find(k, 1, true), "help lists " .. k)
  end
  for _, l in ipairs(ui.help_lines(76)) do ok(ansi.width(l) <= 76, "help line fits 80 cols") end
end

-- ---- row patch after mutations ----
do
  local raw = { { key = "A-1", summary = "a" }, { key = "A-2", summary = "b" } }
  eq(model.upsert_row(raw, { key = "A-2", summary = "B" }), 2, "upsert replaces in place")
  eq(raw[2].summary, "B", "upsert replaced row")
  eq(#raw, 2, "upsert replace keeps length")
  eq(model.upsert_row(raw, { key = "A-3", summary = "c" }), 3, "upsert appends new key")
  eq(raw[3].key, "A-3", "appended row")

  local api = require("jira_tui.api")
  local log, restore = stub(api, { get_issue = function(key)
    if key == "PE-9" then return nil, "http 404" end
    return { key = "PE-7", fields = { summary = "s", status = { name = "Done" } } }
  end })
  local row = sprint.get_issue_row("PE-7")
  eq(row and row.key, "PE-7", "get_issue_row maps the row")
  eq(row and row.status, "Done", "get_issue_row maps status")
  eq(log[1][2], "PE-7", "get_issue_row reads the issue directly (search lags writes)")
  ok(table.concat(log[1][3], ","):find("issuetype", 1, true), "get_issue_row asks for row fields only")
  local none, nerr = sprint.get_issue_row("PE-9")
  ok(none == nil and nerr == "http 404", "get_issue_row: error passed through")
  restore()

  -- assign patches one row, no view reload
  local rowfn = function(key) return { key = key, summary = "alpha root", status = "To Do", assignee = "Zed" } end
  local r = run_tui(keyseq("A"), {
    api = { myself = function() return { accountId = "me1", displayName = "Zed" } end,
      assign_issue = function() return true end },
    sprint = { get_issue_row = rowfn },
  })
  ok(r.ok, "assign flow ok (" .. tostring(r.err) .. ")")
  eq(#calls(r.sprint, "get_issue_row"), 1, "assign: one get_issue_row")
  eq((calls(r.sprint, "get_issue_row")[1] or {})[2], "PE-1", "assign: refreshes the assigned key")
  eq(#r.loads, 1, "assign: zero extra opts.load calls")
  ok(r.out:find("Zed", 1, true), "assign: patched assignee drawn")

  -- refresh failure keeps rows and says so instead of a bare success
  r = run_tui(keyseq("A"), {
    api = { myself = function() return { accountId = "me1" } end, assign_issue = function() return true end },
    sprint = { get_issue_row = function() return nil, "boom" end },
  })
  ok(r.out:find("row refresh failed: boom", 1, true), "assign: refresh error surfaced")
  ok(r.out:find("alpha root", 1, true), "assign: rows kept on refresh failure")

  -- create appends the new row
  r = run_tui(keyseq("c", "new thing", "ctrl-s"), {
    api = { myself = function() return { accountId = "me1" } end,
      get_create_types = function() return { { id = "1", name = "Story", subtask = false } } end,
      create_issue = function() return { key = "PE-99" } end },
    sprint = { get_issue_row = function(key) return { key = key, summary = "new thing", status = "To Do" } end },
  })
  ok(r.ok, "create flow ok (" .. tostring(r.err) .. ")")
  eq(#r.loads, 1, "create: no full reload")
  ok(r.out:find("(5)", 1, true), "create: new row appended (count 5)")
  ok(r.out:find("created PE-99", 1, true), "create: message names new key")
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
