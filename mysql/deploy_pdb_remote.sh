#!/usr/bin/env bash
BASE="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

if [[ ! -f ${BASE}/../util.sh ]] || [[ ! -f ${BASE}/util.sh ]]; then
    echo "Missing util.sh"
    exit 1
fi

source ${BASE}/../util.sh # log_info/log_error/is_local
source ${BASE}/util.sh  # bootstrap

function usage()
{
    echo -e "Utility to depoly polardb database server with pfs\n\n\
SYNOPSIS:\n\
    $0 [OPTIONs]\n\n\
OPTIONs:\n\
    -b | --base=<MYSQL_INSTALL_DIR>: Specify mysql installation directory\n\
    -c | --copy: Copy mysql binary to remote host via SSH from local\n\
    -d | --data=<MYSQL_DATADIR>: Specify mysql data directory\n\
    -H | --host=<hostname>: Specify hostname/ip to deploy mysql database server, localhost by default\n\
    -p | --port=<PORT>: Specify port on which mysql server run\n\
    --pbd=<PBD>: Specify ploarstore block device number to be used\n\
    -h | --help: Print this help message"
}

# parse options
COPY_BIN=0
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
    -c | --copy)
        shift
        COPY_BIN=1;;
    -d | --data)
        shift
        DATA_HOME=$(get_key_value "$1")
        shift;;
    --data=*)
        DATA_HOME=$(get_key_value "$1")
        shift;;
    -H | --host)
        shift
        HOST=$(get_key_value "$1")
        shift;;
    --host=*)
        HOST=$(get_key_value "$1")
        shift;;
    -p | --port)
        shift
        PORT=$(get_key_value "$1")
        shift;;
    --port=*)
        PORT=$(get_key_value "$1")
        shift;;
    --pbd)
        shift
        PBD=$(get_key_value "$1")
        shift;;
    --pbd=*)
        PBD=$(get_key_value "$1")
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
[[ -z ${PORT} ]] && fatal_error "Missing parameter for --port"
[[ -z ${PBD} ]] && fatal_error "Missing parameter for --pbd"

[[ ! -z ${HOST} ]] || HOST=127.0.0.1

# check and copy binary if required
check_binary ${HOST} ${MYSQL_BASE} ${COPY_BIN} || fatal_error "Invalid value for --base"

PFS="/usr/local/bin/pfs"

exec_cmd2 ${HOST} "${PFS} ls /${PBD}-1/" || fatal_error "Invalid pbd value, make sure it is correctly formated and attached!"

REMOTE_HOME=/${PBD}-1/${PORT}
HOST_ID=1
# set my.cnf
MY_CNF=/tmp/my.cnf
cp ${BASE}/my_pdb_pfs_template.cnf ${MY_CNF}
sed -i -e "s#<LOCAL_HOME>#${DATA_HOME}#g" \
       -e "s#<BASE_DIR>#${MYSQL_BASE}#g" \
       -e "s#<REMOTE_HOME>#${REMOTE_HOME}#g" \
       -e "s#<PBD_NAME>#${PBD}-1#g" \
       -e "s#<PORT>#${PORT}#g" \
       -e "s#<HOST_ID>#${HOST_ID}#g" \
       ${MY_CNF}
get_mysql_params ${MY_CNF}

pid=$(check_mysqld ${MYSQL_BASE}/bin ${HOST})
[[ $pid -ne 0 ]] && fatal_error "Database server is already running with pid=${pid} at ${HOST}:${PORT}"

# init data home directory
init_polardb_datadir ${PFS} ${HOST} ${DATA_HOME} ${REMOTE_HOME}

if [[ $(is_local ${HOST}) -eq 1 ]]; then
    cp ${MY_CNF} ${DATA_HOME}/my.cnf
else
    scp -q ${MY_CNF} ${HOST}:${DATA_HOME}/my.cnf
fi

/bin/rm ${MY_CNF}
MY_CNF=${DATA_HOME}/my.cnf

bootstrap ${MYSQL_BASE}/bin ${HOST} ${PORT} ${MY_CNF} || exit 1

init_root_user ${MYSQL_BASE}/bin ${HOST} || exit 1

exit 0
