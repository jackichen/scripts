#!/usr/bin/env bash
# mysql helper script not to run directly

# get mysql parameters from my.cnf
function __get_mysql_params_local()
{
    local MY_CNF=$1

    local stat=1
    if [[ -f ${MY_CNF} ]]; then
        stat=0
        DATADIR=`grep -iw datadir ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        PORT=`grep -iw port ${MY_CNF} | head -n1 | sed 's/ //g' | awk -F'=' '{print $2}'`
        SOCKET=`grep -iw socket ${MY_CNF} | head -n1 | sed 's/ //g' | awk -F'=' '{print $2}'`
        PID_FILE=`grep -iw 'pid-file' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        [[ -z ${PID_FILE} ]] && PID_FILE=`grep -iw 'pid_file' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        MYSQL_LOG=`grep -iw 'log-error' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        [[ -z ${MYSQL_LOG} ]] && MYSQL_LOG=`grep -iw 'log_error' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        PBD_NAME=`grep -iw loose_polar_temp_table_or_file_pbdname ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
    fi
    return $stat
}

function __get_mysql_params_remote()
{
    local MY_CNF=$1
    local HOST=$2

    local stat=$(ssh ${HOST} "[[ -f ${MY_CNF} ]] && echo 0 || echo 1")
    if [[ ${stat} -eq 0 ]]; then
        DATADIR=$(ssh ${HOST} grep -iw datadir ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}')
        PORT=`ssh ${HOST} grep -iw port ${MY_CNF} | head -n1 | sed 's/ //g' | awk -F'=' '{print $2}'`
        SOCKET=`ssh ${HOST} grep -iw socket ${MY_CNF} | head -n1 | sed 's/ //g' | awk -F'=' '{print $2}'`
        PID_FILE=`ssh ${HOST} grep -iw 'pid-file' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        [[ -z ${PID_FILE} ]] && PID_FILE=`ssh ${HOST} grep -iw 'pid_file' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        MYSQL_LOG=`ssh ${HOST} grep -iw 'log-error' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        [[ -z ${MYSQL_LOG} ]] && MYSQL_LOG=`ssh ${HOST} grep -iw 'log_error' ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
        PBD_NAME=`ssh ${HOST} grep -iw loose_polar_temp_table_or_file_pbdname ${MY_CNF} | sed 's/ //g' | awk -F'=' '{print $2}'`
    fi
    return $stat
}

function get_mysql_params()
{
    local MY_CNF=$1
    local HOST=${2:-127.0.0.1}

    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        __get_mysql_params_local $1
    else
        __get_mysql_params_remote $1 ${HOST}
    fi

    if [[ $? -eq 1 ]]; then
        log_error "No such file: ${MY_CNF}"
    else
        [[ -z ${DATADIR} ]] && log_error "datadir is not configured in ${MY_CNF}" || log_info "datadir is: ${DATADIR}"
        [[ -z ${PORT} ]] && log_error "port is not configured in ${MY_CNF}" || log_info "port is: ${PORT}"
        [[ -z ${SOCKET} ]] && log_error "socket is not configured in ${MY_CNF}" || log_info "socket is: ${SOCKET}"
        [[ -z ${PID_FILE} ]] && log_error "No pid-file or pid_file is configured in ${MY_CNF}" || log_info "mysql pid-file is: ${PID_FILE}"
        [[ -z ${MYSQL_LOG} ]] && log_error "No log-error or log_error is configured in ${MY_CNF}" || log_info "mysql error log is: ${MYSQL_LOG}"
        [[ ! -z ${PBD_NAME} ]] && [[ ${PBD_NAME} != "<PBD_NAME>" ]] && log_info "pbd name is: ${PBD_NAME}"
    fi
}

# validate mysql binary
function check_binary()
{
    local HOST=$1
    local MYSQL_BASE=$2
    local COPY_BIN=$3

    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        [[ -d ${MYSQL_BASE} ]] && [[ -x ${MYSQL_BASE}/bin/mysqld ]] && return 0 || return 1
    else
        if [[ ${COPY_BIN} -eq 1 ]]; then
            [[ -d ${MYSQL_BASE} ]] && [[ -x ${MYSQL_BASE}/bin/mysqld ]] || return 1
            log_info "copy mysql binary to remote host ..."
            scp -q -r ${MYSQL_BASE} ${HOST}:${MYSQL_BASE}
            [[ $? -ne 0 ]] && log_error "Failed to copy binary to remote host: ${HOST}" && return 1
        fi

        return $(ssh ${HOST} "[[ -d ${MYSQL_BASE} ]] && [[ -x ${MYSQL_BASE}/bin/mysqld ]] && echo 0 || echo 1")
    fi
}

# init home directory of mysql/polardb server
function init_mysql_datadir()
{
    local HOST=$1
    local DATA_HOME=$2
    local pfs=${3:-0}
    exec_cmd ${HOST} "/bin/rm -rf ${DATA_HOME}"
    exec_cmd ${HOST} "mkdir -p ${DATA_HOME}/log ${DATA_HOME}/tmp" || fatal_error "failed to init data directory"

    if [[ ${pfs} -eq 0 ]]; then
      exec_cmd ${HOST} "mkdir ${DATA_HOME}/data ${DATA_HOME}/blog" || fatal_error "failed to init data directory"
    fi
}

# init home directory of master node with polarstore
function init_polardb_datadir()
{
    local PFS=$1
    local HOST=$2
    local DATA_HOME=$3

    init_mysql_datadir ${HOST} ${DATA_HOME} 1

    if [[ ! -z $4 ]]; then
        local REMOTE_HOME=$4
        exec_cmd2 ${HOST} "${PFS} rm -r ${REMOTE_HOME}"
        exec_cmd2 ${HOST} "${PFS} mkdir ${REMOTE_HOME}" || fatal_error "failed to init data directory in pfs"
        exec_cmd2 ${HOST} "${PFS} mkdir ${REMOTE_HOME}/data" || fatal_error "failed to init data directory in pfs"
        exec_cmd2 ${HOST} "${PFS} mkdir ${REMOTE_HOME}/tmp" || fatal_error "failed to init data directory in pfs"
        exec_cmd2 ${HOST} "${PFS} mkdir ${REMOTE_HOME}/log" || fatal_error "failed to init data directory in pfs"
    fi
}

function check_mysqld_loop()
{
    local BIN=$1
    local HOST=$2
    local PORT=$3
    local FIRST_START=${4:-0}

    local i
    local RETRY=60
    for ((i=1; i<=RETRY; i++)); do
        pid=$([[ ${FIRST_START} -eq 1 ]] && check_mysqld ${BIN} ${HOST} || check_mysqld ${BIN} ${HOST} ${PORT})
        [[ ${pid} -ne 0 ]] && break || sleep 1
    done

    if [[ ${pid} -ne 0 ]]; then
        log_info "Database server is started with pid=${pid} at ${HOST}:${PORT}"
        return 0
    else
        log_error "Failed to start database server ${HOST}:${PORT} after ${RETRY} seconds, aborting"
        return 1
    fi
}

# initialize database server instance
function bootstrap()
{
    local BIN=$1
    local HOST=$2
    local PORT=$3
    local MY_CNF=$4

    log_info "bootstrap database server: ${HOST}:${PORT} with ${MY_CNF}"
    local res=0
    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        ${BIN}/mysqld --defaults-file=${MY_CNF} --initialize-insecure 2>/dev/null
        [[ $? -ne 0 ]] && [[ `grep -c 'initializing of server has completed' ${MYSQL_LOG}` != 1 ]] && res=1
    else
        ssh ${HOST} "${BIN}/mysqld --defaults-file=${MY_CNF} --initialize-insecure" 2>/dev/null
        [[ $? -ne 0 ]] && res=$(ssh ${HOST} "res=0; [[ `grep -c 'initializing of server has completed' ${MYSQL_LOG}` != 1 ]] && res=1; echo \${res}")
    fi

    if [[ ${res} -eq 0 ]]; then
        log_info "Installation of database completed. start database server now ..."

        if [[ $(is_local ${HOST}) -eq 1 ]]; then
            ${BIN}/mysqld --defaults-file=${MY_CNF} >/dev/null 2>&1 &
        else
            ssh ${HOST} "${BIN}/mysqld --defaults-file=${MY_CNF} >/dev/null 2>&1 &"
        fi
        [[ $? -ne 0 ]] && log_error "Failed to start database server ${HOST}:${PORT}, aborting" && return 1

        check_mysqld_loop ${BIN} ${HOST} ${PORT} 1
        return $?
    else
        log_error "Installation of database failed. Aborting ..."
    fi
    return ${res}
}

# check status of database server locally, via SSH if remote host
# return pid, 0 if not exists
# if no port is given, use global environment variable SOCKET as socket file
function check_mysqld()
{
    local BIN=$1
    local HOST=$2
    local PORT=${3:-0}

    local adm_cmd
    local my_cmd
    if [[ ${PORT} -eq 0 ]]; then
        if [[ $(is_local ${HOST}) -eq 1 ]]; then
            [[ ! -S ${SOCKET} ]] && echo 0 && return 0
        else
            local stat=$(ssh ${HOST} "[[ -S ${SOCKET} ]] && echo 0 || echo 1")
            [[ ${stat} -eq 1 ]] && echo 0 && return 0
        fi
        adm_cmd="${BIN}/mysqladmin -uroot -S${SOCKET} ping"
        my_cmd="${BIN}/mysql -uroot -S${SOCKET}"
    else
        adm_cmd="${BIN}/mysqladmin -uroot -h127.0.0.1 -P${PORT} ping"
        my_cmd="${BIN}/mysql -uroot -h127.0.0.1 -P${PORT}"
    fi

    if [[ $(is_local ${HOST}) -eq 1 ]]; then
         ${adm_cmd} >/dev/null 2>&1 && cat `${my_cmd} -e 'SELECT @@pid_file\G' | grep 'pid_file' | awk '{print $NF}'` || echo 0
    else
        local pid_file=`ssh ${HOST} "[[ -S ${SOCKET} ]] && ${adm_cmd} >/dev/null 2>&1 && ${my_cmd} -e 'SELECT @@pid_file\G'" | grep 'pid_file' | awk '{print $NF}'`
        [[ ! -z ${pid_file} ]] && ssh ${HOST} "cat ${pid_file}" || echo 0
    fi
    return 0
}

# start database server process
function start_mysqld()
{
    local BIN=$1
    local HOST=$2
    local PORT=$3
    local MY_CNF=$4
    local with_gdb=$5

    local pid=$(check_mysqld $1 $2 $3)
    [[ ${pid} -ne 0 ]] && log_warn "Database server is already running with pid=${pid} at ${HOST}:${PORT}" && return 1

    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        if [[ ${with_gdb} -eq 1 ]]; then
            gdb --args ${BIN}/mysqld --defaults-file=${MY_CNF} --gdb
        else
            MALLOC_CONF="prof:true,prof_active:true" ${BIN}/mysqld --defaults-file=${MY_CNF} >/dev/null 2>&1 &
        fi
    else
        ssh ${HOST} "MALLOC_CONF="prof:true,prof_active:true" ${BIN}/mysqld --defaults-file=${MY_CNF} >/dev/null 2>&1 &"
    fi
    [[ $? -ne 0 ]] && log_error "Failed to start database server ${HOST}:${PORT}, aborting" && return 1

    check_mysqld_loop ${BIN} ${HOST} ${PORT}
    return $?
}

# set privilege for root user after bootstrap
function init_root_user()
{
    local BIN=$1
    local HOST=$2

    local pid=$(check_mysqld $1 $2)
    [[ $pid -eq 0 ]] && log_error "Database server is not running at ${HOST} with socket file: ${SOCKET}" && return 1

    if [[ $(is_local ${HOST}) -eq 1 ]]; then
        ${BIN}/mysql -uroot -S ${SOCKET} -e "\
            CREATE USER 'root'@'127.0.0.1';\
            GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1';\
            FLUSH PRIVILEGES;"
    else
        ssh ${HOST} "${BIN}/mysql -uroot -S ${SOCKET} -e \"\
            CREATE USER 'root'@'127.0.0.1';\
            GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1';\
            FLUSH PRIVILEGES;\""
    fi
    return 0
}

# stop database server process if exists
function stop_mysqld()
{
    local BIN=$1
    local HOST=$2
    local PORT=$3

    [[ $(check_mysqld $1 $2 $3) -eq 0 ]] && log_warn "Database server is not running at ${HOST}:${PORT}" && return 1

    exec_cmd2 ${HOST} "${BIN}/mysqladmin -uroot -h 127.0.0.1 -P${PORT} shutdown"

    local i
    local RETRY=60
    for ((i=1; i<=RETRY; i++)); do
        [[ $(check_mysqld $1 $2 $3) -eq 0 ]] && break || sleep 1
    done

    [[ $i -ge ${RETRY} ]] && log_error "Failed to stop mysqld in ${RETRY} seconds." && return 1
    return 0
}

# kill process of database server if exists
function kill_mysqld()
{
    local BIN=$1
    local HOST=$2
    local PORT=$3

    local pid=$(check_mysqld $1 $2 $3)
    [[ ${pid} -eq 0 ]] && log_warn "Database server is not running at ${HOST}:${PORT}" && return 1

    log_warn "Database server is running with pid=${pid} at ${HOST}:${PORT}, going to kill it!"
    exec_cmd2 ${HOST} "kill -9 ${pid}"

    return 0
}

