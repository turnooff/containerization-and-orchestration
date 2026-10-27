FROM node:22-alpine

# Версии закреплены: и сервер, и мост ставятся при сборке, а не через npx при каждом старте
RUN npm install -g --no-fund --no-audit \
      @modelcontextprotocol/server-filesystem@2026.8.31 \
      supergateway@3.4.3

USER node

EXPOSE 8000
# supergateway запускает stdio-сервер дочерним процессом и отдаёт его наружу по Streamable HTTP.
# Сервер видит только /data/marketing — это его «разрешённая директория».
CMD ["supergateway", "--stdio", "mcp-server-filesystem /data/marketing", \
     "--outputTransport", "streamableHttp", "--port", "8000"]
