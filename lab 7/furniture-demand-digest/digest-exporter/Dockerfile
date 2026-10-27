FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY exporter.py .

RUN useradd --uid 10002 --no-create-home app
USER app

EXPOSE 9200
CMD ["python", "exporter.py"]
