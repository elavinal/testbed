# Copyright 2024 Louis Royer. All rights reserved.
# Use of this source code is governed by a MIT-style license that can be
# found in the LICENSE file.
# SPDX-License-Identifier: MIT

BUILD_DIR = build
BCOMPOSE = $(BUILD_DIR)/compose.yaml
BCONFIG = $(BUILD_DIR)/config.yaml

PROFILES = --profile debug
PROJECT_DIRECTORY = --project-directory $(BUILD_DIR)
MAKE = make --no-print-directory


$(BCONFIG): default-config.yaml
	@echo Copying default-config.yaml into $(BCONFIG)
	@mkdir -p $$(dirname $(BCONFIG))
	@cp default-config.yaml $(BCONFIG)

$(BCOMPOSE): templates/compose.yaml.j2 scripts/jinja/customize.py $(BCONFIG)
	@echo Building $(BCOMPOSE) from jinja template
	@mkdir -p $$(dirname $(BCOMPOSE))
	@j2 --customize scripts/jinja/customize.py -o $(BCOMPOSE) templates/compose.yaml.j2 $(BCONFIG)

.PHONY: test
test:
	@$(MAKE) clean
	@echo [1/4] Running linter on python scripts
	@$(MAKE) test/lint/python
	@echo [2/3] Running tests for Free5GC config
	@$(MAKE) test/free5gc
	@echo [3/4] Running tests for NextMN/UPF config
	@$(MAKE) test/nextmn-upf
	@echo [4/4] Running tests for NextMN/SRv6 config
	@$(MAKE) test/nextmn-srv6

.PHONY: test/lint/python
test/lint/python:
	@find -type f -iname '*.py' -print | parallel '(echo -n Running pylint on {} ; pylint --persistent=false -v -j 0 {})' :::

.PHONY: test/lint/yaml
test/lint/yaml:
	@echo "disable_openssl_generation: true" >> $(BCONFIG)
	@$(MAKE) build
	@echo Running yamllint
	@yamllint $(BUILD_DIR) default-config.yaml
	@echo Running docker compose config
	@docker compose $(PROJECT_DIRECTORY) config >/dev/null
	@$(MAKE) clean

.PHONY: test/nextmn-srv6
test/nextmn-srv6:
	@$(MAKE) set/dataplane/nextmn-srv6
	@$(MAKE) test/lint/yaml
.PHONY: test/nextmn-upf
test/nextmn-upf:
	@$(MAKE) set/dataplane/nextmn-upf
	@$(MAKE) test/lint/yaml
.PHONY: test/nextmn-free5gc
test/free5gc:
	@$(MAKE) set/dataplane/free5gc
	@$(MAKE) test/lint/yaml

.PHONY: set/dataplane
set/dataplane/%: $(BCONFIG)
	@echo Set dataplane to $(@F)
	@./scripts/config_edit.py $(BCONFIG) --dataplane=$(@F)

.PHONY: set/nb-edges
set/nb-edges/%: $(BCONFIG)
	@echo Set number of edges to $(@F)
	@./scripts/config_edit.py $(BCONFIG) --nb-edges=$(@F)

.PHONY: set/nb-ue
set/nb-ue/%: $(BCONFIG)
	@echo Set number of ue to $(@F)
	@./scripts/config_edit.py $(BCONFIG) --nb-ue=$(@F)

.PHONY: clean
clean:
	@rm -rf $(BUILD_DIR)

.PHONY: build
build:
	@$(MAKE) $(BCOMPOSE)

.PHONY: pull
pull: $(BCOMPOSE)
	@echo Pulling Docker images
	@docker compose $(PROFILES) $(PROJECT_DIRECTORY) pull

.PHONY: pull/all
pull/all:
	@echo Pull **all** Docker images
	@docker compose -f templates/images-list.yaml pull

.PHONY: u
u:
	@$(MAKE) up

.PHONY: d
d:
	@$(MAKE) down

.PHONY: r
r:
	@$(MAKE) restart

.PHONY: up
up: $(BCOMPOSE)
	@# set containers up
	@docker compose $(PROFILES) $(PROJECT_DIRECTORY) up -d

.PHONY: up-fg
up-fg: $(BCOMPOSE)
	@# set containers up in foreground
	@docker compose $(PROFILES) $(PROJECT_DIRECTORY)  up

.PHONY: ctrl
ctrl: $(BCONFIG)
	@# show control plane REST API in firefox
	@scripts/show_ctrl.py $(BCONFIG)

.PHONY: down
down:
	@# shutdown containers
	@#> don't depends on build-all because we need the old version to delete all
	@docker compose $(PROFILES) $(PROJECT_DIRECTORY) down -v

.PHONY: restart
restart:
	@# restart all containers
	@docker compose $(PROFILES) $(PROJECT_DIRECTORY) restart

.PHONY: e
e/%:
	@# enter container
	docker exec -it $(@F) bash

.PHONY: db
db/%:
	@# enter database of a container
	docker exec -it $(@F)-db psql postgres -U postgres

.PHONY: t
t/%:
	@# enter container in debug mode
	docker exec -it $(@F)-debug bash

.PHONY: l
l:
	@# show all logs
	docker compose $(PROFILES) $(PROJECT_DIRECTORY) logs
l/%:
	@# show container's logs
	docker compose $(PROFILES) $(PROJECT_DIRECTORY) logs $(@F)

.PHONY: lf
lf:
	@# show all logs (continuous)
	docker compose $(PROFILES) $(PROJECT_DIRECTORY) logs -f
lf/%:
	@# show container's logs (continuous)
	docker compose $(PROFILES) $(PROJECT_DIRECTORY) logs $(@F) -f

.PHONY: ps
ps:
	@# show container's status
	docker compose $(PROFILES) $(PROJECT_DIRECTORY) ps

.PHONY: ping
ping/%:
	@# ping from a container
	@docker exec -it $(*D)-debug bash -c "ping $(@F)"

.PHONY: ue/ip
ue/ip/%:
	@# show ip of ue
	@docker exec -it ue$(@F)-debug bash -c "ip --brief address show uesimtun0|awk '{print \"ue$(@F):\", \$$3; exit}'"

.PHONY: ue/ping
ue/ping/%:
	@# ping between ues
	@# example:
	@#   make ue/ping/1/2
	@# pings from ue1 to ue2
	@TARGET=$(shell docker exec -it ue$(@F)-debug bash -c "ip --brief address show uesimtun0|awk '{print \$$3; exit}'|cut -d"/" -f 1");\
	docker exec -it ue$(*D)-debug bash -c "ping $$TARGET"

.PHONY: ue/switch-edge
ue/switch-edge/%:
	@# swich edge for ue
	@UE_IP=$(shell docker exec ue$(@F)-debug bash -c "ip --brief address show uesimtun0|awk '{print \$$3; exit}'|cut -d"/" -f 1");\
	scripts/switch.py $(BCONFIG) $$UE_IP

.PHONY: graph/latency-switch
graph/latency-switch:
	@echo "[1/7] Configuring testbed"
	@$(MAKE) set/dataplane/nextmn-srv6
	@$(MAKE) set/nb-ue/1
	@$(MAKE) set/nb-edges/2
	@echo "[2/7] Starting containers"
	@$(MAKE) up
	@echo "[3/7] Adding latency on instance s0"
	@docker exec s0-debug bash -c "tc qdisc add dev edge-0 root netem delay 5ms"
	@sleep 2
	@docker exec ue1-debug bash -c "ping -c 1 10.4.0.1 > /dev/null" # check instance is reachable
	@echo "[4/7] [$$(date --rfc-3339=seconds)] Scheduling instance switch in 30s"
	@bash -c 'sleep 30 && $(MAKE) ue/switch-edge/1 && echo "[5.5/6] [$$(date --rfc-3339=seconds)] Switching to edge 1"' &
	@echo "[5/7] [$$(date --rfc-3339=seconds)] Start ping for 60s"
	@docker exec ue1-debug bash -c "ping -D -w 60 10.4.0.1 -i 0.1 > /volume/ping.txt"
	@echo "[6/7] Stopping containers"
	@$(MAKE) down
	@echo "[7/7] Creating graph"
	@scripts/graphs/latency_switch.py $(BUILD_DIR)/volumes/ue1/ping.txt

.PHONY: graph/cp-delay
graph/cp-delay:
	@$(MAKE) graph/cp-delay/iter/100

.PHONY: graph/cp-delay/iter
graph/cp-delay/iter/%:
	@echo "[1/4] Configuring testbed"
	@$(MAKE) set/nb-ue/1
	@$(MAKE) set/nb-edges/2
	@echo "[2/4] [$$(date --rfc-3339=seconds)] Setting dataplane to Free5GC"
	@$(MAKE) set/dataplane/free5gc
	@$(MAKE) build
	@iter=1 ; while [ $$iter -le $(@F) ] ; do \
		echo "[2/4] [$$iter/$(@F)] [$$(date --rfc-3339=seconds)] New Free5GC capture" ; \
		$(MAKE) graph/cp-delay/f5gc-$$iter ; \
		iter=$$(( iter  + 1)) ; \
	done
	@echo "[3/4] [$$(date --rfc-3339=seconds)] Setting dataplane to NextMN-SRv6"
	@$(MAKE) set/dataplane/nextmn-srv6
	@$(MAKE) build
	@iter=1 ; while [ $$iter -le $(@F) ] ; do \
		echo "[3/4] [$$iter/$(@F)] [$$(date --rfc-3339=seconds)] New NextMN-SRv6 capture" ; \
		$(MAKE) graph/cp-delay/srv6-$$iter ; \
		iter=$$(( iter + 1)) ; \
	done
	@echo "[4/4] Creating graph"
	@scripts/graphs/cp_delay.py text $(BUILD_DIR)/results
	@scripts/graphs/cp_delay.py plot $(@F) $(BUILD_DIR)/results

graph/cp-delay/%:
	@mkdir build/results -p
	@tshark -i any -f sctp -w $(BUILD_DIR)/results/cp-delay-$(@F).pcapng & echo "$$!" > $(BUILD_DIR)/results/pid
	@$(MAKE) up
	@sleep 5
	@$(MAKE) down
	@kill -s TERM "$$(cat $(BUILD_DIR)/results/pid)" && rm $(BUILD_DIR)/results/pid
