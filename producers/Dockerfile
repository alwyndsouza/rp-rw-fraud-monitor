FROM python:3.11-slim

WORKDIR /app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Copy dependency files first for layer caching
COPY pyproject.toml uv.lock* requirements.txt ./

# Install dependencies
RUN uv pip install --system -r requirements.txt

COPY . .

CMD ["python", "main.py"]
