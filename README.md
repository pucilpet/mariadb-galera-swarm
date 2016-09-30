# MySQL Galera on Kontena or Docker Swarm Mode

Forked from ["jakolehm/docker-galera-mariadb-10.0"](https://github.com/jakolehm/docker-galera-mariadb-10.0)

Changes:
 - Add support for Docker Swarm Mode by specifying `NODE_ADDRESS=eth0` when
   creating service.
