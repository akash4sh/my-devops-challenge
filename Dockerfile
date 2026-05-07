# ============================================================
# Stage 1 — builder
# ============================================================
FROM python:3.12-slim-bookworm AS builder

WORKDIR /build

# Copy requirements first so Docker reuses cache
# unless dependencies change, instead of rebuilding
# on every source-code change.
COPY app/requirements.txt .

RUN pip install --upgrade pip --no-cache-dir \
    && pip install --prefix=/install --no-cache-dir -r requirements.txt


# ============================================================
# Stage 2 — runtime
# ============================================================
FROM python:3.12-slim-bookworm AS runtime

# Create a non-root user and group for running the application.
RUN groupadd --system --gid 1000 appgroup \
    && useradd --system --uid 1000 --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy installed packages from builder stage only.
COPY --from=builder /install /usr/local

# Copy application source.
COPY app/ .

# Use port 8080 because non-root users cannot use port 80.
EXPOSE 8080

# Run the application as a non-root user.
USER appuser

CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--timeout", "30", \
     "--graceful-timeout", "25", \
     "--access-logfile", "-", \
     "main:app"]