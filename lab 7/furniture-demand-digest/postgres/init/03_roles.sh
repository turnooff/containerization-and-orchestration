#!/bin/bash
# Пользователи БД по принципу наименьших привилегий:
#   mcp_reader — для sales-mcp: только SELECT по данным продаж;
#   n8n_app    — для не-AI шагов n8n: SELECT + запись в таблицу дедупликации.
# Пароли приходят из переменных окружения контейнера (.env), а не хранятся в SQL.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v mcp_pw="$MCP_READER_PASSWORD" -v n8n_pw="$N8N_DB_PASSWORD" <<'EOSQL'
CREATE ROLE mcp_reader LOGIN PASSWORD :'mcp_pw';
GRANT CONNECT ON DATABASE furniture TO mcp_reader;
GRANT USAGE ON SCHEMA public TO mcp_reader;
GRANT SELECT ON products, customers, orders, order_items, price_history, forecasts TO mcp_reader;

CREATE ROLE n8n_app LOGIN PASSWORD :'n8n_pw';
GRANT CONNECT ON DATABASE furniture TO n8n_app;
GRANT USAGE ON SCHEMA public TO n8n_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO n8n_app;
GRANT INSERT ON reported_anomalies TO n8n_app;
EOSQL
