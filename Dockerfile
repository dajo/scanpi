FROM ubuntu:24.04

# Install only essential packages and clean up in same layer
RUN apt update && apt install -y \
    python3-minimal \
    python3-flask \
    sane \
    sane-utils \
    imagemagick \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/* \
    && rm -rf /var/tmp/* \
    && find /usr/share/doc -type f -delete \
    && find /usr/share/man -type f -delete

WORKDIR /app

# Copy only necessary files
COPY app.py scan_adf.sh policy.xml ./
COPY templates/ templates/

# Set executable permissions
RUN chmod +x scan_adf.sh

EXPOSE 8080

# Use exec form for better signal handling
CMD ["python3", "app.py"]
