# Orquestração do laboratório: `make up` clona os repositórios dos serviços e sobe tudo.
#
#   make up                     clona/atualiza em .repos/ e executa docker compose up -d --build
#   make up REPOS_DIR=..        usa os repositórios já presentes ao lado deste (desenvolvimento)
#   make help                   lista os alvos

GIT_BASE  ?= https://github.com/JoaozinMr
REPOS_DIR ?= .repos
REPOS     := frota-simulador-carga frota-api-ingestao frota-worker-processamento frota-api-alertas

# Só atualiza (git pull) clones gerenciados por este Makefile; nunca mexe em diretórios do desenvolvedor.
ifeq ($(REPOS_DIR),.repos)
UPDATE ?= 1
else
UPDATE ?= 0
endif

COMPOSE  := docker compose
NETWORK  := frota-net
WORKER   ?= frota-worker-1
GROUP    := frota-worker-processamento
K6_IMAGE := grafana/k6:0.54.0
PSQL     := $(COMPOSE) exec -T postgres psql -U frota -d frota

# docker-compose.yml lê REPOS_DIR para os contextos de build.
export REPOS_DIR

.DEFAULT_GOAL := help
.PHONY: help up repos build down clean ps logs simulador simulador-parar k6 k6-externo \
        lag lag-watch falha falha-graciosa recuperar verificar dlq alertas

help: ## Lista os alvos disponíveis
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

up: repos ## Clona os repositórios e sobe todo o ambiente (único comando)
	$(COMPOSE) up -d --build
	@echo ""
	@echo "Ambiente no ar:"
	@echo "  API (load balancer)  http://localhost/api/telemetry  |  http://localhost/api/alerts"
	@echo "  Grafana              http://localhost:3000  (admin / \$$GRAFANA_ADMIN_PASSWORD, padrão admin)"
	@echo "  Redpanda Console     http://localhost:8088"

repos: ## Clona (ou atualiza) os repositórios dos serviços em $(REPOS_DIR)
	@command -v git >/dev/null || { echo "git não encontrado"; exit 1; }
	@mkdir -p $(REPOS_DIR)
	@for repo in $(REPOS); do \
		dir="$(REPOS_DIR)/$$repo"; \
		if [ ! -d "$$dir" ]; then \
			echo ">> clonando $$repo"; \
			git clone --depth 1 "$(GIT_BASE)/$$repo.git" "$$dir" || exit 1; \
		elif [ "$(UPDATE)" = "1" ] && [ -d "$$dir/.git" ]; then \
			echo ">> atualizando $$repo"; \
			git -C "$$dir" pull --ff-only --quiet || echo "   aviso: não foi possível atualizar $$repo (seguindo com a versão local)"; \
		else \
			echo ">> usando $$dir"; \
		fi; \
	done

build: repos ## Reconstrói as imagens sem subir
	$(COMPOSE) build

down: ## Para e remove os containers (mantém os volumes)
	$(COMPOSE) down --remove-orphans

clean: ## Remove containers, volumes (dados) e os clones em .repos/
	$(COMPOSE) down -v --remove-orphans
	rm -rf .repos

ps: ## Estado dos containers
	$(COMPOSE) ps

logs: ## Logs em tempo real (ex.: make logs SERVICE=worker)
	$(COMPOSE) logs -f --tail 100 $(SERVICE)

simulador: ## (Re)inicia o simulador de 1.000 caminhões
	$(COMPOSE) up -d simulador

simulador-parar: ## Para o simulador (ex.: antes do teste k6)
	$(COMPOSE) stop simulador

k6: ## Teste de carga k6 contra o Nginx, dentro da rede do Compose
	docker run --rm -i --network $(NETWORK) --ulimit nofile=65535:65535 \
		-e BASE_URL=http://nginx $(if $(K6_VUS),-e K6_VUS=$(K6_VUS)) $(if $(K6_SLEEP),-e K6_SLEEP=$(K6_SLEEP)) \
		$(K6_IMAGE) run - < k6/load_test.js

k6-externo: ## Teste k6 contra outra máquina (ex.: make k6-externo BASE_URL=http://<ip-da-vm>)
	@test -n "$(BASE_URL)" || { echo "Informe BASE_URL=http://<host>"; exit 1; }
	docker run --rm -i --ulimit nofile=65535:65535 -e BASE_URL=$(BASE_URL) \
		$(if $(K6_VUS),-e K6_VUS=$(K6_VUS)) $(if $(K6_SLEEP),-e K6_SLEEP=$(K6_SLEEP)) \
		$(K6_IMAGE) run - < k6/load_test.js

lag: ## Consumer group dos Workers: membros, partições e lag
	$(COMPOSE) exec redpanda rpk group describe $(GROUP)

lag-watch: ## Acompanha o lag a cada 2s (Ctrl+C para sair)
	@while true; do clear; date; $(COMPOSE) exec -T redpanda rpk group describe $(GROUP); sleep 2; done

# Crash (SIGKILL): o Worker não avisa o grupo; as partições ficam órfãs até o session timeout
# e o lag sobe visivelmente antes do rebalanceamento. `docker stop` sai do grupo na hora.
falha: ## Roteiro de falha: crash de uma réplica do Worker (WORKER=frota-worker-1)
	docker kill $(WORKER)

falha-graciosa: ## Parada limpa de uma réplica (docker stop: rebalanceamento imediato)
	docker stop $(WORKER)

recuperar: ## Religa a réplica derrubada
	docker start $(WORKER)

verificar: ## Verifica idempotência no PostgreSQL (duplicatas devem ser 0)
	@$(PSQL) -c "SELECT count(*) AS telemetria_total, count(DISTINCT id_veiculo) AS veiculos, max(ts) AS ultima_leitura FROM telemetria;"
	@$(PSQL) -c "SELECT count(*) AS telemetria_duplicada FROM (SELECT 1 FROM telemetria GROUP BY id_evento, ts HAVING count(*) > 1) d;"
	@$(PSQL) -c "SELECT count(*) AS alertas_duplicados FROM (SELECT 1 FROM alertas GROUP BY id_veiculo, tipo_infracao, \"timestamp\" HAVING count(*) > 1) d;"
	@$(PSQL) -c "SELECT tipo_infracao, count(*) AS alertas, count(DISTINCT id_veiculo) AS veiculos FROM alertas GROUP BY 1 ORDER BY 1;"

dlq: ## Mostra as 5 mensagens mais recentes da DLQ
	$(COMPOSE) exec redpanda rpk topic consume frota.telemetria.dlq -o -5 -n 5 --format '%k %h{%k=%v;}\n%v\n\n'

alertas: ## Resumo de alertas via load balancer
	@curl -s http://localhost/api/alerts/resumo; echo
