
# Flask + Gunicorn container (multi-version via SITE_SRC)
FROM python:3.11-slim

# Allow selecting v1/v2/v3 via build-arg (keeps your Jenkins usage intact)
ARG SITE_SRC=web/v1

WORKDIR /app

# Copy the selected version's Flask app into the image
# Expecting: app.py, templates/, static/, optional requirements.txt
COPY ${SITE_SRC}/ /app/

# Install dependencies (prefer pinned via requirements.txt if present)
RUN set -eux; \
    if [ -f requirements.txt ]; then \
      pip install --no-cache-dir -r requirements.txt; \
    else \
      pip install --no-cache-dir flask gunicorn; \
    fi

# App Service expects the container to listen on port 80
ENV PORT=80
EXPOSE 80

# Healthcheck: hit the Flask root via loopback
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; print('OK') if urllib.request.urlopen('http://127.0.0.1:80/').status==200 else exit(1)"

# Start Gunicorn; module:variable is app:app (update if you rename)
CMD ["gunicorn", "--bind", "0.0.0.0:80", "app:app"]
