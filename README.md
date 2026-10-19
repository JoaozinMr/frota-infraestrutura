# Frota – Infraestrutura

Orquestração do sistema distribuído de monitoramento de frota: um único comando (`make up`) clona os repositórios dos serviços, constrói as imagens e sobe o ambiente completo com load balancer, broker, bancos, painel e simulador. Inclui o teste de carga k6, o roteiro de falha da apresentação e o provisionamento na Azure (Terraform + cloud-init).

## Arquitetura

```
 Simulador (1.000 caminhões) ─┐
 k6 (até 2.000 VUs) ──────────┤
                              ▼
                    Nginx :80 (round robin)
                 ┌────────────┴─────────────┐
   /api/telemetry│                          │/api/alerts
                 ▼                          ▼
     API Ingestão x2 ──► Redpanda ──► Worker x2 ──(HTTP)──► API Alertas
       (validação)      frota.telemetria   (consumer group,   │
                        frota.telemetria.dlq  6 partições)     │
                                             │   │             │
                                        Redis│   │PostgreSQL◄──┘
                                    (hot path)   (TimescaleDB: telemetria + alertas)
                                                      │
                                               Grafana :3000
```

| Serviço | Repositório | Réplicas | Exposição |
|---|---|---|---|
| `nginx` | este (`nginx/nginx.conf`) | 1 | **:80** |
| `api-ingestao` | [frota-api-ingestao](https://github.com/JoaozinMr/frota-api-ingestao) | **2** | via Nginx (`/api/telemetry`) |
| `worker` | [frota-worker-processamento](https://github.com/JoaozinMr/frota-worker-processamento) | **2** | interna |
| `api-alertas` | [frota-api-alertas](https://github.com/JoaozinMr/frota-api-alertas) | 1 | via Nginx (`/api/alerts`) |
| `simulador` | [frota-simulador-carga](https://github.com/JoaozinMr/frota-simulador-carga) | 1 | — |
| `redpanda` + `init-topics` | imagem oficial | 1 | interna (sem Zookeeper) |
| `redpanda-console` | imagem oficial | 1 | `127.0.0.1:8088` |
| `redis` | `redis:7.4-alpine` | 1 | interna |
| `postgres` | `timescale/timescaledb:2.17.2-pg16` + `postgres/init.sql` | 1 | interna |
| `grafana` | `grafana/grafana:11.3.1` + provisionamento | 1 | **:3000** |

Detalhes de configuração:

- **Load balancer**: upstreams balanceados via DNS interno do Docker, onde cada réplica da Ingestão vira um servidor do round robin. Keep-alive com os upstreams, `worker_connections 16384` para os 2.000 VUs, limite de corpo de 64 KiB (o mesmo da API). Health por serviço: `/health/ingestao` (→ `/health/ready`, broker + tópicos) e `/health/alertas`.
- **Redpanda**: `init-topics` cria `frota.telemetria` e `frota.telemetria.dlq` com 6 partições antes das APIs (a Ingestão usa `AllowAutoCreateTopics=false`). Com 2 Workers no mesmo `GroupId`, cada um recebe 3 partições.
- **Redpanda (retenção)**: `frota.telemetria` guarda 2h ou 256 MB por partição (o que vier primeiro); a DLQ, 24h ou 64 MB por partição.
- **PostgreSQL**: `init.sql` cria a extensão TimescaleDB, a hypertable `telemetria` (chunks de 1h, retenção de 6h), a tabela `alertas` e o usuário somente leitura `grafana_leitura`. As definições espelham o DDL que os próprios serviços executam na inicialização — mantenha-as alinhadas.
- **Grafana**: datasource e dashboard provisionados (`grafana/`); acesso anônimo como Viewer e dashboard "Frota — Monitoramento em tempo real" como página inicial.
- **Logs**: todos os serviços (inclusive o simulador e o Nginx) escrevem JSON em stdout com `Service`; rotação `json-file` de 3×20 MB.

## Pré-requisitos

- Docker Engine/Desktop com Compose v2 e GNU Make.
- Git (o `make up` clona os repositórios por HTTPS).
- ~6 GB de RAM livres para o ambiente completo.

## Subir tudo com um único comando

```bash
make up
```

1. Clona `frota-simulador-carga`, `frota-api-ingestao`, `frota-worker-processamento` e `frota-api-alertas` em `.repos/` (ou faz `git pull --ff-only` se já existirem).
2. Executa `docker compose up -d --build`.

| URL | O quê |
|---|---|
| http://localhost/api/telemetry | `POST` de telemetria (load balancer → Ingestão) |
| http://localhost/api/alerts, `/api/alerts/resumo` | Consulta de alertas |
| http://localhost/health/ingestao, `/health/alertas` | Health dos serviços via Nginx |
| http://localhost:3000 | Grafana (anônimo: leitura; admin: `admin` / `GRAFANA_ADMIN_PASSWORD`, padrão `admin`) |
| http://localhost:8088 | Redpanda Console (consumer group, lag, partições) |

Variáveis opcionais em `.env` (veja `.env.example`): `POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `SIM_NUM_VEICULOS`, `SIM_INTERVALO_SEGUNDOS`.

Desenvolvimento com os repositórios já clonados lado a lado (sem clonar/atualizar):

```bash
make up REPOS_DIR=..
```

Outros alvos (`make help`):

| Alvo | Ação |
|---|---|
| `make ps` / `make logs SERVICE=worker` | Estado e logs |
| `make simulador` / `make simulador-parar` | Liga/desliga a carga orgânica |
| `make k6` | Teste de estresse (seção abaixo) |
| `make lag` / `make lag-watch` | Consumer group: membros, partições e lag |
| `make falha` / `make falha-graciosa` / `make recuperar` | Roteiro de falha |
| `make verificar` | Contagens e checagem de duplicatas no PostgreSQL |
| `make dlq` / `make alertas` | Últimas mensagens da DLQ / resumo de alertas |
| `make down` / `make clean` | Para (mantém dados) / remove tudo, inclusive volumes e `.repos/` |

## Roteiro de falha (apresentação ao vivo)

Objetivo: mostrar que a queda de um Worker não perde nem duplica dados e não trava o painel.

**Preparação**: `make up`, Grafana aberto em http://localhost:3000 e Redpanda Console em http://localhost:8088 → *Consumer Groups* → `frota-worker-processamento`.

1. **Simulador rodando, painel com picos orgânicos.** O simulador sobe com o `make up` (se estiver parado: `make simulador`). No Grafana, "Vazão de telemetria persistida" oscila em torno de ~1.000 eventos/s; o mapa mostra os caminhões e os alertas de `EXCESSO_VELOCIDADE`, `FORA_GEOFENCE` e `SENSOR_MORTO` vão aparecendo. Mostre o consumer group **Stable** com 2 membros e 3 partições cada (`make lag`).

2. **Derrubar a réplica 1 do Worker** em um terminal secundário:

   ```bash
   make falha               # docker kill frota-worker-1 (crash)
   # ou, literalmente:
   docker kill frota-worker-1
   ```

   Use `docker kill` para simular um crash: o processo morre sem avisar o grupo. Com `docker stop` (`make falha-graciosa`) o Worker faz *LeaveGroup* na saída, o rebalanceamento é imediato e o lag quase não aparece — também é uma demonstração válida, só menos visual.

3. **Consumer lag subindo abruptamente.** No Redpanda Console (ou `make lag-watch`), as 3 partições da réplica morta param de avançar: o lag sobe para alguns milhares de mensagens nos ~10–45s do *session timeout*.

4. **Rebalanceamento das partições órfãs.** Expirado o timeout, o grupo passa a ter **1 membro** e o Redpanda atribui as 6 partições ao `frota-worker-2` (coluna *MEMBER-ID*/*HOST* idêntica em todas as partições).

5. **Recuperação e consistência.**
   - O lag volta a ~0 em poucos segundos (o Worker 2 consome o acumulado a partir do último offset confirmado).
   - O painel não travou: a vazão no Grafana segue contínua — a API de Ingestão não depende dos Workers, e as mensagens ficaram retidas no Redpanda.
   - Nenhum alerta foi ignorado: o Worker só confirma offsets após persistir e notificar, então o que estava em andamento na réplica morta é reprocessado.
   - A idempotência bloqueou duplicações: as mensagens entre o último commit e o crash são **reentregues** ao Worker 2, mas são descartadas pelo índice único `(id_evento, ts)` no PostgreSQL e pela deduplicação `alerta:{id}:{tipo}` no Redis. Comprove com:

     ```bash
     make verificar    # telemetria_duplicada = 0 e alertas_duplicados = 0
     ```

     O painel "Eventos duplicados" do Grafana também permanece em 0.

6. **(Opcional) volta da réplica**: `make recuperar` — o grupo rebalanceia de novo para 2 membros com 3 partições cada.

Execução de referência deste roteiro (ambiente local, simulador a ~980 req/s): ao `docker kill`, o lag foi de ~40 para **5.221** em 10s; aos 15s o grupo tinha 1 membro com as 6 partições e o lag voltou a dois dígitos; `make verificar` retornou 0 duplicatas em ~160 mil leituras.

## Teste de carga (k6)

[`k6/load_test.js`](k6/load_test.js) é focado em estresse da Ingestão (o comportamento dos caminhões fica com o simulador):

- **Rampa**: 0 → 2.000 VUs em 1 minuto, 1 minuto sustentado no pico, 30s de descida. Cada VU envia um JSON válido e dorme 1s (≈ 2.000 req/s no pico).
- **Thresholds**: `http_req_duration: ['p(95)<300']` (p95 < 300 ms) e `http_req_failed: ['rate<0.01']` (erro < 1%), além de `checks` (status `202`) > 99%. O k6 sai com código ≠ 0 se algum limite for violado.
- Os payloads usam velocidade < 80 km/h, posição dentro do geofence e motor desligado, para não gerar alertas nem `SENSOR_MORTO` após o teste.

```bash
make simulador-parar        # isola a medição
make k6                     # roda na rede do Compose, contra http://nginx
make k6 K6_VUS=500          # pico menor (ex.: VM B2s)
make k6-externo BASE_URL=http://<ip-da-vm>   # de outra máquina
make simulador
```

Sem Docker: `k6 run -e BASE_URL=http://localhost k6/load_test.js`.

Execução de referência (máquina de desenvolvimento local, perfil completo de 2.000 VUs): 209.553 requisições (~1.390 req/s em média), **p95 = 7,6 ms**, p99 = 8,5 ms, **0% de falhas** e 100% de respostas `202`. Os números em uma VM B2s serão bem diferentes; meça lá antes de apresentar.

## Azure (bônus)

[`azure/`](azure/) provisiona com Terraform (`azurerm` 4.x):

- **VM Linux** Ubuntu 24.04, `Standard_B2s` (2 vCPU, 4 GiB), disco StandardSSD de 64 GB, acesso só por chave SSH.
- **Rede/NSG**: VNet + subnet, IP público estático; regras de entrada apenas para **22** (SSH, restringível por `ssh_origem_permitida`), **80** (Nginx) e **3000** (Grafana). Redpanda, Redis e PostgreSQL não publicam portas no host e não têm regra no NSG; o Redpanda Console fica em `127.0.0.1:8088` (acesso por túnel SSH).
- **cloud-init** ([`cloud-init.yaml.tftpl`](azure/cloud-init.yaml.tftpl)): cria swap de 4 GB (build .NET em 4 GiB), instala Docker (script oficial, com o plugin Compose), Git e Make, clona este repositório em `/opt/frota`, grava o `.env` (senha do Grafana gerada pelo Terraform) e executa `make up`.

```bash
cd azure
cp terraform.tfvars.example terraform.tfvars   # subscription_id, ssh_origem_permitida...
az login
terraform init
terraform apply
terraform output                               # IP, URLs e comando do túnel
terraform output -raw grafana_admin_password
```

O primeiro boot leva ~10–15 minutos (instalação do Docker e build das imagens). Acompanhe com `ssh azureuser@<ip> tail -f /var/log/cloud-init-output.log /var/log/frota-make-up.log`. Na VM, os alvos do Makefile funcionam em `/opt/frota` (ex.: `cd /opt/frota && make lag`).

Para o tamanho B2s, o simulador sobe com 1.000 caminhões a cada 2s (`sim_intervalo_segundos`); o k6 de 2.000 VUs tende a saturar 2 vCPUs — rode-o de outra máquina (`make k6-externo`) ou reduza `K6_VUS`. Remova tudo com `terraform destroy`.

## Garantias e limites

- Um broker com fator de replicação 1: tolera a queda de Workers e de réplicas da API, não a perda do broker ou do disco.
- Sem TLS/autenticação nas APIs; senhas de laboratório (`frota`, `grafana_leitura`) — o banco não é publicado fora da rede do Compose.
- `POSTGRES_PASSWORD`, o `init.sql` e a retenção dos tópicos só valem na criação dos volumes; para reaplicar, `make clean`.
- **Disco**: com o simulador a ~1.000 eventos/s, a telemetria ocupa ~2 GB/hora no PostgreSQL (limitada a 6h ≈ 12 GB) e até ~1,5 GB no Redpanda, além de ~6 GB de imagens. Reserve ~20 GB livres ou reduza a carga (`SIM_INTERVALO_SEGUNDOS=2`). `make down` mantém os dados; `make clean` libera tudo.
- Nenhuma porta de dados (9092, 6379, 5432) é publicada no host.
