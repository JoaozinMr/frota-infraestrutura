-- Executado uma única vez, na criação do volume do PostgreSQL (banco "frota", usuário "frota").
-- Os serviços também garantem seus schemas na inicialização (CREATE ... IF NOT EXISTS);
-- este script os antecipa para que o Grafana tenha as tabelas desde o primeiro acesso.
-- Mantenha as definições alinhadas com:
--   telemetria -> frota-worker-processamento/src/FrotaWorker/Services/PostgresBatchWriter.cs
--   alertas    -> frota-api-alertas/src/FrotaAlertas/Services/AlertaRepository.cs

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Cold path do Worker. Idempotência: índice único (id_evento, ts) + ON CONFLICT DO NOTHING.
-- O índice inclui ts porque o TimescaleDB exige a coluna de particionamento.
CREATE TABLE IF NOT EXISTS telemetria (
    id_evento      UUID,
    id_veiculo     TEXT             NOT NULL,
    sequencia      BIGINT,
    ts             TIMESTAMPTZ      NOT NULL,
    latitude       DOUBLE PRECISION NOT NULL,
    longitude      DOUBLE PRECISION NOT NULL,
    velocidade     DOUBLE PRECISION NOT NULL,
    status_motor   TEXT,
    correlation_id TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_telemetria_evento ON telemetria (id_evento, ts);
CREATE INDEX IF NOT EXISTS ix_telemetria_veiculo_ts ON telemetria (id_veiculo, ts DESC);

-- Chunks de 1 hora: a retenção descarta chunks inteiros (com o padrão de 7 dias nada seria liberado).
SELECT create_hypertable('telemetria', 'ts', chunk_time_interval => INTERVAL '1 hour', if_not_exists => true);
-- Laboratório: ~1.000 eventos/s ocupam ~2 GB/hora; mantém só as últimas 6 horas.
SELECT add_retention_policy('telemetria', INTERVAL '6 hours', if_not_exists => true);

-- Alertas da API de Alertas. Idempotência: UNIQUE (id_veiculo, tipo_infracao, timestamp).
CREATE TABLE IF NOT EXISTS alertas (
    id              BIGSERIAL PRIMARY KEY,
    id_veiculo      TEXT             NOT NULL,
    tipo_infracao   TEXT             NOT NULL,
    descricao       TEXT             NOT NULL DEFAULT '',
    latitude        DOUBLE PRECISION NULL,
    longitude       DOUBLE PRECISION NULL,
    velocidade      DOUBLE PRECISION NULL,
    "timestamp"     TIMESTAMPTZ      NOT NULL,
    correlation_id  TEXT             NULL,
    recebido_em     TIMESTAMPTZ      NOT NULL DEFAULT now(),
    CONSTRAINT uq_alertas_veiculo_tipo_timestamp UNIQUE (id_veiculo, tipo_infracao, "timestamp")
);
CREATE INDEX IF NOT EXISTS ix_alertas_timestamp ON alertas ("timestamp" DESC);
CREATE INDEX IF NOT EXISTS ix_alertas_veiculo_timestamp ON alertas (id_veiculo, "timestamp" DESC);
CREATE INDEX IF NOT EXISTS ix_alertas_tipo_timestamp ON alertas (tipo_infracao, "timestamp" DESC);

-- Usuário somente leitura do Grafana (senha do laboratório; o banco não tem porta publicada).
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_leitura') THEN
        CREATE ROLE grafana_leitura LOGIN PASSWORD 'grafana_leitura';
    END IF;
END
$$;
GRANT CONNECT ON DATABASE frota TO grafana_leitura;
GRANT USAGE ON SCHEMA public TO grafana_leitura;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_leitura;
-- Tabelas criadas depois pelos serviços (usuário frota) também ficam legíveis.
ALTER DEFAULT PRIVILEGES FOR ROLE frota IN SCHEMA public GRANT SELECT ON TABLES TO grafana_leitura;
