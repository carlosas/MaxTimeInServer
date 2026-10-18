# MaxTimeInServer - weekly connected-time quota for a Project Zomboid B42 server.
#
# Nothing here ever restarts the game server on its own: `make restart` is a
# separate, deliberate step.

SERVER      ?= server-local
SSH         ?= ssh -o BatchMode=yes -o ConnectTimeout=8 $(SERVER)
MOD_ID      ?= MaxTimeInServer
WORLD       ?= Zomboides2

ZOMBOID     ?= $$HOME/Zomboid
MODS_DIR    ?= $(ZOMBOID)/mods
CONSOLE     ?= $(ZOMBOID)/server-console.txt
DATA_FILE   ?= $(ZOMBOID)/Lua/MaxTimeInServer.txt
DB_FILE     ?= $(ZOMBOID)/db/$(WORLD).db
SERVER_INI  ?= $(ZOMBOID)/Server/$(WORLD).ini

MOD_FILES   = 42 common

.PHONY: help test deploy package restart status logs data roles ini \
        demo-block demo-restore uninstall

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

package: test verify-sync ## Build the zip the players install into their own Zomboid/mods/
	@rm -rf build && mkdir -p build/$(MOD_ID)
	@COPYFILE_DISABLE=1 tar --no-xattrs -cf - $(MOD_FILES) | tar xf - -C build/$(MOD_ID)
	@cd build && zip -qr $(MOD_ID).zip $(MOD_ID)
	@echo "build/$(MOD_ID).zip - players unzip this into their Zomboid/mods/ folder"
	@unzip -l build/$(MOD_ID).zip | tail -3

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

demo-block: ## Set the cap to 1 minute so the next join is refused (for testing)
	@$(SSH) 'f=$(DATA_FILE); [ -f "$$f" ] || { echo "no $$f yet - connect once first"; exit 1; }; \
		sed -i "s/^capMinutes=.*/capMinutes=1/" "$$f" && grep -n "^capMinutes=" "$$f"'
	@echo "Within a minute the server will refuse anyone whose counter is >= 1 minute."

demo-restore: ## Put the cap back to 600 minutes
	@$(SSH) 'sed -i "s/^capMinutes=.*/capMinutes=600/" $(DATA_FILE) && grep -n "^capMinutes=" $(DATA_FILE)'

uninstall: ## Remove the mod from the server (leaves the counter file alone)
	@$(SSH) 'rm -rf $(MODS_DIR)/$(MOD_ID)'
