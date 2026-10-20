# MaxTimeInServer - weekly connected-time quota for a Project Zomboid B42 server.
#
# Nothing here ever restarts the game server on its own: `make restart` is a
# separate, deliberate step.

SERVER      ?= server-local
SSH         ?= ssh -o BatchMode=yes -o ConnectTimeout=8 $(SERVER)
MOD_ID      ?= MaxTimeInServer
WORLD       ?= Zomboides2

ZOMBOID     ?= $$HOME/Zomboid

# The game's user folder on THIS machine, for install-client.
CLIENT_ZOMBOID ?= $(HOME)/Zomboid
WORKSHOP_DIR   ?= $(CLIENT_ZOMBOID)/Workshop/$(MOD_ID)
MODS_DIR    ?= $(ZOMBOID)/mods
CONSOLE     ?= $(ZOMBOID)/server-console.txt
# The counter file is named after the server.
DATA_FILE   ?= $(ZOMBOID)/Lua/MaxTimeInServer_$(WORLD).txt
DB_FILE     ?= $(ZOMBOID)/db/$(WORLD).db
SERVER_INI  ?= $(ZOMBOID)/Server/$(WORLD).ini

MOD_FILES   = 42 common

.PHONY: help test deploy package restart status logs data roles ini \
        handout install-client verify-client demo-block demo-restore sandbox uninstall

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t24

test: ## Run the Lua test suite locally
	@./tests/run.sh

deploy: test ## Copy the mod to the server (does not restart it)
	@# COPYFILE_DISABLE keeps macOS from shipping ._AppleDouble files, which the
	@# game would try to load as Lua.
	@COPYFILE_DISABLE=1 tar --no-xattrs -cf - $(MOD_FILES) | $(SSH) 'rm -rf $(MODS_DIR)/$(MOD_ID) && mkdir -p $(MODS_DIR)/$(MOD_ID) && tar xf - -C $(MODS_DIR)/$(MOD_ID) && find $(MODS_DIR)/$(MOD_ID) -name "._*" -delete'
	@$(SSH) 'find $(MODS_DIR)/$(MOD_ID) -type f | sort'
	@echo "Deployed. Add $(MOD_ID) to the Mods= line and restart when you are ready."

verify-sync: ## Check the server's copy of the mod matches this working tree
	@# The server hashes the mod's Lua when it boots and kicks clients whose
	@# copies disagree, so the zip handed to players must be the same bytes the
	@# server actually booted with. LC_ALL=C on both sides because macOS and
	@# Linux order "PT/" against "PTBR/" differently otherwise, which looks
	@# exactly like a mismatch and is not one.
	@find $(MOD_FILES) -type f | LC_ALL=C sort | xargs md5 -r | sed 's|^\([a-f0-9]*\) |\1  |' > /tmp/mts-local.txt
	@if ! $(SSH) 'test -d $(MODS_DIR)/$(MOD_ID)'; then \
		echo "the server has no copy of the mod installed - nothing to compare against"; \
		exit 0; fi; \
		$(SSH) 'cd $(MODS_DIR)/$(MOD_ID) && find . -type f | LC_ALL=C sort | xargs md5sum | sed "s|\./||"' > /tmp/mts-remote.txt; \
		if diff -u /tmp/mts-local.txt /tmp/mts-remote.txt; then echo "in sync"; else \
			echo; echo "OUT OF SYNC - run 'make deploy' and restart, or the players' copies will"; \
			echo "fail the server's Lua checksum and be kicked at the connection screen."; exit 1; fi

package: test ## Build the mod archive from this working tree
	@# Deliberately independent of any server: this is the mod as it would be
	@# published. While it is unpublished and copied by hand, use `handout`.
	@rm -rf build && mkdir -p build/$(MOD_ID)
	@COPYFILE_DISABLE=1 tar --no-xattrs -cf - $(MOD_FILES) | tar xf - -C build/$(MOD_ID)
	@cd build && zip -qr $(MOD_ID).zip $(MOD_ID)
	@echo "build/$(MOD_ID).zip - the mod, as it would be published"
	@unzip -l build/$(MOD_ID).zip | tail -3

handout: verify-sync package ## Build the archive to hand out while the mod is unpublished
	@echo
	@echo "Safe to hand out: the server booted these same files, so these copies"
	@echo "will pass its Lua checksum."

workshop: test ## Build the Steam Workshop upload folder in your Zomboid dir
	@# The game wants an exact shape, and it checks it when you press submit:
	@#   <item>/preview.png        256x256, PNG, at most 1000KB
	@#   <item>/workshop.txt       version, title, description lines, tags
	@#   <item>/Contents/mods/<mod>/...
	@# Only buildings/, creative/ and mods/ may sit in Contents/, nothing loose,
	@# and no .exe .dll .bat .app .dylib .sh .so .zip anywhere in it.
	@test -d "$(CLIENT_ZOMBOID)" || { echo "no $(CLIENT_ZOMBOID) here - set CLIENT_ZOMBOID to your game's user folder"; exit 1; }
	@mkdir -p "$(WORKSHOP_DIR)"
	@rm -rf "$(WORKSHOP_DIR)/Contents/mods/$(MOD_ID)"
	@mkdir -p "$(WORKSHOP_DIR)/Contents/mods/$(MOD_ID)"
	@COPYFILE_DISABLE=1 tar --no-xattrs -cf - $(MOD_FILES) | tar xf - -C "$(WORKSHOP_DIR)/Contents/mods/$(MOD_ID)"
	@find "$(WORKSHOP_DIR)/Contents/mods/$(MOD_ID)" -name "._*" -delete
	@# The words come from this repo, so a correction here reaches the page. The
	@# two lines Steam and the submit screen own - the item id and the chosen
	@# visibility - are carried over from whatever is already there.
	@f="$(WORKSHOP_DIR)/workshop.txt"; \
	keep=$$(grep -E '^(id|visibility)=' "$$f" 2>/dev/null || true); \
	if [ -n "$$keep" ]; then \
		grep -vE '^(id|visibility)=' workshop/workshop.txt > "$$f.new"; \
		printf '%s\n' "$$keep" >> "$$f.new"; \
		mv "$$f.new" "$$f"; \
		echo "workshop.txt rewritten, keeping $$(printf '%s' "$$keep" | tr '\n' ' ')"; \
	else \
		cp workshop/workshop.txt "$$f"; \
		echo "wrote workshop.txt from workshop/workshop.txt"; \
	fi
	@if [ ! -f "$(WORKSHOP_DIR)/preview.png" ]; then \
		sips -z 256 256 42/poster.png --out "$(WORKSHOP_DIR)/preview.png" >/dev/null; \
		echo "wrote preview.png - the poster scaled to 256x256, replace it with something drawn for the size"; \
	else echo "kept the preview.png already there"; fi
	@$(MAKE) --no-print-directory workshop-check

workshop-check: ## Check the upload folder against the rules the game enforces
	@fail=0; \
	d="$(WORKSHOP_DIR)"; \
	test -f "$$d/workshop.txt" || { echo "MISSING $$d/workshop.txt"; fail=1; }; \
	if [ -f "$$d/preview.png" ]; then \
		size=$$(sips -g pixelWidth -g pixelHeight "$$d/preview.png" | awk '/pixel/ {print $$2}' | paste -sd x -); \
		bytes=$$(wc -c < "$$d/preview.png"); \
		[ "$$size" = "256x256" ] || { echo "preview.png is $$size, must be 256x256"; fail=1; }; \
		[ "$$bytes" -le 1024000 ] || { echo "preview.png is $$bytes bytes, must be at most 1024000"; fail=1; }; \
	else echo "MISSING $$d/preview.png"; fail=1; fi; \
	ls "$$d/Contents" | grep -qvE '^(buildings|creative|mods)$$' && { echo "only buildings/ creative/ mods/ may be in Contents/"; fail=1; }; \
	find "$$d/Contents" -maxdepth 1 -type f | grep -q . && { echo "no loose files allowed in Contents/"; fail=1; }; \
	find "$$d/Contents/mods" -maxdepth 1 -type f | grep -q . && { echo "no loose files allowed in Contents/mods/"; fail=1; }; \
	bad=$$(find "$$d" \( -name "*.exe" -o -name "*.dll" -o -name "*.bat" -o -name "*.app" -o -name "*.dylib" -o -name "*.sh" -o -name "*.so" -o -name "*.zip" -o -name "._*" \) | head -5); \
	[ -z "$$bad" ] || { echo "file types the Workshop refuses:"; echo "$$bad"; fail=1; }; \
	test -f "$$d/Contents/mods/$(MOD_ID)/42/mod.info" || { echo "MISSING 42/mod.info"; fail=1; }; \
	if [ "$$fail" = "0" ]; then \
		echo "ready to upload: $$d"; \
		echo "  $$(find "$$d/Contents" -type f | wc -l | tr -d ' ') files in Contents/, $$(grep -c '^description=' "$$d/workshop.txt") lines of description"; \
	else echo; echo "NOT ready - fix the above and run make workshop again"; exit 1; fi

install-client: test verify-sync ## Install the mod into the game on THIS machine
	@test -d "$(CLIENT_ZOMBOID)" || { echo "no $(CLIENT_ZOMBOID) here - set CLIENT_ZOMBOID to your game's user folder"; exit 1; }
	@rm -rf "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)"
	@mkdir -p "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)"
	@COPYFILE_DISABLE=1 tar --no-xattrs -cf - $(MOD_FILES) | tar xf - -C "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)"
	@find "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)" -name "._*" -delete
	@echo "installed into $(CLIENT_ZOMBOID)/mods/$(MOD_ID)"

verify-client: ## Check this machine's copy matches the server's, byte for byte
	@cd "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)" && find . -type f | LC_ALL=C sort | xargs md5 -r \
		| sed 's|^\([a-f0-9]*\) ./|\1  |' > /tmp/mts-client.txt
	@$(SSH) 'cd $(MODS_DIR)/$(MOD_ID) && find . -type f | LC_ALL=C sort | xargs md5sum | sed "s|\./||"' > /tmp/mts-server.txt
	@if diff -u /tmp/mts-client.txt /tmp/mts-server.txt; then echo "identical to the server"; else \
		echo; echo "DIFFERENT - this client would be kicked on the Lua checksum"; exit 1; fi

restart: ## Restart the game server (asks nothing, so run it on purpose)
	@$(SSH) 'systemctl --user restart zomboid.service'
	@$(SSH) 'systemctl --user is-active zomboid.service'

status: ## Service status
	@$(SSH) 'systemctl --user is-active zomboid-panel zomboid zomboid-backup.timer'

logs: ## Last MaxTimeInServer lines from the server console
	@$(SSH) 'grep -a "\[MaxTimeInServer" $(CONSOLE) | tail -40 || echo "(no MaxTimeInServer lines yet)"'

data: ## Show the counter file (wherever the engine put it)
	@$(SSH) 'f=$$(find $(ZOMBOID) -maxdepth 2 -name "MaxTimeInServer*.txt" 2>/dev/null | head -5); \
		if [ -n "$$f" ]; then for x in $$f; do echo "== $$x"; cat "$$x"; done; \
		else echo "(no MaxTimeInServer*.txt under $(ZOMBOID) yet)"; fi'

roles: ## Show every account and the role it currently holds
	@$(SSH) 'python3 -c "\
import sqlite3; \
c=sqlite3.connect(\"file:$(DB_FILE)?mode=ro\",uri=True); \
r=dict(c.execute(\"select id,name from role\")); \
print(\"%-20s %-12s %s\" % (\"username\",\"role\",\"last connection\")); \
[print(\"%-20s %-12s %s\" % (u,r.get(i,i),l or \"-\")) for u,i,l in c.execute(\"select username,role,lastConnection from whitelist order by username\")]"'

ini: ## Show the mod-related server ini lines
	@$(SSH) 'grep -nE "^(Mods|WorkshopItems|Open|MaxPlayers)=" $(SERVER_INI)'

demo-block: ## Push a player over the cap so their next join is refused (PLAYER=name)
	@test -n "$(PLAYER)" || { echo "usage: make demo-block PLAYER=<account name>"; exit 1; }
	@$(SSH) 'f=$(DATA_FILE); \
		grep -q "^\[$(PLAYER)\]$$" "$$f" 2>/dev/null || { \
			echo "$(PLAYER) is not in $$f yet - they have to connect once first"; exit 1; }; \
		sed -i "/^\[$(PLAYER)\]$$/,/^$$/ s/^minutes=.*/minutes=999999/" "$$f" && \
		sed -n "/^\[$(PLAYER)\]$$/,/^$$/p" "$$f"'
	@echo "Within a minute the server will refuse $(PLAYER) on their next join."

demo-restore: ## Put a player's counter back to zero (PLAYER=name)
	@test -n "$(PLAYER)" || { echo "usage: make demo-restore PLAYER=<account name>"; exit 1; }
	@$(SSH) 'f=$(DATA_FILE); \
		sed -i "/^\[$(PLAYER)\]$$/,/^$$/ s/^minutes=.*/minutes=0/" "$$f" && \
		sed -n "/^\[$(PLAYER)\]$$/,/^$$/p" "$$f"'

sandbox: ## Show the mod's settings as the server has them
	@$(SSH) 'grep -nA1 "MaxTimeInServer" $(ZOMBOID)/Server/$(WORLD)_SandboxVars.lua 2>/dev/null \
		|| echo "(no MaxTimeInServer settings in $(WORLD)_SandboxVars.lua - the server writes them on its first boot with the mod enabled)"'

uninstall: ## Remove the mod from the server (leaves the counter file alone)
	@$(SSH) 'rm -rf $(MODS_DIR)/$(MOD_ID)'
