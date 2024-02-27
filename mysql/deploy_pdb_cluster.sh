#!/usr/bin/env bash
BASE="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

if [[ ! -f ${BASE}/../util.sh ]] || [[ ! -f ${BASE}/util.sh ]]; then
    echo "Missing util.sh"
    exit 1
fi

source ${BASE}/../util.sh # log_info/log_error/is_local
source ${BASE}/util.sh  # boostrap

function usage()
{
    echo -e "Utility to depoly polardb database cluster with pfs on master node\n\n\
SYNOPSIS:\n\
    $0 [OPTIONs] [COMMAND]\n\n\
OPTIONs:\n\
    -b | --base=<MYSQL_INSTALL_DIR>: Specify mysql installation directory\n\
    -c | --copy: Copy mysql binary to remote host via SSH from local\n\
    -d | --data=<MYSQL_DATADIR>: Specify mysql data directory\n\
    -p | --port=<PORT>: Specify port on which mysql server run\n\
    -a | --ap: Enable AP function on master node\n\
    --pbd=<PBD>: Specify ploarstore block device number to be used\n\
    -r | --replica=<REPLICA_CONF_STRING>: Specify configuration of replica node(s),\n\
                                          multiple configratuon values are seperated by ';'\n\
    -s | --standby=<STANDBY_CONF_STRING>: Specify configuration of standby node(s),\n\
                                          multiple configratuon values are seperated by ';'\n\
    -h | --help: Print this help message\n\n\
COMMANDs:\n\
    <NONE>: By default, deploy master node and other nodes if specified\n\
    add_replica <REPLICA_CONF_STRING>: add replica node(s) with existing master node\n\
    add_standby <STANDBY_CONF_STRING>: add standby node(s) with existing master node\n\n\
Note:\n\
    REPLICA_CONF_STRING is formatted as HOST:PORT:DATA_DIR:INSTALL_DIR:AP\n\
    STANDBY_CONF_STRING is formatted as HOST:PORT:DATA_DIR:INSTALL_DIR:PBD\n"
}

# parse options
OPT_END=0
COPY_BIN=0
IS_AP=0
while [[ ${OPT_END} -eq 0 ]]; do
    case "$1" in
    -b | --base)
        shift
        MYSQL_BASE=$(get_key_value "$1")
        shift;;
    --base=*)
        MYSQL_BASE=$(get_key_value "$1")
        shift;;
    -c | --copy)
        shift
        COPY_BIN=1;;
    -a | --ap)
        IS_AP=1
        shift;;
    -d | --data)
        shift
        MASTER_HOME=$(get_key_value "$1")
        shift;;
    --data=*)
        MASTER_HOME=$(get_key_value "$1")
        shift;;
    -p | --port)
        shift
        MASTER_PORT=$(get_key_value "$1")
        shift;;
    --port=*)
        MASTER_PORT=$(get_key_value "$1")
        shift;;
    --pbd)
        shift
        MASTER_PBD=$(get_key_value "$1")
        shift;;
    --pbd=*)
        MASTER_PBD=$(get_key_value "$1")
        shift;;
    -r | --replicas)
        shift
        REPLICA_CONF_STR=$(get_key_value "$1")
        shift;;
    --replicas=*)
        REPLICA_CONF_STR=$(get_key_value "$1")
        shift;;
    -s | --standby)
        shift
        STANDBY_CONF_STR=$(get_key_value "$1")
        shift;;
    --standby=*)
        STANDBY_CONF_STR=$(get_key_value "$1")
        shift;;
    -h | --help)
        usage
        exit 0;;
    *)
        OPT_END=1;;
    esac
done

[[ -z ${MYSQL_BASE} ]] && log_error "Missing parameter for --base" && exit 1
[[ -d ${MYSQL_BASE} ]] && [[ -x ${MYSQL_BASE}/bin/mysqld ]] || fatal_error "Invalid value for --base"
[[ -z ${MASTER_HOME} ]] && log_error "Missing parameter for --data" && exit 1
[[ -z ${MASTER_PORT} ]] && log_error "Missing parameter for --port" && exit 1
[[ -z ${MASTER_PBD} ]] && log_error "Missing parameter for --pbd" && exit 1

PFS="/usr/local/bin/pfs"
# IP address of master ndoe is used by replica and standby nodes
MASTER_HOST=$(hostname -i)
REPL_USER="replicator"
REPL_PASS="passw0rd"
MASTER_REMOTE=/${MASTER_PBD}-1/${MASTER_PORT}

function deploy_master()
{
    local HOST_ID=1

    # check pbd is accessable by master
    exec_cmd2 ${MASTER_HOST} "${PFS} ls /${MASTER_PBD}-1/" || fatal_error "Invalid pbd value, make sure it is correctly formated and attached!"

    log_info "Deploy polardb master at port=${MASTER_PORT} pbd=${MASTER_PBD}"
    # init data home directory
    init_polardb_datadir ${PFS} ${MASTER_HOST} ${MASTER_HOME} ${MASTER_REMOTE}
 
    # set my.cnf
    local MY_CNF=${MASTER_HOME}/my.cnf
    cp ${BASE}/my_pdb_pfs_template.cnf ${MY_CNF}
    sed -i -e "s#<LOCAL_HOME>#${MASTER_HOME}#g" \
           -e "s#<BASE_DIR>#${MYSQL_BASE}#g" \
           -e "s#<REMOTE_HOME>#${MASTER_REMOTE}#g" \
           -e "s#<PBD_NAME>#${MASTER_PBD}-1#g" \
           -e "s#<PORT>#${MASTER_PORT}#g" \
           -e "s#<HOST_ID>#${HOST_ID}#g" \
           ${MY_CNF}
    if [[ ${IS_AP} -eq 1 ]]; then
        sed -i -e "s/#innodb_polar_max_pddl_threads/innodb_polar_max_pddl_threads = 128/g" \
               -e "s/#innodb_polar_parallel_ddl_threads/innodb_polar_parallel_ddl_threads = 128/g" \
               -e "s/#polar_enable_imci/polar_enable_imci = ON/g" \
               ${MY_CNF}
    fi
    get_mysql_params ${MY_CNF}

    local pid=$(check_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST})
    [[ ${pid} -ne 0 ]] && fatal_error "Database server is already running at ${MASTER_HOST}:${MASTER_PORT} with pid=${pid}"

    bootstrap ${MYSQL_BASE}/bin ${MASTER_HOST} ${MASTER_PORT} ${MY_CNF} || exit 1

    init_root_user ${MYSQL_BASE}/bin ${MASTER_HOST} || exit 1
 
    log_info "Creating replicator profile ..."
    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} <<EOF
        CREATE USER "${REPL_USER}"@'%' IDENTIFIED BY "${REPL_PASS}";
        GRANT ALL PRIVILEGES ON *.* TO "${REPL_USER}"@'%';
        CREATE USER "${REPL_USER}"@'127.0.0.1' IDENTIFIED BY "${REPL_PASS}";
        GRANT ALL PRIVILEGES ON *.* TO "${REPL_USER}"@'127.0.0.1';
        FLUSH PRIVILEGES;
        CREATE SCHEMA polardb_ha; USE polardb_ha;
        CREATE TABLE nodes (
            id int not null primary key auto_increment,
            hostname varchar(128),
            port bigint,
            mysqld_file varchar(2048),
            conf_file varchar(2048),
            host_id int,
            pbd_no int);
        CREATE TABLE heartbeat (
            id int not null primary key auto_increment,
            hb_ts timestamp(6));
        INSERT INTO polardb_ha.nodes VALUES (default, '${MASTER_HOST}', '${MASTER_PORT}',
            '${MYSQL_BASE}/bin/mysqld', '${MY_CNF}', 1, '${MASTER_PBD}');
        INSERT INTO heartbeat VALUES (default, now());
EOF
    [[ $? -ne 0 ]] && exit 1
}

function deploy_standby_copy_data()
{
    local CONF_STR=$1
    local STANDBY_HOST=$(echo ${CONF_STR} | awk -F':' '{print $1}')
    local STANDBY_PORT=$(echo ${CONF_STR} | awk -F':' '{print $2}')
    local STANDBY_HOME=$(echo ${CONF_STR} | awk -F':' '{print $3}')
    local STANDBY_BASE=$(echo ${CONF_STR} | awk -F':' '{print $4}')
    local STANDBY_PBD=$(echo ${CONF_STR} | awk -F':' '{print $5}')
    local STANDBY_REMOTE=/${STANDBY_PBD}-1/${STANDBY_PORT}
    local HOST_ID=1

    # check mysqld binary for standby
    if [[ $(is_local ${STANDBY_HOST}) -eq 1 ]]; then
        log_warn "deploy standby on master node!"
        [[ ${STANDBY_HOME} != ${MASTER_HOME} ]] && [[ ${STANDBY_PORT} != ${MASTER_PORT} ]] || fatal_error "standby node cannot use same datadir or port as master node"

        if [[ ${MYSQL_BASE} != ${STANDBY_BASE} ]] && [[ ${COPY_BIN} -eq 1 ]]; then
            cp -r ${MYSQL_BASE} ${STANDBY_BASE}
            [[ $? -ne 0 ]] && fatal_error "Failed to copy binary to ${STANDBY_BASE} for standby"
        fi
        [[ -d ${STANDBY_BASE} ]] && [[ -x ${STANDBY_BASE}/bin/mysqld ]] || fatal_error "Invalid value of basedir for standby"
    else
        if [[ ${COPY_BIN} -eq 1 ]]; then
            scp -q -r ${MYSQL_BASE} ${STANDBY_HOST}:${STANDBY_BASE}
            [[ $? -ne 0 ]] && fatal_error "Failed to copy binary to replica node: ${STANDBY_HOST}"
        fi
        local stat=$(ssh ${STANDBY_HOST} "[[ -d ${STANDBY_BASE} ]] && [[ -x ${STANDBY_BASE}/bin/mysqld ]] && echo 0 || echo 1")
        [[ ${stat} -eq 0 ]] || fatal_error "Invalid value of basedir for standby"
    fi

    [[ ${STANDBY_PBD} != ${MASTER_PBD} ]] || fatal_error "standby node cannot use same pbd as master node"

    # check pbd is accessable by standby
    exec_cmd2 ${STANDBY_HOST} "${PFS} ls /${STANDBY_PBD}-1/" || fatal_error "Invalid pbd value, make sure it is correctly formated and attached!"

    log_info "Deploy polardb standby node on ${STANDBY_HOST}:${STANDBY_PORT} with pbd=${STANDBY_PBD} ..."
    # set data directory of standby
    exec_cmd ${STANDBY_HOST} "mkdir -p ${STANDBY_HOME}" || fatal_error "failed to init data directory for standby node"
    exec_cmd ${STANDBY_HOST} "/bin/rm -rf ${STANDBY_HOME}/*" || fatal_error "failed to init data directory for standby node"

    # copy data directory of standby from master
    if [[ $(is_local ${STANDBY_HOST}) -eq 1 ]]; then
        cp -r ${MASTER_HOME}/* ${STANDBY_HOME}/
    else
        scp -q -r ${MASTER_HOME}/* ${STANDBY_HOST}:${STANDBY_HOME}/
    fi
    [[ $? -ne 0 ]] && fatal_error "Failed to copy data from master data directory to standby data directory"

    exec_cmd ${STANDBY_HOST} "/bin/rm ${STANDBY_HOME}/log/polar.info ${STANDBY_HOME}/log/master-error.log"
    ${PFS} fscp -w 16 ${MASTER_PBD}-1 ${STANDBY_PBD}-1 > /dev/null 2>&1 || fatal_error "Failed to copy data from master polarstore to standby polarstore"
    [[ ${MASTER_PORT} -ne ${MASTER_PORT} ]] && \
        exec_cmd1 ${STANDBY_HOST} "${PFS} rename /${STANDBY_PBD}-1/${MASTER_PORT} /${STANDBY_PBD}-1/${STANDBY_PORT}"
    exec_cmd1 ${STANDBY_HOST} "${PFS} rm ${STANDBY_REMOTE}/data/auto.cnf"

    # set my.cnf
    local MY_CNF=/tmp/my.cnf
    cp ${BASE}/my_pdb_pfs_template.cnf ${MY_CNF}
    sed -i -e "s#<LOCAL_HOME>#${STANDBY_HOME}#g" \
           -e "s#<BASE_DIR>#${STANDBY_BASE}#g" \
           -e "s#<REMOTE_HOME>#${STANDBY_REMOTE}#g" \
           -e "s#<PBD_NAME>#${STANDBY_PBD}-1#g" \
           -e "s#<PORT>#${STANDBY_PORT}#g" \
           -e "s#<HOST_ID>#${HOST_ID}#g" \
           -e "s/#polar_master_host/polar_master_host = ${MASTER_HOST}/g" \
           -e "s/#polar_master_port/polar_master_port = ${MASTER_PORT}/g" \
           -e "s/#polar_master_user_name/polar_master_user_name = ${REPL_USER}/g" \
           -e "s/#polar_master_user_password/polar_master_user_password = ${REPL_PASS}/g" \
           ${MY_CNF}
    get_mysql_params ${MY_CNF}

    if [[ $(is_local ${STANDBY_HOST}) -eq 1 ]]; then
        cp ${MY_CNF} ${STANDBY_HOME}/my.cnf
    else
        scp -q ${MY_CNF} ${STANDBY_HOST}:${STANDBY_HOME}/my.cnf
    fi
    /bin/rm /tmp/my.cnf
}

function deploy_standbys()
{
    log_info "Shutting down master node to copy data for new standby node(s)"
    stop_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${MASTER_PORT}
    sleep 5

    for STANDBY_CONF in `echo ${STANDBY_CONF_STR} | sed 's/;/ /g'`; do
        deploy_standby_copy_data ${STANDBY_CONF}
    done

    log_info "Start master node"
    start_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${MASTER_PORT} ${MASTER_HOME}/my.cnf || fatal_error "Failed to start master node after cloning"

    # start all standby nodes
    for STANDBY_CONF in `echo ${STANDBY_CONF_STR} | sed 's/;/ /g'`; do
        local STANDBY_HOST=$(echo ${STANDBY_CONF} | awk -F':' '{print $1}')
        local STANDBY_PORT=$(echo ${STANDBY_CONF} | awk -F':' '{print $2}')
        local STANDBY_HOME=$(echo ${STANDBY_CONF} | awk -F':' '{print $3}')
        local STANDBY_BASE=$(echo ${STANDBY_CONF} | awk -F':' '{print $4}')
        local STANDBY_PBD=$(echo ${STANDBY_CONF} | awk -F':' '{print $5}')

        log_info "Start standby node on ${STANDBY_HOST} at port=${STANDBY_PORT}"
        start_mysqld ${STANDBY_BASE}/bin ${STANDBY_HOST} ${STANDBY_PORT} ${STANDBY_HOME}/my.cnf

        ${MYSQL_BASE}/bin/mysql -uroot -h 127.0.0.1 -P${MASTER_PORT} <<EOF
            INSERT INTO polardb_ha.nodes VALUES(default, '${STANDBY_HOST}', '${STANDBY_PORT}',
                '${STANDBY_BASE}/bin/mysqld', '${STANDBY_HOME}/my.cnf', 1, '${STANDBY_PBD}');
EOF
    done

    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} -e "SHOW POLAR standbys;"
}

function deploy_replicas()
{
    local HOST_ID=$1

    for REPLICA_CONF in `echo ${REPLICA_CONF_STR} | sed 's/;/ /g'`; do
        local REPLICA_HOST=$(echo ${REPLICA_CONF} | awk -F':' '{print $1}')
        local REPLICA_PORT=$(echo ${REPLICA_CONF} | awk -F':' '{print $2}')
        local REPLICA_HOME=$(echo ${REPLICA_CONF} | awk -F':' '{print $3}')
        local REPLICA_BASE=$(echo ${REPLICA_CONF} | awk -F':' '{print $4}')
        local REPLICA_AP=$(echo ${REPLICA_CONF} | awk -F':' '{print $5}')

        log_info "deploy replica $REPLICA_HOST:$REPLICA_PORT"

        # check replica parameters
        [[ $(is_local ${REPLICA_HOST}) -eq 1 ]] && fatal_error "Can't deploy replica on master node"

        if [[ ${COPY_BIN} -eq 1 ]]; then
            scp -q -r ${MYSQL_BASE} ${REPLICA_HOST}:${REPLICA_BASE}
            [[ $? -ne 0 ]] && fatal_error "Failed to copy binary to replica node: ${REPLICA_HOST}"
        fi
        local stat=$(ssh ${REPLICA_HOST} "[[ -d ${REPLICA_BASE} ]] && [[ -x ${REPLICA_BASE}/bin/mysqld ]] && echo 0 || echo 1")
        [[ ${stat} -eq 0 ]] || fatal_error "Invalid value of basedir for replica"

        # check master pbd is accessable by replica
        exec_cmd2 ${REPLICA_HOST} "${PFS} ls /${MASTER_PBD}-1/" || fatal_error "Invalid pbd value, make sure it is correctly formated and attached!"

        log_info "Deploy polardb replica node on ${REPLICA_HOST}:${REPLICA_PORT} with pbd=${MASTER_PBD} ..."
        ((HOST_ID++))
        init_mysql_datadir ${REPLICA_HOST} ${REPLICA_HOME} 1

        # set my.cnf
        local MY_CNF=/tmp/my.cnf
        cp ${BASE}/my_pdb_pfs_template.cnf ${MY_CNF}
        sed -i -e "s#<LOCAL_HOME>#${REPLICA_HOME}#g" \
               -e "s#<BASE_DIR>#${REPLICA_BASE}#g" \
               -e "s#<REMOTE_HOME>#${MASTER_REMOTE}#g" \
               -e "s#<PBD_NAME>#${MASTER_PBD}-1#g" \
               -e "s#<PORT>#${REPLICA_PORT}#g" \
               -e "s#<HOST_ID>#${HOST_ID}#g" \
               -e "s/#polar_master_host/polar_master_host = ${MASTER_HOST}/g" \
               -e "s/#polar_master_port/polar_master_port = ${MASTER_PORT}/g" \
               -e "s/#polar_master_user_name/polar_master_user_name = ${REPL_USER}/g" \
               -e "s/#polar_master_user_password/polar_master_user_password = ${REPL_PASS}/g" \
               -e "s/#polar_enable_replica/polar_enable_replica = ON/g" \
               ${MY_CNF}

        if [[ ${REPLICA_AP} -eq 1 ]]; then
            sed -i -e "s/#innodb_polar_max_pddl_threads/innodb_polar_max_pddl_threads = 128/g" \
                   -e "s/#innodb_polar_parallel_ddl_threads/innodb_polar_parallel_ddl_threads = 128/g" \
                   -e "s/#polar_enable_imci/polar_enable_imci = ON/g" \
                      ${MY_CNF}
        fi

        get_mysql_params ${MY_CNF}
        scp -q ${MY_CNF} ${REPLICA_HOST}:${REPLICA_HOME}/my.cnf || fatal_error "failed to copy my.cnf"
        /bin/rm /tmp/my.cnf

        start_mysqld ${REPLICA_BASE}/bin ${REPLICA_HOST} ${REPLICA_PORT} ${REPLICA_HOME}/my.cnf

        ssh ${REPLICA_HOST} "${REPLICA_BASE}/bin/mysql -uroot -h127.0.0.1 -P${REPLICA_PORT} \
            -e \"DROP TABLE IF EXISTS mysql.slow_log, mysql.general_log;\
                 CREATE TABLE IF NOT EXISTS mysql.slow_log (\
                   start_time timestamp(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),\
                   user_host mediumtext NOT NULL,\
                   query_time time(6) NOT NULL,\
                   lock_time time(6) NOT NULL,\
                   rows_sent int(11) NOT NULL,\
                   rows_examined int(11) NOT NULL,\
                   db varchar(512) NOT NULL,\
                   last_insert_id int(11) NOT NULL,\
                   insert_id int(11) NOT NULL,\
                   server_id int(10) unsigned NOT NULL,\
                   sql_text mediumblob NOT NULL,\
                   thread_id bigint(21) unsigned NOT NULL\
                 ) ENGINE=CSV DEFAULT CHARSET=utf8 COMMENT='Slow log';\
                 CREATE TABLE IF NOT EXISTS mysql.general_log (\
                   event_time timestamp(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),\
                   user_host mediumtext NOT NULL,\
                   thread_id bigint(21) unsigned NOT NULL,\
                   server_id int(10) unsigned NOT NULL,\
                   command_type varchar(64) NOT NULL,\
                   argument mediumblob NOT NULL\
                 ) ENGINE=CSV DEFAULT CHARSET=utf8 COMMENT='General log';\""

        ${MYSQL_BASE}/bin/mysql -uroot -h 127.0.0.1 -P${MASTER_PORT} <<EOF
            INSERT INTO polardb_ha.nodes VALUES(default, '${REPLICA_HOST}', '${REPLICA_PORT}',
                '${REPLICA_BASE}/bin/mysqld', '${REPLICA_HOME}/my.cnf', ${HOST_ID}, '${MASTER_PBD}');
EOF
    done

    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} -e "SHOW POLAR replicas;"
}

# main
if [[ -z "$1" ]]; then
    # deploy master node
    deploy_master
    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} -e "SHOW POLAR status\G"

    if [[ ! -z ${STANDBY_CONF_STR} ]]; then
        # depoly standby node(s)
        deploy_standbys
    fi

    if [[ ! -z ${REPLICA_CONF_STR} ]]; then
        # deploy replica node(s)
        deploy_replicas 1
    fi
else
    get_mysql_params ${MASTER_HOME}/my.cnf
    pid=$(check_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${MASTER_PORT})
    [[ ${pid} -eq 0 ]] && fatal_error "Database server is not running at ${MASTER_HOST}:${MASTER_PORT}"

    if [[ "$1" == "add_replica" ]]; then
        [[ ! -z $2 ]] || fatal_error "Missing configuration string for add_replica command"
        REPLICA_CONF_STR=$2

        # get max host_id of current replicas
        HOST_ID=`${MYSQL_BASE}/bin/mysql -uroot -h 127.0.0.1 -P${MASTER_PORT} -e "SELECT MAX(host_id) FROM polardb_ha.nodes\G" | awk -F':' '{print $2}'`
        # deploy new replica node with existing master node
        deploy_replicas ${HOST_ID}
    elif [[ "$1" == "add_standby" ]]; then
        [[ ! -z $2 ]] || fatal_error "Missing configuration string for add_standby command"
        STANDBY_CONF_STR=$2
    
        # deploy new standby node with existing master node
        deploy_standbys
    else
        fatal_error "Invalid command: $1"
    fi
fi

