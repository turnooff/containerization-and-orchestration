FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Сначала зависимости, потом код: правка server.py не инвалидирует слой с pip install
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY server.py .

RUN useradd --uid 10001 --no-create-home app
USER app

EXPOSE 8000
CMD ["python", "server.py"]
