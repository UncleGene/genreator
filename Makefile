LUA ?= luajit
PLUGIN := Genreator.lrplugin
LR_PLUGIN_DIR := $(HOME)/Library/Application Support/Adobe/Lightroom/Modules

.PHONY: test lint install uninstall clean help model model-verify encoder encoder-zip release

MODEL_TOOL := $(LUA) tools/model.lua
REPO := UncleGene/genreator

help:
	@echo "make test      Run the offline test suite (no Lightroom, no network)"
	@echo "make lint      Byte-compile every Lua file to catch syntax errors"
	@echo "make install   Symlink the plugin into Lightroom's Modules folder"
	@echo "make uninstall Remove the symlink"
	@echo "make model FROM=<folder> [KEYWORDS=<folder>]  Import a model folder (and its keyword model) into the bundle"
	@echo "make model-verify          Check every bundled model file against the manifest"
	@echo "make encoder               Download the encoder (a release asset) if missing"
	@echo "make encoder-zip           Package the encoder for a release (maintainers)"
	@echo "make release               Package the whole plugin for a release (maintainers)"

test:
	@$(LUA) tests/run.lua

# Syntax check. Catches Lua 5.3-only syntax that Lightroom's 5.1.4 would reject.
lint:
	@fail=0; \
	for f in $(PLUGIN)/*.lua tests/*.lua tests/stub/*.lua tools/*.lua; do \
		$(LUA) -bl "$$f" >/dev/null 2>/tmp/gr-lint.err || { \
			echo "SYNTAX ERROR in $$f"; cat /tmp/gr-lint.err; fail=1; }; \
	done; \
	[ $$fail -eq 0 ] && echo "lint: all files parse under $$($(LUA) -v 2>&1 | head -1)"; \
	exit $$fail

install: encoder
	@mkdir -p "$(LR_PLUGIN_DIR)"
	@rm -rf "$(LR_PLUGIN_DIR)/$(PLUGIN)"
	@ln -s "$(CURDIR)/$(PLUGIN)" "$(LR_PLUGIN_DIR)/$(PLUGIN)"
	@echo "Linked $(PLUGIN) into $(LR_PLUGIN_DIR)"
	@echo "Restart Lightroom Classic, then check Plug-in Manager."
	@echo "Note: Lightroom does not pick up files added to a plugin folder while running."

# The model files are committed except the encoder, which is larger than GitHub allows in
# git and is published as a release asset tagged by its id.
model:
	@$(MODEL_TOOL) import "$(FROM)" "$(KEYWORDS)"

model-verify:
	@$(MODEL_TOOL) verify

# The release asset is downloaded over HTTPS; if that fails (a private copy of the
# repository), a signed-in `gh` CLI is tried.
encoder:
	@id=$$($(MODEL_TOOL) encoder-id) && \
	if $(MODEL_TOOL) encoder-ok; then echo "Encoder $$id already present"; else \
	  $(MODEL_TOOL) fetch-encoder "https://github.com/$(REPO)/releases/download/encoder-$$id/$$id.mlmodelc.zip" || \
	  if command -v gh >/dev/null; then echo "Trying again with the GitHub CLI" && mkdir -p dist && \
	    gh release download "encoder-$$id" -R $(REPO) -p "$$id.mlmodelc.zip" -O "dist/$$id.mlmodelc.zip" --clobber && \
	    $(MODEL_TOOL) fetch-encoder "file://$(CURDIR)/dist/$$id.mlmodelc.zip"; \
	  else echo "Download failed. For a private repository, install the GitHub CLI and sign in (gh auth login)."; exit 1; fi; fi

encoder-zip:
	@id=$$($(MODEL_TOOL) encoder-id) && \
	$(MODEL_TOOL) encoder-zip "dist/$$id.mlmodelc.zip" && \
	echo "Publish: gh release create encoder-$$id -R $(REPO) dist/$$id.mlmodelc.zip"

uninstall:
	@rm -rf "$(LR_PLUGIN_DIR)/$(PLUGIN)"
	@echo "Removed $(PLUGIN) from $(LR_PLUGIN_DIR)"

# Lightroom's temp path on macOS is the per-user $TMPDIR (/var/folders/.../T), not /tmp.
# Lists what it removes, so "the temp directory is gone" (development.md) is observable.
clean:
	@found=$$(ls -d "$${TMPDIR:-/tmp}"/genreator-* /tmp/genreator-* 2>/dev/null); \
	if [ -n "$$found" ]; then echo "Removing:"; echo "$$found"; rm -rf $$found; \
	else echo "No rendition temp directories found"; fi

# The release users install (ADR-026): the plugin folder with the encoder, as one zip.
release: encoder
	@$(MODEL_TOOL) plugin-zip dist && \
	echo "Publish: gh release create v<version> -R $(REPO) <the zip above>, <version> as in its name"
