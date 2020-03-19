Allows you to assign predictable static hostnames to each container.
This allows HAProxy to connect to each server reliably.

Requires a version of docker > 19.03
https://github.com/moby/moby/pull/39204

```
$ docker network create -d overlay --attachable haproxy
$ docker network create -d overlay --attachable galera
$ docker stack deploy --compose-file docker-compose.yml galera
```

