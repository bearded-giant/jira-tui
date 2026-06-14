LUA ?= luajit
PREFIX ?= $(HOME)/.local
ARGS ?=

.PHONY: help test test-all lint check run install uninstall build screenshots

help: ## show targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

test: ## run tests on $(LUA)  (override: make test LUA=lua)
	$(LUA) test/run.lua

test-all: ## run tests on luajit and lua
	luajit test/run.lua
	lua test/run.lua

lint: ## luacheck (needs: luarocks install luacheck)
	luacheck lua bin test

check: lint test ## lint + test

run: ## run the tui  (make run ARGS="REF --backlog")
	./bin/jira-tui $(ARGS)

install: ## symlink launcher into $(PREFIX)/bin
	@mkdir -p $(PREFIX)/bin
	ln -sf "$(CURDIR)/bin/jira-tui" "$(PREFIX)/bin/jira-tui"
	@echo "linked $(PREFIX)/bin/jira-tui"

uninstall: ## remove the symlink
	rm -f "$(PREFIX)/bin/jira-tui"

build: ## (none -- pure lua)
	@echo "pure lua, nothing to build. run 'make check'."

screenshots: ## render TUI views to screenshots/*.png (needs vhs + JIRA_* env)
	vhs screenshots/jira-tui.tape
