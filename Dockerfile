FROM python:3.12-slim

WORKDIR /app

ENV HOST=0.0.0.0 \
    PORT=8080 \
    SERVICEOS_SYNC_ENABLED=false \
    PYTHONUNBUFFERED=1

COPY . .

EXPOSE 8080

CMD ["python3", "scripts/app_server.py"]
