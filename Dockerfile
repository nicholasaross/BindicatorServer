FROM python:3.13-slim

# Install Chromium and its driver (Debian packages keep them in sync)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        chromium \
        chromium-driver \
    && rm -rf /var/lib/apt/lists/*

# Selenium needs to find the Debian-packaged binary
ENV CHROME_BIN=/usr/bin/chromium
ENV CHROMEDRIVER_PATH=/usr/bin/chromedriver

WORKDIR /app

COPY pyproject.toml ./
RUN pip install --no-cache-dir .  2>/dev/null; true

# Install runtime deps explicitly (pyproject.toml is informational;
# we pin what we need here for a reproducible image)
RUN pip install --no-cache-dir \
    fastapi \
    uvicorn[standard] \
    beautifulsoup4 \
    selenium \
    apscheduler \
    tzdata

COPY bindicator.py server.py ./

EXPOSE 8000

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
