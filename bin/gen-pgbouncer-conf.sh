#!/usr/bin/env bash

is-enabled() {
  ( shopt -s extglob nocasematch
    [[ $1 == @(1|true|yes|on) ]]
  )
}

POSTGRES_URLS=${PGBOUNCER_URLS:-DATABASE_URL}
POOL_MODE=${PGBOUNCER_POOL_MODE:-transaction}
SERVER_RESET_QUERY=${PGBOUNCER_SERVER_RESET_QUERY}
n=1

# if the SERVER_RESET_QUERY and pool mode is session, pgbouncer recommends DISCARD ALL be the default
# http://pgbouncer.projects.pgfoundry.org/doc/faq.html#_what_should_my_server_reset_query_be
if [ -z "${SERVER_RESET_QUERY}" ] &&  [ "$POOL_MODE" == "session" ]; then
  SERVER_RESET_QUERY="DISCARD ALL;"
fi

cat >> /app/vendor/pgbouncer/pgbouncer.ini << EOFEOF
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6000
auth_type = md5
auth_file = /app/vendor/pgbouncer/users.txt

; When server connection is released back to pool:
;   session      - after client disconnects
;   transaction  - after transaction finishes
;   statement    - after statement finishes
pool_mode = ${POOL_MODE}
server_reset_query = ${SERVER_RESET_QUERY}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN:-100}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE:-5}
min_pool_size = ${PGBOUNCER_MIN_POOL_SIZE:-0}
reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE:-1}
reserve_pool_timeout = ${PGBOUNCER_RESERVE_POOL_TIMEOUT:-5.0}
server_lifetime = ${PGBOUNCER_SERVER_LIFETIME:-3600}
server_idle_timeout = ${PGBOUNCER_SERVER_IDLE_TIMEOUT:-600}
log_connections = ${PGBOUNCER_LOG_CONNECTIONS:-1}
log_disconnections = ${PGBOUNCER_LOG_DISCONNECTIONS:-1}
log_pooler_errors = ${PGBOUNCER_LOG_POOLER_ERRORS:-1}
stats_period = ${PGBOUNCER_STATS_PERIOD:-60}
stats_users = ${PGBOUNCER_STATS_USER:-none}
pkt_buf = ${PGBOUNCER_PKT_BUF:-4096}
sbuf_loopcnt = ${PGBOUNCER_SBUF_LOOPCNT:-20}
server_tls_sslmode = ${PGBOUNCER_SERVER_TLS_SSLMODE:-require}
[databases]
EOFEOF

for POSTGRES_URL in $POSTGRES_URLS
do
  eval POSTGRES_URL_VALUE=\$$POSTGRES_URL
  IFS=':' read DB_USER DB_PASS DB_HOST DB_PORT DB_NAME <<< $(echo $POSTGRES_URL_VALUE | perl -lne 'print "$1:$2:$3:$4:$5" if /^postgres(?:ql)?:\/\/([^:]*):([^@]*)@(.*?):(.*?)\/(.*?)(?:\?.*)?$/')

  # unescape the password
  UNESCAPED_DB_PASS=${DB_PASS//+/ }
  UNESCAPED_DB_PASS=${UNESCAPED_DB_PASS//%/\\x}
  UNESCAPED_DB_PASS="$(printf '%b' ${UNESCAPED_DB_PASS})"

  DB_MD5_PASS="md5"`echo -n ${UNESCAPED_DB_PASS}${DB_USER} | md5sum | awk '{print $1}'`

  CLIENT_DB_NAME="db${n}"

  echo "Setting ${POSTGRES_URL}_PGBOUNCER config var"

  if [ "$PGBOUNCER_PREPARED_STATEMENTS" == "false" ]
  then
    export ${POSTGRES_URL}_PGBOUNCER=postgres://$DB_USER:$DB_PASS@127.0.0.1:6000/$CLIENT_DB_NAME?prepared_statements=false
  else
    export ${POSTGRES_URL}_PGBOUNCER=postgres://$DB_USER:$DB_PASS@127.0.0.1:6000/$CLIENT_DB_NAME
  fi

  cat >> /app/vendor/pgbouncer/users.txt << EOFEOF
"$DB_USER" "$DB_MD5_PASS"
EOFEOF

  cat >> /app/vendor/pgbouncer/pgbouncer.ini << EOFEOF
$CLIENT_DB_NAME= host=$DB_HOST port=$DB_PORT dbname=$DB_NAME
EOFEOF

  let "n += 1"
done

# add PGBOUNCER_STATS_USER to users.txt
if is-enabled "${PGBOUNCER_MONITORING_ENABLED:-0}"; then
  if [ -z "$PGBOUNCER_STATS_USER" ] || [ -z "$PGBOUNCER_STATS_PASSWORD" ]; then
    echo "PGBOUNCER_MONITORING_ENABLED environment variable is set but PGBOUNCER_STATS_USER and/or PGBOUNCER_STATS_PASSWORD is missing."
  else
    PGBOUNCER_STATS_PASSWORD_MD5="md5"`echo -n ${PGBOUNCER_STATS_PASSWORD}${PGBOUNCER_STATS_USER} | md5sum | awk '{print $1}'`
    cat >> /app/vendor/pgbouncer/users.txt << EOFEOF
"$PGBOUNCER_STATS_USER" "$PGBOUNCER_STATS_PASSWORD_MD5"
EOFEOF
  fi
fi

chmod go-rwx /app/vendor/pgbouncer/*
