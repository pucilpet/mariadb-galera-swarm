FROM mariadb:10.1

# Install host for DNS resolution
RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
      curl \
      galera-arbitrator-3 \
      host \
    && rm -rf /tmp/* /var/cache/apk/* /var/lib/apt/lists/*

COPY conf.d/* /etc/mysql/conf.d/
COPY bin/galera-healthcheck /usr/local/bin/galera-healthcheck
COPY mysqld.sh /usr/local/bin/mysqld.sh
COPY start.sh /usr/local/bin/start.sh

EXPOSE 3306 4444 4567 4567/udp 4568

#HEALTHCHECK CMD ["docker-healthcheck"]

ENTRYPOINT ["start.sh"]
