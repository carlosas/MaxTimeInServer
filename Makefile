# PlayerTimer - weekly connected-time quota for a Project Zomboid B42 server.
#
# Nothing here ever restarts the game server on its own: `make restart` is a
# separate, deliberate step.

SERVER      ?= server-local
SSH         ?= ssh -o BatchMode=yes -o ConnectTimeout=8 $(SERVER)
MOD_ID      ?= PlayerTimer
WORLD       ?= Zomboides2

ZOMBOID     ?= $$HOME/Zomboid
MODS_DIR    ?= $(ZOMBOID)/mods
CONSOLE     ?= $(ZOMBOID)/server-console.txt
DATA_FILE   ?= $(ZOMBOID)/Lua/PlayerTimer.txt
DB_FILE     ?= $(ZOMBOID)/db/$(WORLD).db
SERVER_INI  ?= $(ZOMBOID)/Server/$(WORLD).ini

MOD_FILES   = mod.info poster.png common

.PHONY: help test deploy restart status logs data roles ini \
        probe-deploy probe-read probe-clean uninstall

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t24

test: ## Run the Lua test suite locally
	@./tests/run.sh

deploy: test ## Copy the mod to the server (does not restart it)
	@tar cf - $(MOD_FILES) | $(SSH) 'mkdir -p $(MODS_DIR)/$(MOD_ID) && tar xf - -C $(MODS_DIR)/$(MOD_ID)'
	@$(SSH) 'find $(MODS_DIR)/$(MOD_ID) -type f | sort'
	@echo "Deployed. Add $(MOD_ID) to the Mods= line and restart when you are ready."

restart: ## Restart the game server (asks nothing, so run it on purpose)
	@$(SSH) 'systemctl --user restart zomboid.service'
	@$(SSH) 'systemctl --user is-active zomboid.service'

status: ## Service status
	@$(SSH) 'systemctl --user is-active zomboid-panel zomboid zomboid-backup.timer'

logs: ## Last PlayerTimer lines from the server console
	@$(SSH) 'grep -a "\[PlayerTimer" $(CONSOLE) | tail -40 || echo "(no PlayerTimer lines yet)"'

data: ## Show the counter file
	@$(SSH) 'cat $(DATA_FILE) 2>/dev/null || echo "(no $(DATA_FILE) yet)"'

roles: ## Show every account and the role it currently holds
	@$(SSH) 'python3 -c "\
import sqlite3; \
c=sqlite3.connect(\"file:$(DB_FILE)?mode=ro\",uri=True); \
r=dict(c.execute(\"select id,name from role\")); \
print(\"%-20s %-12s %s\" % (\"username\",\"role\",\"last connection\")); \
[print(\"%-20s %-12s %s\" % (u,r.get(i,i),l or \"-\")) for u,i,l in c.execute(\"select username,role,lastConnection from whitelist order by username\")]"'

ini: ## Show the mod-related server ini lines
	@$(SSH) 'grep -nE "^(Mods|WorkshopItems|Open|MaxPlayers)=" $(SERVER_INI)'

probe-deploy: ## Copy the throwaway layout probes to the server
	@cd tools/probe && tar cf - PlayerTimerProbeA PlayerTimerProbeB | $(SSH) 'mkdir -p $(MODS_DIR) && tar xf - -C $(MODS_DIR)'
	@echo "Probes in place. Set Mods=PlayerTimerProbeA;PlayerTimerProbeB, restart, then 'make probe-read'."

probe-read: ## Report which mod layouts actually loaded
	@$(SSH) 'grep -a "\[PlayerTimerProbe\]" $(CONSOLE) | tail -20 || echo "(no probe lines - no layout loaded)"'
	@$(SSH) 'grep -aiE "mod.*(not found|missing|error)" $(CONSOLE) | tail -10 || true'

probe-clean: ## Remove the probe mods from the server
	@$(SSH) 'rm -rf $(MODS_DIR)/PlayerTimerProbeA $(MODS_DIR)/PlayerTimerProbeB'
	@echo "Probes removed. Remember to put the Mods= line back."

uninstall: ## Remove the mod from the server (leaves the counter file alone)
	@$(SSH) 'rm -rf $(MODS_DIR)/$(MOD_ID)'
