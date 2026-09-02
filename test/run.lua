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
  ok(plain(render.hint_line("x", nil, 60)):find("q quit", 1, true), "narrow hint keeps q quit")
end

-- ---- status badge colors ----
do
  local render = require("jira_tui.render")
  eq(render.status_bg("To Do"), ansi.color.blue, "jira 'To Do' (with space) gets the todo color")
  eq(render.status_bg("TODO"), ansi.color.blue, "TODO")
  eq(render.status_bg("In Progress"), ansi.color.yellow, "In Progress")
  eq(render.status_bg("Ready for QA"), ansi.color.surface, "Ready for wins over QA")
  eq(render.status_bg("Done"), ansi.color.green, "Done")
  eq(render.status_bg(nil), ansi.color.surface, "nil -> default")
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

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
