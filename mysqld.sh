#!/bin/bash
#
# This script tries to start mysqld with the right parameters to join an existing cluster
# or create a new one if the old one cannot be joined
#

LOG_MESSAGE="Docker startscript: "
OPT="$@"
START=""

function do_install_db {
	if ! test -d /var/lib/mysql/mysql; then
		echo "${LOG_MESSAGE} Initializing MariaDb data directory..."
		if ! mysql_install_db; then
			echo "${LOG_MESSAGE} Failed to initialized data directory. Will hope for the best..."
			return 1
		fi
	fi
	return 0
}

function check_nodes {
	for node in ${1//,/ }; do
		[ "$node" = "$2" ] && continue
		if curl -f -o - http://$node:8081 && echo; then
			echo "${LOG_MESSAGE} Node at $node is healthy!"
			return 0
		fi
	done
	return 1
}

if [[ "$OPT" =~ /--wsrep-new-cluster/ ]]
then
	# --wsrep-new-cluster is used for the "seed" node so no recovery used
	echo "${LOG_MESSAGE} Starting a new cluster..."
	do_install_db

elif test -f /var/lib/mysql/wsrep-new-cluster
then
	# flag file indicating new cluster needed, possibly easier than using "seed" in some cases
	echo "${LOG_MESSAGE} Starting a new cluster (because of flag file)..."
	rm -f /var/lib/mysql/wsrep-new-cluster
	do_install_db
	START="--wsrep-new-cluster"

elif ! test -f /var/lib/mysql/ibdata1
then
	# skip recovery on empty data directory
	echo "${LOG_MESSAGE} No ibdata1 found, starting a fresh node..."
	do_install_db

elif test -f /var/lib/mysql/gvwstate.dat
then
    # gvwstate.dat indicates that wsrep_cluster_status was previously Primary so let pc.recovery do it's thing.
	echo "${LOG_MESSAGE} gvwstate.dat file found, relying on pc.recovery to restore cluster state..."

else
	# try to recover state from grastate.dat or logfile
	POSITION=''
	if ! test -f /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} Missing grastate.dat file..."
	elif ! grep -q 'seqno:' /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} Invalid grastate.dat file..."
	elif grep -q '00000000-0000-0000-0000-000000000000' /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} uuid is not known..."
	else
		uuid=$(sed -n 's/^uuid:\s*//' /var/lib/mysql/grastate.dat)
		seqno=$(sed -n 's/^seqno:\s*//' /var/lib/mysql/grastate.dat)
		if [ "$seqno" = "-1" ]; then
			echo "${LOG_MESSAGE} uuid is known but seqno is not..."
		else
			POSITION="$uuid:$seqno"
			echo "${LOG_MESSAGE} Recovered position from grastate.dat: $POSITION"
		fi
	fi

	if test -z "$POSITION"; then
		echo "${LOG_MESSAGE} --------------------------------------------------"
		echo "${LOG_MESSAGE} Attempting to recover GTID positon..."

		tmpfile=$(mktemp -t wsrep_recover.XXXXXX)
		mysqld  --wsrep-on=ON \
				--wsrep_sst_method=skip \
				--wsrep_cluster_address=gcomm:// \
				--skip-networking \
				--wsrep-recover 2> $tmpfile
		if [ $? -ne 0 ]; then cat $tmpfile; else grep 'WSREP' $tmpfile; fi
		echo "${LOG_MESSAGE} --------------------------------------------------"

		POSITION=$(sed -n 's/.*WSREP: Recovered position:\s*//p' $tmpfile)
		rm -f $tmpfile
	fi

	# If unable to find position then something is really wrong and cluster is possibly corrupt
	if test -z "$POSITION"; then
		echo "${LOG_MESSAGE} We found no wsrep position!"
		echo "${LOG_MESSAGE} Refusing to start since something is seriously wrong.."
		echo "${LOG_MESSAGE} "
		echo "${LOG_MESSAGE}       VvVvVv         "
		echo "${LOG_MESSAGE}       |-  -|    //   "
		echo "${LOG_MESSAGE}  <----|O  O|---<<<   "
		echo "${LOG_MESSAGE}       |  D |    \\\\ "
		echo "${LOG_MESSAGE}       | () |         "
		echo "${LOG_MESSAGE}        \\__/         "
		echo "${LOG_MESSAGE} "
		exit 1
	fi

	# Communicate to other nodes to find if there is a Primary Component and if not
	# figure out who has the highest recovery position to be the bootstrapper
	NODE_ADDRESS=$(sed -E 's#.*--wsrep_node_address=([0-9.]+):4567.*#\1#' <<< "$OPT")
	GCOMM=$(sed -E 's#.*gcomm://([0-9.,]+)#\1#' <<< "$OPT")
	LISTEN_PORT=3309

	# Use the galera-healthcheck server to determine if a healthy node exists
	# Try multiple times since we really don't want to start a new cluster...
	for i in $(seq 1 6); do
		if check_nodes $GCOMM $NODE_ADDRESS
		then
			echo "${LOG_MESSAGE} Found a healthy node! Attempting to join..."
			START="--wsrep_start_position=$POSITION"
			break
		else
			echo "${LOG_MESSAGE} Waiting for a healthy node to appear..."
			sleep 10
		fi
	done

	if test -z "$START"
	then
		# If no healthy node is running then collect uuid:seqno from other nodes and
		# use them to determine which node should do the bootstrap
		echo "${LOG_MESSAGE} Collecting grastate.dat info from other nodes..."
		set -m
		tmpfile=$(mktemp -t socat.XXXX)
		socat -u TCP-LISTEN:$LISTEN_PORT,bind=$NODE_ADDRESS,fork OPEN:$tmpfile,append &
		PID_SERVER=$!

		# Send uuid:seqno to other nodes - every 5 seconds for 60 seconds
		while true; do
			for node in ${GCOMM//,/ }; do
				[ "$node" = "$NODE_ADDRESS" ] && continue
				socat - TCP:$node:$LISTEN_PORT <<< "$NODE_ADDRESS:$POSITION"
			done
			sleep 5
		done &
		PID_CLIENT=$!

		sleep 60
		kill $PID_SERVER
		kill $PID_CLIENT
		set +m

		if check_nodes $GCOMM $NODE_ADDRESS
		then
			# Check once more for healthy nodes in case one came up while we were waiting
			echo "${LOG_MESSAGE} Found a healthy node, attempting to join..."
			START="--wsrep_start_position=$POSITION"

		elif test -s $tmpfile
		then
			# We now have a collection of <ip>:<uuid>:<seqno> for all running nodes.
			MY_SEQNO=${POSITION#*:}
			BEST_SEQNO=$(awk -F: '{print $3}' | sort -nu | tail -n 1)
			if [ "$MY_SEQNO" -gt "$BEST_SEQNO" ]; then
				# This node is newer than all the others, start a new cluster
				START="--wsrep-new-cluster"
			elif [ "$MY_SEQNO" -lt "$BEST_SEQNO" ]; then
				# This node is older than another node, be a joiner
				START="--wsrep_start_position=$POSITION"
			else
				# This and another node or nodes are the newest, lowest IP wins
				LOWEST_IP=$(awk -F: "/:$BEST_SEQNO$/{print \$1}" | sort -u | head -n 1)
				if [ "$NODE_ADDRESS" < "$LOWEST_IP" ]; then
					START="--wsrep-new-cluster"
				else
					START="--wsrep_start_position=$POSITION"
				fi
			fi
		else
			# Did not receive communication from other nodes, starting a new cluster
			START="--wsrep-new-cluster"
		fi
	fi
fi

# Start mysqld
echo "${LOG_MESSAGE} ----------------------------------"
echo "${LOG_MESSAGE} Starting with options: $OPT $START"
exec mysqld $OPT $START

