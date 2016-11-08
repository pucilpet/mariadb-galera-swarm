#!/bin/bash

# Simple mysqld start script for containers
# We do not use mysqld_safe

MYSQLD=mysqld
LOG_MESSAGE="Docker startscript: "
OPT="$@"
START=""

# Init mysql directory on first run
if ! test -d /var/lib/mysql/mysql && ! mysql_install_db; then
	echo "${LOG_MESSAGE} Tried to install mysql.* schema because /var/lib/mysql seemed empty"
	echo "${LOG_MESSAGE} it failed :("
fi

# Get the GTID position if possible, but skip this step if pc.recovery is enabled
if ! [[ "$OPT" =~ /--wsrep-new-cluster/ ]] && ! [ -f /var/lib/mysql/gvwstate.dat ]; then
	echo  "${LOG_MESSAGE} Recovering GTID positon"
	tmpfile=$(mktemp -t wsrep_recover.XXXXXX)
	if test -z "$tmpfile" || ! $MYSQLD $OPT --wsrep-recover 2>${tmpfile}; then
		echo "${LOG_MESSAGE} An error happened while trying to '--wsrep-recover'"
		test -f $tmpfile && { cat ${tmpfile}; rm -f ${tmpfile}; }
		exit 1
	fi
	wsrep_start_position=$(sed -n 's/.*Recovered\ position:\s*//p' ${tmpfile} | head -n 1)

	if test -z "$wsrep_start_position"; then
		if ! grep -q 'skipping position recovery'; then
			echo "${LOG_MESSAGE} We found no wsrep position!"
			echo "${LOG_MESSAGE} Most likely Galera is not configured, so we refuse to start"
			exit 1
		else
			echo "${LOG_MESSAGE} Position recovery skipped."
		fi
	else
		START="--wsrep_start_position=$wsrep_start_position"
	fi
	rm -f ${tmpfile}
fi

# Start mysqld
echo  "${LOG_MESSAGE} Starting with options: $OPT $START"
exec $MYSQLD $OPT $START

