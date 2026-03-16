FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

COPY server/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY server/ ./server/
COPY web/ ./web/
COPY run_server.py ./

RUN mkdir -p /data/saves /data/db

ENV OSGSC_DATA_DIR=/data
ENV OSGSC_HOST=0.0.0.0
ENV OSGSC_PORT=4444

EXPOSE 4444

CMD ["python", "run_server.py"]
