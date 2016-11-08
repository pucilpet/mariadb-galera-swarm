#!/bin/bash

# Exit on errors but report line number
set -e
err_report() {
    echo "start.sh: Error on line $1"
}
trap 'err_report $LINENO' ERR

# Set 'TRACE=y' environment variable to see detailed output for debugging
if [ "$TRACE" = "y" ]; then
	set -x
fi

if [ -z "$XTRABACKUP_PASSWORD" ]; then
	echo "XTRABACKUP_PASSWORD not set"
	exit 1
fi

CLUSTERCHECK_PASSWORD=${CLUSTERCHECK_PASSWORD:-$(echo "$XTRABACKUP_PASSWORD" | sha256sum | awk '{print $1;}')}
CLUSTER_NAME=${CLUSTER_NAME:-cluster}
GCOMM_MINIMUM=${GCOMM_MINIMUM:-2}
GCOMM=""
MYSQL_MODE_ARGS=""

#
# Resolve node address
#
if [ -z "$NODE_ADDRESS" ]; then
	# Support Weave/Kontena
	NODE_ADDRESS=$(ip addr | awk '/inet/ && /ethwe/{sub(/\/.*$/,"",$2); print $2}')
fi
if [ -z "$NODE_ADDRESS" ]; then
	# Support Docker Swarm Mode
	NODE_ADDRESS=$(ip addr | awk '/inet/ && /eth0/{sub(/\/.*$/,"",$2); print $2}')
elif [[ "$NODE_ADDRESS" =~ [a-zA-Z][a-zA-Z0-9:]+ ]]; then
	# Support interface - e.g. Docker Swarm Mode uses eth0
	NODE_ADDRESS=$(ip addr | awk "/inet/ && / $NODE_ADDRESS\$/{sub(/\\/.*$/,\"\",\$2); print \$2}" | head -n 1)
elif ! [[ "$NODE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	# Support grep pattern. E.g. ^10.0.1.*
	NODE_ADDRESS=$(getent hosts $(hostname) | grep -e "$NODE_ADDRESS")
fi
if ! [[ "$NODE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Could not determine NODE_ADDRESS: $NODE_ADDRESS"
	exit 1
fi

# Allow for easily adding more startup scripts
if [ -f /usr/local/lib/startup.sh ]; then
	source /usr/local/lib/startup.sh
fi

#
# Start modes:
#  - sleep - Useful for running the container without MySQL, e.g. for running innobackupex restore
#  - no-galera - Useful for running mysql_upgrade
#  - seed - Start a new cluster - run only once and use 'node' after cluster is started
#  - node - Join an existing cluster
#
case "$1" in
	sleep)
		echo "Sleeping forever..."
		sleep infinity
		exit
		;;
	no-galera)
		echo "Starting with Galera disabled"
		shift 1
		gosu mysql mysqld --console \
			--wsrep-on=OFF \
			--default-time-zone="+00:00" \
			"$@" 2>&1
		exit
		;;
	seed)
		MYSQL_MODE_ARGS+=" --wsrep-on=ON --wsrep-new-cluster"
		# bootstrapping
		if [ ! -f /var/lib/mysql/skip-cluster-bootstrapping ]; then
			echo "Bootstrapping cluster..."
			if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
				MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
				echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD"
			fi

			cat >/tmp/bootstrap.sql <<EOF
CREATE USER IF NOT EXISTS 'xtrabackup'@'127.0.0.1' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
GRANT RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'127.0.0.1';
CREATE USER IF NOT EXISTS 'xtrabackup'@'localhost' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
GRANT RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
CREATE USER IF NOT EXISTS 'clustercheck'@'127.0.0.1' IDENTIFIED BY '$CLUSTERCHECK_PASSWORD';
GRANT PROCESS ON *.* TO 'clustercheck'@'127.0.0.1';
CREATE USER IF NOT EXISTS 'clustercheck'@'localhost' IDENTIFIED BY '$CLUSTERCHECK_PASSWORD';
GRANT PROCESS ON *.* TO 'clustercheck'@'localhost';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1';
SET PASSWORD FOR 'root'@'127.0.0.1' = PASSWORD('$MYSQL_ROOT_PASSWORD');
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'localhost';
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$MYSQL_ROOT_PASSWORD');
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
EOF

			if [ "$MYSQL_DATABASE" ]; then
				echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> /tmp/bootstrap.sql
			fi

			if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
				echo "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> /tmp/bootstrap.sql
				if [ "$MYSQL_DATABASE" ]; then
					echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> /tmp/bootstrap.sql
				fi
			fi
			echo "FLUSH PRIVILEGES;" >> /tmp/bootstrap.sql

			MYSQL_MODE_ARGS+=" --init-file=/tmp/bootstrap.sql"
			touch /var/lib/mysql/skip-cluster-bootstrapping
		fi

		shift 1
		echo "Starting seed node"
		;;
	node)
		MYSQL_MODE_ARGS+=" --wsrep-on=ON"
		if [ -z "$2" ]; then
			echo "Missing master node address"
			exit 1
		fi
		ADDRS="$2"
		RESOLVE=0
		while true; do
			SEP=""
			GCOMM=""
			for ADDR in ${ADDRS//,/ }; do
				if [[ "$ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
					GCOMM+="$SEP$ADDR"
				else
					RESOLVE=1
					GCOMM+="$SEP$(getent hosts "$ADDR" | awk '{ print $1 }' | paste -sd ",")"
				fi
				if [ -n "$GCOMM" ]; then
					SEP=,
				fi
			done
			GCOMM=${GCOMM%%,}                        # strip trailing commas
			GCOMM=$(echo "$GCOMM" | sed 's/,\+/,/g') # strip duplicate commas

			# It is possible that containers on other nodes aren't running yet and should be waited on
			# before trying to start. For example, this occurs when updated container images are being pulled
			# by `docker service update <service>` or on a full cluster power loss
			COUNT=$(echo "$GCOMM" | tr ',' "\n" | sort -u | grep -v -e "^$NODE_ADDRESS\$" | wc -l)
			if [ $RESOLVE -eq 1 -a $COUNT -lt $(($GCOMM_MINIMUM - 1)) ]; then
				echo "Waiting for at least $GCOMM_MINIMUM IP addresses to resolve..."
				sleep 3
			else
				break
			fi
		done
		shift 2
		echo "Starting node, connecting to gcomm://$GCOMM"
		;;
	*)
		echo "sleep|no-galera|seed|node <othernode>,..."
		exit 1
esac

# start processes
set +e -m

function shutdown () {
	echo Shutting down
	test -s /var/run/mysql/mysqld.pid && kill -TERM $(cat /var/run/mysql/mysqld.pid)
}
trap shutdown TERM INT

galera-healthcheck -user=clustercheck -password="$CLUSTERCHECK_PASSWORD" -availWhenDonor=false -pidfile=/var/run/galera-healthcheck.pid &
gosu mysql mysqld.sh --console \
	$MYSQL_MODE_ARGS \
	--wsrep_cluster_name="$CLUSTER_NAME" \
	--wsrep_cluster_address="gcomm://$GCOMM" \
	--wsrep_node_address="$NODE_ADDRESS:4567" \
	--wsrep_sst_auth="xtrabackup:$XTRABACKUP_PASSWORD" \
	--default-time-zone="+00:00" \
	"$@" 2>&1 &
wait $!
RC=$?

test -s /var/run/galera-healthcheck.pid && kill $(cat /var/run/galera-healthcheck.pid)

exit $RC
