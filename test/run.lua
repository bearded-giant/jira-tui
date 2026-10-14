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

-- ---- launch contract (README: no args -> My Issues, PROJECT -> Active Sprint) ----
do
  local init = require("jira_tui.init")
  local l = init.resolve_launch({}, nil)
  eq(l.view, "My Issues", "no args -> My Issues"); eq(l.project, nil, "no args, no project")
  l = init.resolve_launch({}, "SEC")
  eq(l.view, "My Issues", "no args ignores last_view; still My Issues"); eq(l.project, "SEC", "last project seeds S/B")
  l = init.resolve_launch({ "ref" }, "SEC")
  eq(l.view, "Active Sprint", "project arg forces Active Sprint"); eq(l.project, "REF", "project arg uppercased, beats last")
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

  local bar = plain(render.tab_bar("My Issues", { ["Active Sprint"] = true, ["Backlog"] = true }, 100))
  ok(bar:find("My Issues") and bar:find("JQL") and bar:find("Help"), "tab bar has visible tabs")
  ok(not bar:find("Active Sprint") and not bar:find("Backlog"), "hidden tabs dropped")
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
  ok(render.tab_bar(render.view_label("JQL:project = X"), {}, 100):find(active_jql, 1, true), "JQL tab highlighted for a JQL:<q> view")
  ok(not render.tab_bar(render.view_label("My Issues"), {}, 100):find(active_jql, 1, true), "JQL tab plain on My Issues")

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

  local adf = api.text_to_adf("line one\n\nline two")
  eq(adf.type, "doc", "text_to_adf builds a doc")
  eq(#adf.content, 3, "two lines + blank = 3 paragraphs")
  eq(adf.content[1].content[1].text, "line one", "first paragraph text")
  eq(#adf.content[2].content, 0, "blank line = empty paragraph")
  ok(json.encode(adf.content[2].content) == "[]", "empty paragraph encodes as [], not {}")
  eq(api.text_to_adf(""), nil, "empty text -> nil adf")

  local appended = api.append_to_adf(adf, "line three")
  eq(#appended.content, 4, "append adds a paragraph")
  eq(appended.content[4].content[1].text, "line three", "appended text")
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

  local t, d = model.split_create_input("my title\n---\nbody line\nmore")
  eq(t, "my title", "title above ---")
  eq(d, "body line\nmore", "description below ---")
  t, d = model.split_create_input("just a title")
  eq(t, "just a title", "title only, no ---")
  eq(d, nil, "no description without body")
  t, d = model.split_create_input("title\nrest without marker")
  eq(t, "title", "first line is title without ---")
  eq(d, "rest without marker", "rest becomes description")
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
  f, n = after("\27[<0;10;5Ma"); eq(f, nil, "mouse click swallowed"); eq(n, "a", "byte after click intact")
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

  local q = plain(mdr.to_ansi("> quoted one> quoted two"))
  ok(q:find("│ quoted one", 1, true) and q:find("│ quoted two", 1, true), "adf-collapsed quote split into rows")

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
for k in ("enter esc tab bs del ctrl-s ctrl-c ctrl-d ctrl-u up down left right home end pgup pgdn wheelup wheeldown")
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
-- opts.sprint: stub fns for jira_tui.sprint. opts.state: persist fake (fake_state()).
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
    isatty = function() return false end,
    read_key = function()
      i = i + 1
      if keys[i] then return keys[i] end
      if exhausted then error("feed exhausted") end
      exhausted = true
      return nil
    end,
  })
  local api_log, restore_api = stub(api, opts.api or {})
  local sprint_log, restore_sprint = stub(require("jira_tui.sprint"), opts.sprint or {})
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
    hidden_tabs = {},
    state = opts.state,
  })
  io.stderr = o_stderr
  restore_api(); restore_sprint(); restore_term()
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

-- ---- row patch after mutations ----
do
  local raw = { { key = "A-1", summary = "a" }, { key = "A-2", summary = "b" } }
  eq(model.upsert_row(raw, { key = "A-2", summary = "B" }), 2, "upsert replaces in place")
  eq(raw[2].summary, "B", "upsert replaced row")
  eq(#raw, 2, "upsert replace keeps length")
  eq(model.upsert_row(raw, { key = "A-3", summary = "c" }), 3, "upsert appends new key")
  eq(raw[3].key, "A-3", "appended row")

  local api = require("jira_tui.api")
  local log, restore = stub(api, { search_issues = function(jql)
    if jql == "key = PE-9" then return { issues = {} } end
    return { issues = { { key = "PE-7", fields = { summary = "s", status = { name = "Done" } } } } }
  end })
  local row = sprint.get_issue_row("PE-7")
  eq(row and row.key, "PE-7", "get_issue_row maps the row")
  eq(row and row.status, "Done", "get_issue_row maps status")
  eq(log[1][2], "key = PE-7", "get_issue_row queries by key")
  eq(log[1][6], "PE", "get_issue_row derives project from key")
  local none, nerr = sprint.get_issue_row("PE-9")
  ok(none == nil and nerr == "not found", "get_issue_row: missing key -> nil, not found")
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
