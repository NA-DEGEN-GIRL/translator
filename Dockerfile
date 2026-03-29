FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY requirements.txt .
RUN uv pip install --system -r requirements.txt

COPY main.py prompts.py ./
COPY static/ static/
COPY .env.example .

EXPOSE 8001

CMD ["python", "main.py"]
