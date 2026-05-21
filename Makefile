# Makefile for the /claude-markdown-health-check command
#
# `make install`    — install the command, its references, and the validator into ~/.claude/
# `make uninstall`  — remove the installed command + reference tree
# `make check-self` — install, then remind you to run /claude-markdown-health-check

CLAUDE_DIR  := $(HOME)/.claude
CMD_SRC     := commands/claude-markdown-health-check.md
CMD_DEST    := $(CLAUDE_DIR)/commands/claude-markdown-health-check.md
REF_SRC     := commands/claude-markdown-health-check/references
REF_DEST    := $(CLAUDE_DIR)/claude-markdown-health-check/references
SCRIPT_SRC  := commands/scripts/validate-skills.sh
SCRIPT_DEST := $(CLAUDE_DIR)/commands/scripts/validate-skills.sh

.PHONY: install uninstall check-self help

help:
	@echo "Targets:"
	@echo "  install     install command + references + validator into ~/.claude/"
	@echo "  uninstall   remove the installed command + reference tree"
	@echo "  check-self  install, then run /claude-markdown-health-check in Claude Code"

install:
	@mkdir -p "$(CLAUDE_DIR)/commands/scripts" "$(REF_DEST)"
	@cp "$(CMD_SRC)" "$(CMD_DEST)"
	@cp "$(REF_SRC)"/*.md "$(REF_DEST)/"
	@cp "$(SCRIPT_SRC)" "$(SCRIPT_DEST)"
	@chmod +x "$(SCRIPT_DEST)"
	@echo "Installed:"
	@echo "  $(CMD_DEST)"
	@echo "  $(REF_DEST)/"
	@echo "  $(SCRIPT_DEST)"

uninstall:
	@rm -f "$(CMD_DEST)"
	@rm -rf "$(CLAUDE_DIR)/claude-markdown-health-check"
	@echo "Removed: $(CMD_DEST)"
	@echo "Removed: $(CLAUDE_DIR)/claude-markdown-health-check/"
	@echo "Left in place (shared dir): $(SCRIPT_DEST)"

check-self: install
	@echo "Now run /claude-markdown-health-check inside Claude Code."
