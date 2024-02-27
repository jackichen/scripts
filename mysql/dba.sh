#!/usr/bin/env bash
BASE="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

if [[ ! -f ${BASE}/../util.sh ]] || [[ ! -f ${BASE}/util.sh ]]; then
    echo "Missing util.sh"
    exit 1
fi

source ${BASE}/../util.sh # log_info/log_error/is_local
source ${BASE}/util.sh  # start_mysqld

function usage()
{
    echo -e "Utility to manage mysql local or remote (via SSH) database server\n\n\
SYNOPSIS:\n\
    $0 [OPTIONs] COMMAND\n\n\
OPTIONs:\n\
    -b | --base=<MYSQL_INSTALL_DIR>: Specify mysql installation directory\n\
    -d | --data=<MYSQL_DATADIR>: Specify mysql data directory\n\
    -p | --port=<PORT>: base port of multi master cluster\n\
    -m | --multi-master: For multi master cluster\n\
    --master-count <NUM> | --master-count=<NUM> : number of master servers in multi master cluster\n\
    --master-count=<NUM> : number of master servers in multi master cluster\n\
    -H | --host=<hostname>: Specify hostname/ip to deploy mysql database server, localhost by default\n\
    -h | --help: Print this help message\n\n\
COMMAND:\n\
    start: Start database server if not started\n\
    stop: Stop database server if started\n\
    kill: Kill database server if started\n\
    restart: Stop database server if started, and start database server again\n\
    status: Check whether database server is running\n\
    gstart: start mysqld server with gdb\n\
    gdb: start gdb to attach mysqld server if running\n\
    kill: kill mysqld server if running\n\
    conn: Login to the database server with root user if started"
}

# parse options
CC_PORT=0
FOR_MM=0
MASTER_COUNT=0
OPT_END=0
while [[ ${OPT_END} -eq 0 ]]; do
    case "$1" in
    -b | --base)
        shift
        MYSQL_BASE=$(get_key_value "$1")
        shift;;
    --base=*)
        MYSQL_BASE=$(get_key_value "$1")
        shift;;
    -d | --data)
        shift
        DATA_HOME=$(get_key_value "$1")
        shift;;
    --data=*)
        DATA_HOME=$(get_key_value "$1")
        shift;;
    -p | --port)
        shift
        CC_PORT=$(get_key_value "$1")
        shift;;
    --port=*)
        CC_PORT=$(get_key_value "$1")
        shift;;
    -m | --multi-master)
        FOR_MM=1
        shift;;
    --master-count)
        shift
        MASTER_COUNT=$(get_key_value "$1")
        shift;;
    --master-count)
        shift
        MASTER_COUNT=$(get_key_value "$1")
        shift;;
    --master-count=*)
        MASTER_COUNT=$(get_key_value "$1")
        shift;;
    -H | --host)
        shift
        HOST=$(get_key_value "$1")
        shift;;
    --host=*)
        HOST=$(get_key_value "$1")
        shift;;
    -h | --help)
        usage
        exit 0;;
    *)
        OPT_END=1;;
    esac
done

# check parameters
[[ -z ${MYSQL_BASE} ]] && fatal_error "Missing parameter for --base"
[[ -z ${DATA_HOME} ]] && fatal_error "Missing parameter for --data"
[[ ! -z ${HOST} ]] || HOST=127.0.0.1

if [[ ${FOR_MM} -eq 1 ]]; then
  [[ -z ${CC_PORT} ]] && log_error "Missing parameter for --port" && exit 1
  CC_HOME=${DATA_HOME}/cc_${CC_PORT}
  GS_PORT=`expr ${CC_PORT} + 20`
  GS_HOME=${DATA_HOME}/gs_${GS_PORT}
  GR_PORT=`expr ${CC_PORT} + 21`
  GR_HOME=${DATA_HOME}/gr_${GR_PORT}
  GA_PORT=`expr ${CC_PORT} + 22`
  GA_HOME=${DATA_HOME}/gr_${GA_PORT}
  # execute command
  case "$1" in
    "start")
      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${CC_PORT} ${CC_HOME}/my.cnf
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        RW_HOME=${DATA_HOME}/${RW_PORT}
        start_mysqld ${MYSQL_BASE}/bin ${HOST} ${RW_PORT} ${RW_HOME}/my.cnf
        ((MM_ID++))
      done
      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${GS_PORT} ${GS_HOME}/my.cnf
      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${GR_PORT} ${GR_HOME}/my.cnf
      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${GA_PORT} ${GA_HOME}/my.cnf
      ;;
    "stop")
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${GR_PORT}
      yy
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${GA_PORT}
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${GS_PORT}
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${RW_PORT}
        ((MM_ID++))
      done
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${CC_PORT}
      ;;
    "kill")
      kill_mysqld ${MYSQL_BASE}/bin ${HOST} ${GR_PORT}
      kill_mysqld ${MYSQL_BASE}/bin ${HOST} ${GA_PORT}
      kill_mysqld ${MYSQL_BASE}/bin ${HOST} ${GS_PORT}
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        kill_mysqld ${MYSQL_BASE}/bin ${HOST} ${RW_PORT}
        ((MM_ID++))
      done
      kill_mysqld ${MYSQL_BASE}/bin ${HOST} ${CC_PORT}
      ;;
    "restart")
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${GR_PORT}
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${GA_PORT}
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${GS_PORT}
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${RW_PORT}
        ((MM_ID++))
      done
      stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${CC_PORT}

      log_info "Waiting for shutdown complete ..."
      sleep 30

      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${CC_PORT} ${CC_HOME}/my.cnf
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        RW_HOME=${DATA_HOME}/${RW_PORT}
        start_mysqld ${MYSQL_BASE}/bin ${HOST} ${RW_PORT} ${RW_HOME}/my.cnf
        ((MM_ID++))
      done
      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${GS_PORT} ${GS_HOME}/my.cnf
      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${GR_PORT} ${GR_HOME}/my.cnf
      start_mysqld ${MYSQL_BASE}/bin ${HOST} ${GA_PORT} ${GA_HOME}/my.cnf
      ;;
    "status")
      pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${CC_PORT})
      if [[ ${pid} -ne 0 ]]; then
          log_info "PolarDB Cache Center server is running with pid=${pid} at ${HOST}:${CC_PORT}"
          ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${CC_PORT} -e "SELECT * FROM INFORMATION_SCHEMA.INNODB_CLUSTER_REGISTRY;"
          ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${CC_PORT} -e "SHOW POLAR GLOBAL STANDBYS;"
      else
          log_info "PolarDB Cache Center server is not running at ${HOST}:${CC_PORT}"
      fi
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${RW_PORT})
        if [[ ${pid} -ne 0 ]]; then
            log_info "PolarDB MultiMaster server is running with pid=${pid} at ${HOST}:${RW_PORT}"
        else
            log_info "PolarDB MultiMaster server is not running at ${HOST}:${RW_PORT}"
        fi
        ((MM_ID++))
      done
      pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${GS_PORT})
      if [[ ${pid} -ne 0 ]]; then
          log_info "PolarDB Global Standby server is running with pid=${pid} at ${HOST}:${GS_PORT}"
          ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${GS_PORT} -e "SHOW POLAR REPLICAS;"
      else
          log_info "PolarDB Global Standby server is not running at ${HOST}:${GS_PORT}"
      fi
      pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${GR_PORT})
      if [[ ${pid} -ne 0 ]]; then
          log_info "PolarDB Global Replica server is running with pid=${pid} at ${HOST}:${GR_PORT}"
      else
          log_info "PolarDB Global Replica server is not running at ${HOST}:${GR_PORT}"
      fi
      pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${GA_PORT})
      if [[ ${pid} -ne 0 ]]; then
          log_info "PolarDB Global AP RO server is running with pid=${pid} at ${HOST}:${GA_PORT}"
      else
          log_info "PolarDB Global AP RO server is not running at ${HOST}:${GA_PORT}"
      fi
      ;;
    *)
         fatal_error "Invalid command: $1";;
  esac
  exit 0
fi

MY_CNF=${DATA_HOME}/my.cnf
if [[ $(is_local ${HOST}) -eq 1 ]]; then
    log_info "Check parameters locally ..."
    [[ ! -x ${MYSQL_BASE}/bin/mysqld ]] && fatal_error "Invalid value for parameter --base"
    [[ ! -f ${MY_CNF} ]] && fatal_error "Can't find my.cnf under ${DATA_HOME}"
else
    log_info "Check parameters in remote ..."
    stat=$(ssh ${HOST} "[[ -x ${MYSQL_BASE}/bin/mysqld ]] && echo 1 || echo 0")
    [[ ${stat} -eq 0 ]] && fatal_error "Invalid value for parameter --base"
    stat=$(ssh ${HOST} "[[ -f ${MY_CNF} ]] && echo 1 || echo 0")
    [[ ${stat} -eq 0 ]] && fatal_error "Can't find my.cnf under ${DATA_HOME}"
fi

# parse mysql parameters
get_mysql_params ${MY_CNF} ${HOST}

# execute command
case "$1" in
"start")
    start_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT} ${MY_CNF}
    ;;
"stop")
    stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT}
    ;;
"kill")
    kill_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT}
    ;;
"restart")
    stop_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT}
    log_info "Waiting for shutdown complete ..."
    sleep 30
    start_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT} ${MY_CNF}
    ;;
"status")
    pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT})
    if [[ ${pid} -ne 0 ]]; then
        log_info "Database server is running with pid=${pid} at ${HOST}:${PORT}"
    else
        log_info "Database server is not running at ${HOST}:${PORT}"
    fi
    ;;
"conn")
    pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT})
    [[ ${pid} -eq 0 ]] && fatal_error "Database server is not running at ${HOST}:${PORT}"
    cmd="${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${PORT}"
    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        ${cmd}
    else
        ssh -t ${HOST} ${cmd}
    fi
    ;;
"gdb")
    pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT})
    [[ ${pid} -eq 0 ]] && fatal_error "Database server is not running at ${HOST}:${PORT}"
    cmd="gdb -p $pid"
    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        ${cmd}
    else
        ssh -t ${HOST} ${cmd}
    fi
    ;;
"pstack")
    pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT})
    [[ ${pid} -eq 0 ]] && fatal_error "Database server is not running at ${HOST}:${PORT}"
    cmd="pstack $pid"
    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        ${cmd}
    else
        ssh -t ${HOST} ${cmd}
    fi
    ;;
"gstart")
    pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT})
    if [[ ${pid} -ne 0 ]]; then
        log_info "Database server is already running with pid=${pid} at ${HOST}:${PORT}"
    else
        start_mysqld ${MYSQL_BASE}/bin ${HOST} ${PORT} ${MY_CNF} 1
    fi
    ;;
*)
    fatal_error "Invalid command: $1";;
esac

