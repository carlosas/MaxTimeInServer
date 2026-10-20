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
	@# server actually booted with.
	@find $(MOD_FILES) -type f | sort | xargs md5 -r | sed 's|^\([a-f0-9]*\) |\1  |' > /tmp/mts-local.txt
	@if ! $(SSH) 'test -d $(MODS_DIR)/$(MOD_ID)'; then \
		echo "the server has no copy of the mod installed - nothing to compare against"; \
		exit 0; fi; \
		$(SSH) 'cd $(MODS_DIR)/$(MOD_ID) && find . -type f | sort | xargs md5sum | sed "s|\./||"' > /tmp/mts-remote.txt; \
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

install-client: test verify-sync ## Install the mod into the game on THIS machine
	@test -d "$(CLIENT_ZOMBOID)" || { echo "no $(CLIENT_ZOMBOID) here - set CLIENT_ZOMBOID to your game's user folder"; exit 1; }
	@rm -rf "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)"
	@mkdir -p "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)"
	@COPYFILE_DISABLE=1 tar --no-xattrs -cf - $(MOD_FILES) | tar xf - -C "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)"
	@find "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)" -name "._*" -delete
	@echo "installed into $(CLIENT_ZOMBOID)/mods/$(MOD_ID)"

verify-client: ## Check this machine's copy matches the server's, byte for byte
	@cd "$(CLIENT_ZOMBOID)/mods/$(MOD_ID)" && find . -type f | sort | xargs md5 -r \
		| sed 's|^\([a-f0-9]*\) ./|\1  |' > /tmp/mts-client.txt
	@$(SSH) 'cd $(MODS_DIR)/$(MOD_ID) && find . -type f | sort | xargs md5sum | sed "s|\./||"' > /tmp/mts-server.txt
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
