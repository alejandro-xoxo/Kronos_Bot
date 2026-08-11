FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY list_groups.py .

RUN mkdir -p /app/session

CMD ["python", "main.py"]