# Dockerfile — IT-Stack ODOO wrapper
# Module 13 | Category: business | Phase: 3
# Base image: odoo:17

FROM odoo:17

# Labels
LABEL org.opencontainers.image.title="it-stack-odoo" \
      org.opencontainers.image.description="Odoo ERP and business management" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-odoo"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/odoo/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
