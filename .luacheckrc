std = "max" -- lua5.x + luajit globals
max_line_length = false

-- vendored third-party json -- don't lint upstream code
exclude_files = { "lua/jira_tui/json.lua" }

-- entry script reads the global arg table
files["bin/jira-tui"] = { read_globals = { "arg" } }

-- the tui harness mutes io.stderr so a crash line doesn't spam the test output
files["test/run.lua"] = { ignore = { "122/io" } }

-- keep real signal (undefined globals 1xx, logic 5xx); mute style/unused/shadowing
ignore = {
  "21.", -- unused local / argument / loop var
  "31.", -- value assigned but never accessed
  "4..", -- shadowing / redefinition
  "542", -- empty if branch
  "6..", -- whitespace / line length / formatting
}
