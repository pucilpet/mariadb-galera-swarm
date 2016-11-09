#!/bin/bash

# Simple mysqld start script for containers
# We do not use mysqld_safe

MYSQLD=mysqld
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

if [[ "$OPT" =~ /--wsrep-new-cluster/ ]]
then
	# --wsrep-new-cluster is used for the "seed" node so no recovery used
	echo "${LOG_MESSAGE} Starting a new cluster..."
	do_install_db

elif ! test -f /var/lib/mysql/ibdata1
then
	# skip recovery on empty data directory
	echo "${LOG_MESSAGE} No ibdata1 found, starting a fresh node..."
	do_install_db

elif test -f /var/lib/mysql/gvwstate.dat
then
    # gvwstate.dat indicates that wsrep_cluster_status was previously Primary so let pc.recovery do it's thing.
	echo "${LOG_MESSAGE} gvwstate.dat file found, relying on pc.recovery to restore cluster state..."

elif test -f /var/lib/mysql/grastate.dat && ! grep -qe 'seqno:\s*-1' /var/lib/mysql/grastate.dat
then
	# valid grastate.dat should be recoverable without recovering GTID
	echo "${LOG_MESSAGE} grastate.dat file found with valid seqno, relying on state data for recovery..."

else
	# grastate.dat with -1 seqno indicates unclean shutdown so recover GTID position
	# missing grastate.dat means manual tinkering or restore from backup?
	echo  "${LOG_MESSAGE} Attempting to recover GTID positon..."
	tmpfile=$(mktemp -t wsrep_recover.XXXXXX)
	if test -z "$tmpfile" || ! $MYSQLD $OPT --wsrep-recover 2>${tmpfile}; then
		echo "${LOG_MESSAGE} An error happened while trying to '--wsrep-recover'"
		test -f $tmpfile && { cat $tmpfile; rm -f $tmpfile; }
		exit 1
	fi
	wsrep_start_position=$(sed -n 's/.*Recovered\ position:\s*//p' $tmpfile | head -n 1)

	if test -n "$wsrep_start_position"; then
		echo "${LOG_MESSAGE} ----------------------------------"
		grep -F 'Recovered position:' $tmpfile
		echo "${LOG_MESSAGE} ----------------------------------"
		START="--wsrep_start_position=$wsrep_start_position"
	elif grep -qF 'skipping position recovery' $tmpfile; then
		echo "${LOG_MESSAGE} Position recovery skipped."
	else
		echo "${LOG_MESSAGE} We found no wsrep position!"
		echo "${LOG_MESSAGE} Most likely Galera is not configured, so we refuse to start"
		exit 1
	fi
	rm -f $tmpfile
fi

# Start mysqld
echo  "${LOG_MESSAGE} Starting with options: $OPT $START"
exec $MYSQLD $OPT $START

