FROM python:3.11-slim

# Create a dedicated non-root system user and group
RUN groupadd --system appgroup \
    && useradd --system --no-create-home --gid appgroup appuser

WORKDIR /app

# Install dependencies as root before dropping privileges
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source
COPY app.py .

# Hand off ownership so the non-root user can read the files
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 5000

# Workers: 2 * vCPU + 1 is the standard formula; we default to 3 for a
# t2.micro (1 vCPU). Override with the GUNICORN_WORKERS env var at runtime.
CMD ["sh", "-c", "gunicorn \
    --bind 0.0.0.0:5000 \
    --workers ${GUNICORN_WORKERS:-3} \
    --worker-class sync \
    --timeout 120 \
    --access-logfile - \
    --error-logfile - \
    --log-level info \
    app:app"]
