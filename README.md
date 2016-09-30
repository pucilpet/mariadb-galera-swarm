# MySQL Galera on Kontena or Docker Swarm Mode

Forked from ["jakolehm/docker-galera-mariadb-10.0"](https://github.com/jakolehm/docker-galera-mariadb-10.0)

Changes:
 - Rebase on official mariadb:10.1 image
 - Add support for Docker Swarm Mode by specifying `NODE_ADDRESS=eth0` when
   creating service.
 - Fix running mysqld as root using gosu
 - TODO - Add support for HEALTHCHECK for Docker 1.12

