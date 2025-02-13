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
    echo -e "Utility to depoly polardb database cluster with local disk on master node\n\n\
SYNOPSIS:\n\
    $0 [OPTIONs] [COMMAND]\n\n\
OPTIONs:\n\
    -b | --base=<MYSQL_INSTALL_DIR>: Specify mysql installation directory\n\
    -c | --copy: Copy mysql binary to remote host via SSH from local\n\
    -d | --data=<MYSQL_DATADIR>: Specify mysql data directory\n\
    -p | --port=<PORT>: Specify port on which mysql server run\n\
    -a | --ap: Enable AP function on master node\n\
    -x | --xengine: Enable XEngine function\n\
    -m | --multi-master: Deploy multi master cluster\n\
    --master-count <NUM> | --master-count=<NUM> : number of master servers in multi master cluster\n\
    --global-standby: enable global standby\n\
    --global-standby-replica: enable global standby replica, 1 standard RO and 1 AP RO\n\
    --global-replica: enable global replica with CC, 1 standard RO and 1 AP RO\n\
    -r | --replica=<REPLICA_CONF_STRING>: Specify configuration of replica node(s),\n\
                                          multiple configratuon values are seperated by ';'\n\
    -s | --standby=<STANDBY_CONF_STRING>: Specify configuration of standby node(s),\n\
                                          multiple configratuon values are seperated by ';'\n\
    --replica-count=<NUM> : current number of replicas\n\
    -h | --help: Print this help message\n\n\
COMMANDs:\n\
    <NONE>: By default, deploy master node and other nodes if specified\n\
    add_replica <REPLICA_CONF_STRING>: add replica node(s) with existing master node\n\
    add_standby <STANDBY_CONF_STRING>: add standby node(s) with existing master node\n\n\
Note:\n\
    REPLICA_CONF_STRING is formatted as PORT:DATA_HOME:AP\n\
    STANDBY_CONF_STRING is formatted as HOST:PORT:DATA_HOME:INSTALL_DIR\n"
}

# parse options
OPT_END=0
COPY_BIN=0
IS_AP=0
FOR_MM=0
MASTER_COUNT=0
REPLICA_COUNT=0
XENGINE=0
GLOBAL_STANDBY=0
GLOBAL_STANDBY_REPLICA=0
GLOBAL_REPLICA=0
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
    -m | --multi-master)
        FOR_MM=1
        shift;;
    --global-standby)
        GLOBAL_STANDBY=1
        shift;;
    --global-standby-replica)
        GLOBAL_STANDBY_REPLICA=1
        shift;;
    --global-replica)
        GLOBAL_REPLICA=1
        shift;;
    --master-count)
        shift
        MASTER_COUNT=$(get_key_value "$1")
        shift;;
    --master-count=*)
        MASTER_COUNT=$(get_key_value "$1")
        shift;;
    -r | --replica)
        shift
        REPLICA_CONF_STR=$(get_key_value "$1")
        shift;;
    --replica=*)
        REPLICA_CONF_STR=$(get_key_value "$1")
        shift;;
    --replica-count=*)
        REPLICA_COUNT=$(get_key_value "$1")
        shift;;
    -s | --standby)
        shift
        STANDBY_CONF_STR=$(get_key_value "$1")
        shift;;
    --standby=*)
        STANDBY_CONF_STR=$(get_key_value "$1")
        shift;;
    -x | --xengine)
        XENGINE=1
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

# IP address of master ndoe is used by replica and standby nodes
MASTER_HOST=$(hostname -i)
REPL_USER="replicator"
REPL_PASS="passw0rd"

function is_xengine_enabled() {
  match=$(grep -w '^loose_xengine' $1 | wc -l)
  if [[ ${match} -eq 0 ]]; then return 0; fi

  return 1
}

function deploy_master()
{
    log_info "Deploy polardb master at port=${MASTER_PORT} XENGINE=${XENGINE} IMCI=${IS_AP}"
    # init data home directory with local disk
    init_mysql_datadir ${MASTER_HOST} ${MASTER_HOME} 0
 
    # set my.cnf
    local MY_CNF=${MASTER_HOME}/my.cnf
    cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
    sed -i -e "s#<LOCAL_HOME>#${MASTER_HOME}#g" \
           -e "s#<BASE_DIR>#${MYSQL_BASE}#g" \
           -e "s#<DATA_DIR>#${MASTER_HOME}/data#g" \
           -e "s#<PORT>#${MASTER_PORT}#g" \
           -e "s#<BLOG>#${MASTER_HOME}/blog#g" \
           ${MY_CNF}
    if [[ ${IS_AP} -eq 1 ]]; then
        sed -i -e "s/#innodb_polar_max_pddl_threads/innodb_polar_max_pddl_threads = 128/g" \
               -e "s/#innodb_polar_parallel_ddl_threads/innodb_polar_parallel_ddl_threads = 128/g" \
               -e "s/#polar_enable_imci/polar_enable_imci = ON/g" \
                  ${MY_CNF}
    fi
    if [[ ${XENGINE} -eq 1 ]]; then
        sed -i -e "s/^#XE/loose/g" ${MY_CNF}
    fi
    get_mysql_params ${MY_CNF}

    local pid=$(check_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${MASTER_PORT})
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

    [[ ! -z ${STANDBY_HOST} ]] || fatal_error "Missing host for standby configuration string!"
    [[ ! -z ${STANDBY_PORT} ]] || fatal_error "Missing port for standby configuration string!"
    [[ ! -z ${STANDBY_HOME} ]] || fatal_error "Missing data home dir for standby configuration string!"
    [[ ! -z ${STANDBY_BASE} ]] || fatal_error "Missing install base dir for standby configuration string!"

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

    is_xengine_enabled ${MASTER_HOME}/my.cnf
    is_xengine=$?
    log_info "Deploy polardb standby node on ${STANDBY_HOST}:${STANDBY_PORT} XENGINE=${is_xengine} ..."
    # set data directory of standby
    exec_cmd ${STANDBY_HOST} "/bin/rm -rf ${STANDBY_HOME}"
    exec_cmd ${STANDBY_HOST} "mkdir -p ${STANDBY_HOME}" || fatal_error "failed to init data directory for standby node"

    # copy data directory of standby from master
    if [[ $(is_local ${STANDBY_HOST}) -eq 1 ]]; then
        cp -r ${MASTER_HOME}/* ${STANDBY_HOME}/
    else
        scp -q -r ${MASTER_HOME}/* ${STANDBY_HOST}:${STANDBY_HOME}/
    fi
    [[ $? -ne 0 ]] && fatal_error "Failed to copy data from master data directory to standby data directory"

    exec_cmd ${STANDBY_HOST} "/bin/rm ${STANDBY_HOME}/log/*"
    exec_cmd1 ${STANDBY_HOST} "rm ${STANDBY_HOME}/data/auto.cnf"

    # set my.cnf
    local MY_CNF=/tmp/my.cnf
    cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
    sed -i -e "s#<LOCAL_HOME>#${STANDBY_HOME}#g" \
           -e "s#<BASE_DIR>#${STANDBY_BASE}#g" \
           -e "s#<DATA_DIR>#${STANDBY_HOME}/data#g" \
           -e "s#<BLOG>#${STANDBY_HOME}/blog#g" \
           -e "s#<PORT>#${STANDBY_PORT}#g" \
           -e "s/#polar_master_host/polar_master_host = ${MASTER_HOST}/g" \
           -e "s/#polar_master_port/polar_master_port = ${MASTER_PORT}/g" \
           -e "s/#polar_master_user_name/polar_master_user_name = ${REPL_USER}/g" \
           -e "s/#polar_master_user_password/polar_master_user_password = ${REPL_PASS}/g" \
           ${MY_CNF}
    if [[ ${is_xengine} -eq 1 ]]; then
        sed -i -e "s/^#XE/loose/g" ${MY_CNF}
    fi
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

    log_info "Start master node for deploying standby node"
    start_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${MASTER_PORT} ${MASTER_HOME}/my.cnf || fatal_error "Failed to start master node after cloning"

    # start all standby nodes
    for STANDBY_CONF in `echo ${STANDBY_CONF_STR} | sed 's/;/ /g'`; do
        local STANDBY_HOST=$(echo ${STANDBY_CONF} | awk -F':' '{print $1}')
        local STANDBY_PORT=$(echo ${STANDBY_CONF} | awk -F':' '{print $2}')
        local STANDBY_HOME=$(echo ${STANDBY_CONF} | awk -F':' '{print $3}')
        local STANDBY_BASE=$(echo ${STANDBY_CONF} | awk -F':' '{print $4}')

        log_info "Start standby node on ${STANDBY_HOST} at port=${STANDBY_PORT}"
        start_mysqld ${STANDBY_BASE}/bin ${STANDBY_HOST} ${STANDBY_PORT} ${STANDBY_HOME}/my.cnf

        log_info "============================================================"
    done

    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} -e "SHOW POLAR standbys;"
}

function deploy_replicas()
{
    local HOST_ID=$1
    local is_gs_ro=$2

    REPLICA_HOST=${MASTER_HOST}
    REPLICA_BASE=${MYSQL_BASE}
    for REPLICA_CONF in `echo ${REPLICA_CONF_STR} | sed 's/;/ /g'`; do
        local REPLICA_PORT=$(echo ${REPLICA_CONF} | awk -F':' '{print $1}')
        local REPLICA_HOME=$(echo ${REPLICA_CONF} | awk -F':' '{print $2}')
        local REPLICA_AP=$(echo ${REPLICA_CONF} | awk -F':' '{print $3}')

        ls /${MASTER_HOME}/data || fatal_error "Can't access data dir of master node for replica!"
        is_xengine_enabled ${MASTER_HOME}/my.cnf
        is_xengine=$?
        log_info "Deploy polardb replica node on ${REPLICA_HOST}:${REPLICA_PORT} XENGINE=${is_xengine} IMCI=${REPLICA_AP}..."
        ((HOST_ID++))
        init_mysql_datadir ${REPLICA_HOST} ${REPLICA_HOME} 1

        # set my.cnf
        local MY_CNF=/tmp/my.cnf
        cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
        sed -i -e "s#<LOCAL_HOME>#${REPLICA_HOME}#g" \
               -e "s#<BASE_DIR>#${REPLICA_BASE}#g" \
               -e "s#<DATA_DIR>#${MASTER_HOME}/data#g" \
               -e "s#<BLOG>#${MASTER_HOME}/blog#g" \
               -e "s#<PORT>#${REPLICA_PORT}#g" \
               -e "s/#polar_master_host/polar_master_host = ${MASTER_HOST}/g" \
               -e "s/#polar_master_port/polar_master_port = ${MASTER_PORT}/g" \
               -e "s/#polar_master_user_name/polar_master_user_name = ${REPL_USER}/g" \
               -e "s/#polar_master_user_password/polar_master_user_password = ${REPL_PASS}/g" \
               -e "s/#polar_enable_replica/polar_enable_replica = ON/g" \
               ${MY_CNF}

        if [[ ${REPLICA_AP} -eq 1 ]]; then
            sed -i -e "s/#AP/loose/g" ${MY_CNF}
        fi
        if [[ ${is_gs_ro} -eq 1 ]]; then
            sed -i -e "s/^#MM_GS/loose/g" ${MY_CNF}
        fi

        if [[ ${is_xengine} -eq 1 ]]; then
            sed -i -e "s/^#XE/loose/g" ${MY_CNF}
        fi

        get_mysql_params ${MY_CNF}
        cp ${MY_CNF} ${REPLICA_HOME}/my.cnf || fatal_error "failed to copy my.cnf"
        /bin/rm /tmp/my.cnf

        start_mysqld ${REPLICA_BASE}/bin ${REPLICA_HOST} ${REPLICA_PORT} ${REPLICA_HOME}/my.cnf

        log_info "============================================================"
    done

    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} -e "SHOW POLAR replicas;"
}

# Register replica with CC node
function deploy_cc_replicas()
{
    local HOST_ID=$1
    local RW_HOME=$2

    REPLICA_HOST=${MASTER_HOST}
    REPLICA_BASE=${MYSQL_BASE}
    for REPLICA_CONF in `echo ${REPLICA_CONF_STR} | sed 's/;/ /g'`; do
        local REPLICA_PORT=$(echo ${REPLICA_CONF} | awk -F':' '{print $1}')
        local REPLICA_HOME=$(echo ${REPLICA_CONF} | awk -F':' '{print $2}')
        local REPLICA_AP=$(echo ${REPLICA_CONF} | awk -F':' '{print $3}')

        ls /${RW_HOME}/data || fatal_error "Can't access data dir of master node for replica!"
        log_info "Deploy polardb replica node on ${REPLICA_HOST}:${REPLICA_PORT} IMCI=${REPLICA_AP}..."
        ((HOST_ID++))
        init_mysql_datadir ${REPLICA_HOST} ${REPLICA_HOME} 1

        # set my.cnf
        local MY_CNF=/tmp/my.cnf
        cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
        sed -i -e "s#<LOCAL_HOME>#${REPLICA_HOME}#g" \
               -e "s#<BASE_DIR>#${REPLICA_BASE}#g" \
               -e "s#<DATA_DIR>#${RW_HOME}/data#g" \
               -e "s#<BLOG>#${RW_HOME}/blog#g" \
               -e "s#<PORT>#${REPLICA_PORT}#g" \
               -e "s/#polar_master_host/polar_master_host = ${MASTER_HOST}/g" \
               -e "s/#polar_master_port/polar_master_port = ${MASTER_PORT}/g" \
               -e "s/#polar_master_user_name/polar_master_user_name = ${REPL_USER}/g" \
               -e "s/#polar_master_user_password/polar_master_user_password = ${REPL_PASS}/g" \
               -e "s/#polar_enable_replica/polar_enable_replica = ON/g" \
               -e "s/^#MM_COMMON/loose/g" \
               -e "s/^#MM_GR/loose/g" \
               -e "s#<CC_DATADIR>#${MASTER_HOME}/data#g" \
               -e "s/#loose_innodb_cc_glog_dir /loose_innodb_cc_glog_dir /g"\
               -e "s#<GLOG_DIR>#${MASTER_HOME}/glog#g" \
               ${MY_CNF}

        if [[ ${REPLICA_AP} -eq 1 ]]; then
            sed -i -e "s/#AP/loose/g" ${MY_CNF}
        fi

        get_mysql_params ${MY_CNF}
        cp ${MY_CNF} ${REPLICA_HOME}/my.cnf || fatal_error "failed to copy my.cnf"
        /bin/rm /tmp/my.cnf

        start_mysqld ${REPLICA_BASE}/bin ${REPLICA_HOST} ${REPLICA_PORT} ${REPLICA_HOME}/my.cnf

        log_info "============================================================"
    done

    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} -e "SHOW POLAR replicas;"
}

function deploy_multi_master()
{
    CC_HOST=${MASTER_HOST}
    CC_PORT=${MASTER_PORT}
    CC_HOME=${MASTER_HOME}/cc_${CC_PORT}
    GLOG_PORT=`expr ${CC_PORT} + 19`

    RW1_PORT=`expr ${CC_PORT} + 1`
    RW1_HOME=${MASTER_HOME}/rw_${RW1_PORT}

    # bootstrap a CC server
    log_info "==================== bootstrap a CC server ..."
    local pid=$(check_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${CC_PORT})
    [[ ${pid} -ne 0 ]] && fatal_error "Database server is already running at ${MASTER_HOST}:${CC_PORT} with pid=${pid}"

    log_info "Deploy polardb cache center server for multi master at port=${CC_PORT}"
    # init data home directory with local disk
    init_mysql_datadir ${MASTER_HOST} ${CC_HOME} 0
    mkdir ${CC_HOME}/glog

    # set my.cnf
    local MY_CNF=${CC_HOME}/my.cnf
    cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
    sed -i -e "s#<LOCAL_HOME>#${CC_HOME}#g" \
           -e "s#<BASE_DIR>#${MYSQL_BASE}#g" \
           -e "s#<DATA_DIR>#${CC_HOME}/data#g" \
           -e "s#<BLOG>#${CC_HOME}/blog#g" \
           -e "s#<PORT>#${CC_PORT}#g" \
           -e "s#<CC_HOME>#${CC_HOME}#g" \
           -e "s#<MM_HOME>#${RW1_HOME}#g" \
           -e "s/<CC_PORT>/${CC_PORT}/g" \
           -e "s/^#MM_COMMON/loose/g" \
           -e "s/<RDMA_PORT>/${GLOG_PORT}/g"  \
           -e "s/^#MM_CC/loose/g" \
           -e "s/<MASTER_COUNT>/${MASTER_COUNT}/g" \
           -e "s/#loose_innodb_cc_glog_dir /loose_innodb_cc_glog_dir /g"\
           -e "s#<GLOG_DIR>#${CC_HOME}/glog#g" \
           ${MY_CNF}
    get_mysql_params ${MY_CNF} ${MASTER_HOST}

    bootstrap ${MYSQL_BASE}/bin ${MASTER_HOST} ${CC_PORT} ${MY_CNF} || exit 1
    init_root_user ${MYSQL_BASE}/bin ${MASTER_HOST} || exit 1
    log_info "Creating replicator profile on cache center server ..."
    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${CC_PORT} <<EOF
        CREATE USER "${REPL_USER}"@'%' IDENTIFIED BY "${REPL_PASS}";
        GRANT ALL PRIVILEGES ON *.* TO "${REPL_USER}"@'%';
        CREATE USER "${REPL_USER}"@'127.0.0.1' IDENTIFIED BY "${REPL_PASS}";
        GRANT ALL PRIVILEGES ON *.* TO "${REPL_USER}"@'127.0.0.1';
        FLUSH PRIVILEGES;
EOF

    # bootstrap a RW server
    log_info "==================== bootstrap master server ..."
    MM_ID=1
    log_info "Deploy polardb master server for multi master at port=${RW1_PORT}"
    # init data home directory with local disk
    init_mysql_datadir ${MASTER_HOST} ${RW1_HOME} 0

    # set my.cnf
    MY_CNF=${RW1_HOME}/my.cnf
    cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
    sed -i -e "s#<LOCAL_HOME>#${RW1_HOME}#g" \
           -e "s#<BASE_DIR>#${MYSQL_BASE}#g" \
           -e "s#<DATA_DIR>#${RW1_HOME}/data#g" \
           -e "s#<BLOG>#${RW1_HOME}/blog#g" \
           -e "s#<PORT>#${RW1_PORT}#g" \
           -e "s#<MM_HOME>#${RW1_HOME}#g" \
           -e "s/<MM_ID>/${MM_ID}/g" \
           -e "s/<CC_HOST>/${CC_HOST}/g" \
           -e "s/^#MM_COMMON/loose/g" \
           -e "s/<RDMA_PORT>/${GLOG_PORT}/g" \
           -e "s/^#MM_RW/loose/g" \
           -e "s/<CC_PORT>/${CC_PORT}/g" \
           ${MY_CNF}
    get_mysql_params ${MY_CNF} ${MASTER_HOST}
    bootstrap ${MYSQL_BASE}/bin ${MASTER_HOST} ${RW1_PORT} ${MY_CNF} || exit 1
    init_root_user ${MYSQL_BASE}/bin ${MASTER_HOST} || exit 1

    log_info "Creating replicator profile on master server ..."
    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${RW1_PORT} <<EOF
        CREATE USER "${REPL_USER}"@'%' IDENTIFIED BY "${REPL_PASS}";
        GRANT ALL PRIVILEGES ON *.* TO "${REPL_USER}"@'%';
        CREATE USER "${REPL_USER}"@'127.0.0.1' IDENTIFIED BY "${REPL_PASS}";
        GRANT ALL PRIVILEGES ON *.* TO "${REPL_USER}"@'127.0.0.1';
        FLUSH PRIVILEGES;
EOF

    while [[ ${MM_ID} -lt ${MASTER_COUNT} ]]; do
      log_info "=============================================================="
      ((MM_ID++))
      # start another master server with same datadir as master1
      RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
      RW_HOME=${MASTER_HOME}/rw_${RW_PORT}
      log_info "Start another polardb master server for multi master at port=${RW_PORT} data_home=${RW_HOME}"
      init_mysql_datadir ${MASTER_HOST} ${RW_HOME} 1   # Just used to skip data/blog dir
      /bin/rm -rf ${RW1_HOME}/blog${MM_ID}
      mkdir ${RW1_HOME}/blog${MM_ID}

      MY_CNF=${RW_HOME}/my.cnf
      cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
      sed -i -e "s#<LOCAL_HOME>#${RW_HOME}#g" \
             -e "s#<BASE_DIR>#${MYSQL_BASE}#g" \
             -e "s#<DATA_DIR>#${RW1_HOME}/data#g" \
             -e "s#<BLOG>#${RW1_HOME}/blog${MM_ID}#g" \
             -e "s#<PORT>#${RW_PORT}#g" \
             -e "s#<MM_HOME>#${RW1_HOME}#g" \
             -e "s/<MM_ID>/${MM_ID}/g" \
             -e "s/<CC_HOST>/${CC_HOST}/g" \
             -e "s/^#MM_COMMON/loose/g" \
             -e "s/<RDMA_PORT>/${GLOG_PORT}/g" \
             -e "s/^#MM_RW/loose/g" \
             -e "s/<CC_PORT>/${CC_PORT}/g" \
             ${MY_CNF}
      get_mysql_params ${MY_CNF} ${MASTER_HOST}
      /bin/rm -rf ${RW_HOME}/log ${RW_HOME}/tmp
      mkdir -p ${RW_HOME}/log ${RW_HOME}/tmp || fatal_error "Failed to set data directory for master"
      start_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${RW_PORT} ${MY_CNF}
    done
    ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${CC_PORT} -e "SELECT * FROM INFORMATION_SCHEMA.INNODB_CLUSTER_REGISTRY;"
    sleep 30

    if [[ ${GLOBAL_STANDBY} -eq 1 || ${GLOBAL_STANDBY_REPLIC} -eq 1 ]]; then
      # Add a global standby node
      log_info "==================== Add a global standby node ..."
      GS_PORT=`expr ${CC_PORT} + 20`
      GS_HOME=${MASTER_HOME}/gs_${GS_PORT}
      /bin/rm -rf ${GS_HOME}
      mkdir -p ${GS_HOME} || fatal_error "failed to create data directory for global standby node"

      log_info "Deploy polardb global standby node at port=${GS_PORT} ..."
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        stop_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${RW_PORT}
        ((MM_ID++))
      done
      stop_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${CC_PORT}
      sleep 30

      # copy data directory of standby from master
      log_info "copy data directory of standby from master"
      cp -r ${RW1_HOME}/* ${GS_HOME}/ || fatal_error "Failed to copy data from master data directory to standby data directory"
      # Remove OLD redo logfiles and error log
      log_info "remove OLD redo logfiles and error log"
      /bin/rm -rf ${GS_HOME}/blog* ${GS_HOME}/log ${GS_HOME}/tmp ${GS_HOME}/data/ib_logfile* ${GS_HOME}/data/auto*.cnf
      mkdir ${GS_HOME}/blog ${GS_HOME}/log ${GS_HOME}/tmp

      # set my.cnf
      MY_CNF=${GS_HOME}/my.cnf
      cp ${BASE}/my_pdb_local_template.cnf ${MY_CNF}
      sed -i -e "s#<LOCAL_HOME>#${GS_HOME}#g" \
             -e "s#<BASE_DIR>#${MYSQL_BASE}#g" \
             -e "s#<DATA_DIR>#${GS_HOME}/data#g" \
             -e "s#<BLOG>#${GS_HOME}/blog#g" \
             -e "s#<PORT>#${GS_PORT}#g" \
             -e "s/#polar_master_host/polar_master_host = ${CC_HOST}/g" \
             -e "s/#polar_master_port/polar_master_port = ${CC_PORT}/g" \
             -e "s/#polar_master_user_name/polar_master_user_name = ${REPL_USER}/g" \
             -e "s/#polar_master_user_password/polar_master_user_password = ${REPL_PASS}/g" \
             -e "s/^#MM_COMMON/loose/g" \
             -e "s/^#MM_GS/loose/g" \
             ${MY_CNF}

      # start CC with special configuration
      MY_CNF=${CC_HOME}/my.cnf
      log_info "start CC with special configuration"
      sed -i "s/^#loose_innodb_cc_glog_combine_all/loose_innodb_cc_glog_combine_all/g" ${MY_CNF}
      start_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${CC_PORT} ${MY_CNF} || fatal_error "Can't start CC server"
      ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${CC_PORT} -e "ALTER SYSTEM WAIT GLOBAL LOGS UNTIL NOW();"
      stop_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${CC_PORT}
      sed -i "s/^loose_innodb_cc_glog_combine_all/#loose_innodb_cc_glog_combine_all/g" ${MY_CNF}

      sleep 30
      # COPY redo log files from CC's glog directory
      log_info "COPY redo log files from CC's glog directory"
      cp ${CC_HOME}/glog/ib_logfile* ${GS_HOME}/data/

      # Start CC server, RW servers and global standby
      log_info "==================== Start CC server and RW servers and global standby ..."
      start_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${CC_PORT} ${CC_HOME}/my.cnf || fatal_error "Can't start CC server after configure global standby"
      MM_ID=1
      while [[ ${MM_ID} -le ${MASTER_COUNT} ]]; do
        RW_PORT=`expr ${CC_PORT} + ${MM_ID}`
        RW_HOME=${MASTER_HOME}/rw_${RW_PORT}
        start_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${RW_PORT} ${RW_HOME}/my.cnf || fatal_error "Can't start master server for multi master cluster after configure global standby"
        ((MM_ID++))
      done
      start_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${GS_PORT} ${GS_HOME}/my.cnf || fatal_error "Can't start global standby"
      ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${CC_PORT} -e "SELECT * FROM INFORMATION_SCHEMA.INNODB_CLUSTER_REGISTRY;"
      ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${CC_PORT} -e "SHOW POLAR GLOBAL STANDBYS;"

      if [[ ${GLOBAL_STANDBY_REPLICA} -eq 1 ]]; then
        # Add 1 standard global replica and 1 global replica for AP registered with global standby
        log_info "================== Add 1 standard global replica and 1 global replica for AP registered with global standby ..."
        log_info "Start a standard global standby replica and columnar global standby replica"
        GSR_PORT=`expr ${GS_PORT} + 1`
        GSR_HOME=${MASTER_HOME}/gsr_${GSR_PORT}
        GSA_PORT=`expr ${GS_PORT} + 2`
        GSA_HOME=${MASTER_HOME}/gsr_${GSA_PORT}
        REPLICA_CONF_STR="${GSR_PORT}:${GSR_HOME}:0;${GSA_PORT}:${GSA_HOME}:1"
        OLD_MASTER_HOME=${MASTER_HOME}
        OLD_MASTER_PORT=${MASTER_PORT}
        MASTER_HOME=${GS_HOME}
        MASTER_PORT=${GS_PORT}
        deploy_replicas 1 1
        MASTER_HOME=${OLD_MASTER_HOME}
        MASTER_PORT=${OLD_MASTER_PORT}
        REPLICA_CONF_STR=""
      fi
    fi

    if [[ ${GLOBAL_REPLICA} -eq 1 ]]; then
      # Add 1 standard global replica and 1 global replica for AP registered with cache center
      log_info "================== Add 1 standard global replica and 1 global replica for AP registered with CC ..."
      log_info "Start a standard global replica and columnar global replica"
      OLD_MASTER_HOME=${MASTER_HOME}
      OLD_MASTER_PORT=${MASTER_PORT}
      GR_PORT=`expr ${CC_PORT} + 11`
      GR_HOME=${MASTER_HOME}/gr_${GR_PORT}
      GA_PORT=`expr ${CC_PORT} + 12`
      GA_HOME=${MASTER_HOME}/gr_${GA_PORT}
      REPLICA_CONF_STR="${GR_PORT}:${GR_HOME}:0;${GA_PORT}:${GA_HOME}:1"
      MASTER_HOME=${CC_HOME}
      MASTER_PORT=${CC_PORT}
      deploy_cc_replicas 1 ${RW1_HOME}
      MASTER_HOME=${OLD_MASTER_HOME}
      MASTER_PORT=${OLD_MASTER_PORT}
      REPLICA_CONF_STR=""
   fi
}

# main
if [[ -z "$1" ]]; then
    # deploy master node
    if [[ ${FOR_MM} -eq 1 ]]; then
        deploy_multi_master
    else
        deploy_master
        ${MYSQL_BASE}/bin/mysql -uroot -h127.0.0.1 -P${MASTER_PORT} -e "SHOW POLAR status\G"
    fi

    if [[ ! -z ${STANDBY_CONF_STR} ]]; then
        # depoly standby node(s)
        deploy_standbys
    fi

    if [[ ! -z ${REPLICA_CONF_STR} ]]; then
        # deploy replica node(s)
        deploy_replicas 1 0
    fi
elif [[ ${FOR_MM} -ne 1 ]]; then
    get_mysql_params ${MASTER_HOME}/my.cnf
    pid=$(check_mysqld ${MYSQL_BASE}/bin ${MASTER_HOST} ${MASTER_PORT})
    [[ ${pid} -eq 0 ]] && fatal_error "Database server is not running at ${MASTER_HOST}:${MASTER_PORT}"

    if [[ "$1" == "add_replica" ]]; then
        [[ ! -z $2 ]] || fatal_error "Missing configuration string for add_replica command"
        REPLICA_CONF_STR=$2

        # deploy new replica node with existing master node
        deploy_replicas `expr ${REPLICA_COUNT} + 1` 0
    elif [[ "$1" == "add_standby" ]]; then
        [[ ! -z $2 ]] || fatal_error "Missing configuration string for add_standby command"
        STANDBY_CONF_STR=$2
    
        # deploy new standby node with existing master node
        deploy_standbys
    else
        fatal_error "Invalid command: $1"
    fi
else
    log_error "Adding standby/replica isn't supported for multimaster cluster now"
    exit 1
fi
