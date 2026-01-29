ARG BUILD_FROM=ghcr.io/home-assistant/${BUILD_ARCH}-base:latest
FROM ${BUILD_FROM}

# Dependencias para ejecutar el script
RUN apk add --no-cache \
    bash \
    openssl \
    openssh-client \
    ca-certificates \
    jq

# Empaquetamos el script y el entrypoint
RUN mkdir -p /opt/renew
COPY renew-cert.sh /opt/renew/renew-cert.sh
COPY run.sh /run.sh

RUN chmod +x /opt/renew/renew-cert.sh /run.sh

CMD ["/bin/sh", "/run.sh"]