#!/usr/bin/python
#coding:utf-8

# Parallel loading of mysqldump result file

from __future__ import print_function

from datetime import datetime
from decimal import Decimal
from multiprocessing import Process, Value
from optparse import OptionParser
import ctypes
import os
import shlex
import shutil
import subprocess
import sys
import time
import traceback
import errno
import re
import random

current_file_path = os.path.abspath(__file__)
current_file_dir = os.path.dirname(os.path.abspath(__file__))
testscript_dir = os.path.dirname(current_file_dir)
class bcolors:
    RED = '\033[31m'
    GREEN = '\033[32m'
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

start_time = datetime.now()

parser = OptionParser()
parser.add_option("-m", "--mysql", dest="mysql_path",
                  help="Path of mysql binary",
                  default="/usr/local/bin/mysql",
                  type="string", action="store")
parser.add_option("-f", "--mysql_dump_file", dest="mysql_dump_file",
                  help="output file of mysqldump",
                  default="{}/out.sql".format(current_file_dir),
                  type="string", action="store")
parser.add_option("-d", "--database",
                  dest="database",
                  help="use this database after connected",
                  default=None, type="string", action="store")
parser.add_option("-s", "--socket",
                  dest="socket",
                  help="Use this socket to connect",
                  default='', type="string", action="store")
parser.add_option("-u", "--user",
                  dest="user",
                  help="default user",
                  default="root",
                  type="string", action="store")
parser.add_option("-p", "--password",
                  dest="password",
                  help="default password",
                  default=None,
                  type="string", action="store")
parser.add_option("-H", "--host",
                  dest="host",
                  help="db hostname",
                  default="localhost",
                  type="string", action="store")
parser.add_option("-P", "--port",
                  dest="port",
                  help="db listening port",
                  default=8250, type="int", action="store")
parser.add_option("-l", "--line_per_file",
                  dest="line_per_file",
                  help="Num of INSERT per file",
                  default=16, type="int", action="store")
parser.add_option("-x", "--parallel",
                  dest="parallel",
                  help="Num of parallel running tasks (range between [1,1024])",
                  default=8, type="int", action="store")
parser.add_option("-t", "--tmp_dir",
                  dest="tmp_dir",
                  type="string",
                  help="Temporary dir for storing splitted data file",
                  default="/tmp/",
                  action="store")
parser.add_option("-c", "--delete_after_load",
                  dest="delete_after_load",
                  help="Delete tmpfile after load",
                  default=True,
                  action="store_true")
parser.add_option("-b", "--fast_mode",
                  dest="fast_mode",
                  help="Disable innodb_flush_log_at_trx_commit, unique_checks, etc",
                  default=True,
                  action="store_true")
parser.add_option("-v", "--verbose",
                  dest="verbose",
                  help="Show debug info", action="store_true")
(options, args) = parser.parse_args()

new_tmp_dir = "this_is_temp_dir_for_chunks"
tmp_dir = os.path.join(options.tmp_dir, new_tmp_dir)

input_file = os.path.abspath(options.mysql_dump_file)
cur_file_idx = 0
schema_file = os.path.join(tmp_dir, "f_schema.sql")
all_data_files = []

index_recover_ddl_stmts_file = os.path.join(tmp_dir, "f_index_recover_ddl_stmts.sql")
index_recover_ddl_stmts = []

"""
Util file lock. Example usage:

    with FileLock("/tmp/ddd.txt") as flk:
        do_something()

This file lock is typically useful for coordinating between multi-process.
Not suitable for use in multi-thread environment.
"""
class FileLock:
    def __init__(self, file_path, timeout=60 * 5):
        """
            Default timeout as 5 minute to prevent disaster.
            Setting timeout to 0 means no timeout.
        """
        self.file_path = file_path
        if not os.path.isabs(file_path):
            fp = os.path.join(os.path.curdir, file_path)
            self.file_path = fp
        self.timeout = timeout
        self.is_locked = False
        self.hard_timeout = 60 * 120
        self.fd = 0
        if self.timeout > self.hard_timeout:
            self.timeout = self.hard_timeout

    def acquire(self):
        start_time = time.time()
        while True:
            try:
                self.fd = os.open(self.file_path, os.O_CREAT | os.O_EXCL | os.O_RDWR)
                self.is_locked = True
                break
            except OSError as e:
                if e.errno != errno.EEXIST:
                    raise
                period = time.time() - start_time
                timeout_msg = "File lock timeout after {} seconds at \
                               file " + self.file_path
                if (self.timeout is None or self.timeout <= 0):
                    if period < self.hard_timeout:
                        continue
                    else:
                        raise Exception(timeout_msg.format(self.hard_timeout))
                if period >= self.timeout:
                    raise Exception(timeout_msg.format(period))

                time.sleep(0.5)
                continue

    def release(self):
        if self.is_locked:
            os.close(self.fd)
            #os.unlink(self.file_path)
            self.is_locked = False

    def __enter__(self):
        if not self.is_locked:
            self.acquire()

    def __exit__(self, type, value, traceback):
        if self.is_locked:
            self.release()

    def __del__(self):
        self.release()
        if os.path.exists(self.file_path):
            os.unlink(self.file_path)

def print_msg(*args, **kwargs):
    fp = os.path.join(current_file_dir, "SuiteAllPyFileLock_print.lock")
    with FileLock(fp):
        print(*args, **kwargs)

def print_if_verbose(msg):
    if not options.verbose:
        return
    print_msg(msg)

def print_warn(msg):
    print_msg(bcolors.RED + "[WARN] " + bcolors.ENDC + msg)

def print_info(msg):
    print_msg(bcolors.BOLD + "[INFO] " + bcolors.ENDC + msg)

def check_output(command):
    process = subprocess.Popen(shlex.split(command), shell=False,
                               stdin=subprocess.PIPE, stderr=subprocess.PIPE,
                               stdout=subprocess.PIPE)
    output, err = process.communicate()
    retcode = process.poll()
    if retcode:
        err_msg = "Execute command failed. Error code {}. Command: {}, output: {}, err: {}".format(
                retcode, command, output, err)
        raise Exception(err_msg)
    return output

# Prefer socket connection if available
def get_mysql_exe_cmd():
    mysql_exe_cmd = ""
    if len(options.socket):
        mysql_exe_cmd = "{mysql_arg} -u{user_arg} --socket {socket_arg} ".format(
                mysql_arg=options.mysql_path,
                user_arg=options.user,
                socket_arg=options.socket)
    elif len(options.password):
        mysql_exe_cmd = "{mysql_arg} -u{user_arg} -p{password} --host {host_arg} --port {port_arg} ".format(
                mysql_arg=options.mysql_path,
                user_arg=options.user,
                password=options.password,
                host_arg=options.host,
                port_arg=options.port)
    else:
        mysql_exe_cmd = "{mysql_arg} -u{user_arg} --host {host_arg} --port {port_arg} ".format(
                mysql_arg=options.mysql_path,
                user_arg=options.user,
                host_arg=options.host,
                port_arg=options.port)
    return mysql_exe_cmd

# Because we write to /tmp by default, it is required that the tmpdir should
# have at least 2GB available to prevent disaste.
def check_tmp_dir_space():
    disk = os.statvfs(tmp_dir)
    disk_available_GB = (disk.f_bavail * disk.f_frsize) / 1024.0 / 1024 / 1024
    if disk_available_GB < 2:
        print_msg("Less than 2GB available under {}; please specify another tmp dir".format(tmp_dir))
        exit(1)

def split_file():
    if not os.path.exists(input_file):
        raise Exception("input file not exists: {}".format(input_file))

    print_msg("Splitting input file `{}` into chunks ...".format(
        input_file, options.line_per_file))

    if os.path.exists(tmp_dir):
        opath = tmp_dir
        npath = '{}-back'.format(tmp_dir.rstrip('/'))
        print_msg("Tmp dir '{op_arg}' already exists. Move it to '{np_arg}'.".format(op_arg=opath, np_arg=npath))
        if os.path.exists(npath):
            print_msg("`{}` exists. Remove it first...".format(npath))
            shutil.rmtree(npath)
        shutil.move(opath, npath)

    check_output("mkdir -p {}".format(tmp_dir))
    check_tmp_dir_space()

    f_schema = open(schema_file, "w+")
    f_cur_data_file = None
    total_lines = 0
    line_per_file = max(options.line_per_file, 1)
    cur_file_lines = 0
    global cur_file_idx
    global all_data_files
    with open(options.mysql_dump_file, "r") as ifile:
        for line in ifile:
            total_lines += 1
            if not line.startswith('INSERT'):
                # A better way. FUTURE WORK.
                # If there is already CREATE DB / USE DB in the sql file, we use that DB.
                # If there is more than 1 CREATE DB / USE DB in the sql, we abort execution,
                # and save the leftover content to another file.
                if line.startswith('CREATE DATABASE') or line.startswith('USE '):
                    print_msg('Not implemented creating db or switch db inside source file.')
                    print_msg('Please guarantee that the whole source file belongs to a single database/schema and retry.')
                    exit(1)
                if line.startswith('SET') and ('GTID_PURGED' in line):
                    print_msg('Skip loading GTID_PURGED setting: {}'.format(line))
                    continue
                f_schema.write(line)
            else:
                if cur_file_lines >= line_per_file:
                    f_cur_data_file.flush()
                    f_cur_data_file.close()
                    f_cur_data_file = None
                    cur_file_lines = 0
                    cur_file_idx += 1

                if f_cur_data_file is None:
                    new_data_file_path = os.path.join(tmp_dir, "f_data_{}.sql".format(cur_file_idx))
                    all_data_files.append(new_data_file_path)
                    f_cur_data_file = open(new_data_file_path, "w+")
                    print_msg("\rCreating data file {}...".format(new_data_file_path), end='')
                    sys.stdout.flush() # flush stdout so that cursor will not blinking...
                    cur_file_lines = 0

                f_cur_data_file.write(line)
                cur_file_lines += 1

    f_schema.flush()
    f_schema.close()
    if f_cur_data_file is not None:
        f_cur_data_file.flush()
        f_cur_data_file.close()

    print_msg("Done ({} line processed in total)".format(total_lines))

def source_single_file(db, file_path, task_id=0, cur_file_idx = None, total_file_cnt = None):
    cmd = "{mysql_exe_cmd} {db_arg} -e 'source {file_arg}'".format(
            mysql_exe_cmd=get_mysql_exe_cmd(),
            db_arg=db,
            file_arg=file_path)

    task_info = ""
    if cur_file_idx is not None and total_file_cnt is not None:
        task_info = "({}/{})".format(cur_file_idx, total_file_cnt)

    if options.verbose:
        print_msg("[task {task_id_arg}] {task_arg} cmd: `{cmd_arg}`".format(
            task_id_arg=task_id, task_arg=task_info, cmd_arg=cmd))
    else:
        print_msg("[task {task_id_arg}] {task_arg} Loading file `{file_arg}`".format(
            task_id_arg=task_id, task_arg=task_info, file_arg=file_path))
    check_output(cmd)

    if options.delete_after_load:
        print_if_verbose("[task {task_id_arg}] {task_arg} File loaded, remove now: {file_arg}".format(
                task_id_arg=task_id, task_arg=task_info, file_arg=file_path))
        os.remove(file_path)

class MyProcess(Process):
    def __init__(self):
        super(MyProcess, self).__init__()

    def work(self):
        """do work"""
        raise Exception("test")

    def run(self):
        try:
            self.work()
        except Exception as e:
            print_msg(e.message)
            traceback.print_exc()
            sys.exit(1)

class MyProcessPool:
    def __init__(self):
        self.process = []
        self.results = []
        self.closed = False

    def addProcess(self, process):
        if self.closed == True:
            raise Exception("can't add process after start.")
        self.process.append(process)

    def start(self):
        self.closed = True
        for p in self.process:
            p.start()

    def join(self):
        for p in self.process:
            p.join()
            self.results.append(p.exitcode)

    def getResult(self):
        for result in self.results:
            if result != 0:
                return False
        return True

class MyAtomicCounter:
    def __init__(self):
        self.counter = Value(ctypes.c_long, 0)

    def increment(self, value):
        with self.counter.get_lock():
            self.counter.value += value
            return self.counter.value

    def decrease(self, value):
        with self.counter.get_lock():
            self.counter.value -= value
            return self.counter.value

    def get(self):
        return self.counter.value

    def set(self, value):
        with self.counter.get_lock():
            self.counter.value = value

class InsertWorker(MyProcess):
    def __init__(self, counter, task_id):
        super(MyProcess, self).__init__()
        self.counter = counter
        self.task_id = task_id

    def run(self):
       total_file_cnt = len(all_data_files)
       while True:
           cur_idx = self.counter.increment(1)
           cur_idx -= 1
           if cur_idx >= total_file_cnt:
               break
           try:
               source_single_file(options.database, all_data_files[cur_idx],
                                  self.task_id, cur_idx, total_file_cnt)
           except Exception as e:
               print_msg("Exception when insert data: {}".format(str(e)))

def source_parallel():
    process_pool = MyProcessPool()
    atomic_count = MyAtomicCounter()
    for task_id in range(options.parallel):
        new_process = InsertWorker(atomic_count, task_id)
        process_pool.addProcess(new_process)
    process_pool.start()
    process_pool.join()
    res = process_pool.getResult()
    if not res:
        print_msg("Loading failed with unknown error")

def do_create_db(database):
    create_db_cmd = ("{mysql_exec_arg} -e 'CREATE DATABASE IF NOT EXISTS {db_arg}'").format(
            mysql_exec_arg=get_mysql_exe_cmd(), db_arg=database)
    check_output(create_db_cmd)

#
# Foreign key get / set
#
def is_fk_on():
    show_fkc_cmd = """ {mysql_exec_arg} -e "SHOW VARIABLES LIKE '%foreign_key_checks%'" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    fkc_output = check_output(show_fkc_cmd)
    res = re.findall(r'ON', fkc_output, re.MULTILINE)
    fkc_is_on = len(res) > 0
    return fkc_is_on

def do_disable_fkc():
    disable_fkc_cmd = """ {mysql_exec_arg} -e "SET GLOBAL foreign_key_checks = OFF" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    check_output(disable_fkc_cmd)

def do_enable_fkc():
    enable_fkc_cmd = """ {mysql_exec_arg} -e "SET GLOBAL foreign_key_checks = ON" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    check_output(enable_fkc_cmd)

#
# binglog
#
def check_bool_var(var_name):
    show_cmd = """ {mysql_exec_arg} -e "SHOW VARIABLES LIKE '{var_name_arg}'" """.format(mysql_exec_arg=get_mysql_exe_cmd(), var_name_arg=var_name)
    show_output = check_output(show_cmd)
    res = re.findall(r'ON', show_output, re.MULTILINE)
    is_on = len(res) > 0
    return is_on

#
# Unique key get / set
#
def is_fk_on():
    show_ukc_cmd = """ {mysql_exec_arg} -e "SHOW VARIABLES LIKE 'unique_checks'" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    ukc_output = check_output(show_ukc_cmd)
    res = re.findall(r'ON', ukc_output, re.MULTILINE)
    ukc_is_on = len(res) > 0
    return ukc_is_on

def do_disable_ukc():
    disable_ukc_cmd = """ {mysql_exec_arg} -e "SET GLOBAL unique_checks = OFF" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    check_output(disable_ukc_cmd)

def do_enable_ukc():
    enable_ukc_cmd = """ {mysql_exec_arg} -e "SET GLOBAL unique_checks = ON" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    check_output(enable_ukc_cmd)

#
# autocommit key get / set
#
def is_autocommit_off():
    show_autocommit_cmd = """ {mysql_exec_arg} -e "SHOW VARIABLES LIKE 'autocommit'" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    ac_output = check_output(show_autocommit_cmd)
    res = re.findall(r'OFF', ac_output, re.MULTILINE)
    ac_off = len(res) > 0
    return ac_off

def do_enable_autocommit():
    enable_ac_cmd = """ {mysql_exec_arg} -e "SET GLOBAL autocommit = ON" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    check_output(enable_ac_cmd)

def do_disable_autocommit():
    disable_ac_cmd = """ {mysql_exec_arg} -e "SET GLOBAL autocommit = OFF" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    check_output(disable_ac_cmd)

#
# innodb_flush_log_at_trx_commit
#
def get_innodb_flush_log_at_trx_commit():
    cmd = """ {mysql_exec_arg} -e "SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit'" """.format(mysql_exec_arg=get_mysql_exe_cmd())
    cmd_res = check_output(cmd)
    res = re.findall(r'innodb_flush_log_at_trx_commit\t(.*)', cmd_res, re.MULTILINE)
    if len(res) < 1:
        print_msg("Fail to get innodb_flush_log_at_trx_commit variable from mysqld; SHOW VARIABLES result is:\n{}".format(cmd_res))
        exit(1)
    val = int(res[0])
    print_if_verbose("Current innodb_flush_log_at_trx_commit setting: {}".format(val))
    return val

def do_set_innodb_flush_log_at_trx_commit(new_val):
    cmd = """ {mysql_exec_arg} -e "SET GLOBAL innodb_flush_log_at_trx_commit = {new_val_arg}" """.format(
            mysql_exec_arg=get_mysql_exe_cmd(), new_val_arg=new_val)
    check_output(cmd)


def remove_secondary_indexes():
    pass

#               ---------------------------
#               ----  start execution ----
#               ---------------------------

print_msg("------- Loading data with configuration ----------------")
print_msg("mysql binary:             {}".format(options.mysql_path))
print_msg("input mysqldump file:     {}".format(input_file))
print_msg("tmp dir:                  {}".format(tmp_dir))
print_msg("database:                 {}".format(options.database))
print_msg("socket:                   {}".format(options.socket))
print_msg("user:                     {}".format(options.user))
print_msg("password (ignored now):   {}".format(options.password))
print_msg("port:                     {}".format(options.port))
print_msg("line per data file:       {}".format(options.line_per_file))
print_msg("parallel:                 {}".format(options.parallel))
print_msg("verbose:                  {}".format(options.verbose))
print_msg("-----------------------------")

# Check connection fist
print_msg("Checking mysql connection using command: `{}` ... ".format(get_mysql_exe_cmd()), end="")
show_processlist_cmd = """{} -e "show processlist;" """.format(get_mysql_exe_cmd())
check_output(show_processlist_cmd)
print_msg("OK")

# Create database if not exists
if options.database is None:
    raise Exception("Please specify a database to load data into")
do_create_db(options.database)

# Check for binlog, if binlog is on, warn.
binlog_is_on_1 = check_bool_var("polar_log_bin")
binlog_is_on_2 = check_bool_var("log_bin")
if binlog_is_on_1 or binlog_is_on_2:
    print_warn("binlog is ON. Consider turn it off while loading data.")

# Check for columnar index, if on, warn.
columnar_is_on = check_bool_var("polar_enable_imci")
if columnar_is_on:
    print_warn("polar_enable_imci is ON. Consider turn it off while loading data.")

# disable foreign key check if ON
fkc_is_on = is_fk_on()
if fkc_is_on:
    print_info("""Foreign key check is ON. Disble it now. Will recover later.""")
    do_disable_fkc()

# disable unique_checks if ON and options.fast_mode
ukc_is_on = is_fk_on()
if ukc_is_on and options.fast_mode:
    print_info("""Unique key check is ON. Disble it now. Will recover later.""")
    do_disable_ukc()

# enable autocommit to avoid large transaction
autocommit_is_off = is_autocommit_off()
if autocommit_is_off:
    print_info("""Autocommit is OFF. Set it to ON to avoid large transaction. Will recover later.""")
    do_enable_autocommit()

# Disable innodb_flush_log_at_trx_commit if ON
old_innodb_flush_log_at_trx_commit = get_innodb_flush_log_at_trx_commit()
cur_innodb_flush_log_at_trx_commit = old_innodb_flush_log_at_trx_commit
if old_innodb_flush_log_at_trx_commit == 1 and options.fast_mode:
    print_info("""innodb_flush_log_at_trx_commit is not 0 now. Set it to 0 to make data loading faster.""")
    do_set_innodb_flush_log_at_trx_commit(0)
    cur_innodb_flush_log_at_trx_commit = 0

try:
    # prepare file
    split_file()
    print_msg("---\n")

    # source schema file
    print_msg("Load schema file `{}` into database `{}` using single thread".format(schema_file, options.database))
    source_single_file(options.database, schema_file)
    print_msg("---\n")

    # Remove secondary index for all empty tables inside options.database to make load faster
    #print_info("Before loading data, remove all secondary index; Will recover later.")
    #print_info("Original schema file is: `{}`".format(schema_file))
    #print_info("Index recovering DDL statements will be stored at `{}` for use in case anything failed afterward".format(index_recover_ddl_stmts_file))
    #tmpfile = open(index_recover_ddl_stmts_file, "w+")
    #tmpfile.close()
    #remove_secondary_indexes()

    # sourcing data file
    if options.parallel <= 1:
        print_msg("Load data file into database `{}` using single thread".format(options.database))
        for file in all_data_files:
            source_single_file(options.database, file)
    else:
        print_msg("Load data file into database `{}` parallelly (parallel={})".format(options.database, options.parallel))
        source_parallel()

    # remove tmp dir
    shutil.rmtree(tmp_dir)
except Exception as e:
    print("Error: {}".format(str(e)))
finally:
    if fkc_is_on:
        print_msg("""Recover foreign key check to ON.""")
        do_enable_fkc()
    if ukc_is_on and options.fast_mode:
        print_msg("""Recover unique key check to ON.""")
        do_enable_ukc()
    if autocommit_is_off:
        print_msg("""Recover autocommit to OFF.""")
        do_disable_autocommit()
    if old_innodb_flush_log_at_trx_commit != cur_innodb_flush_log_at_trx_commit:
        print_msg("""Recover innodb_flush_log_at_trx_commit to old value: """.format(old_innodb_flush_log_at_trx_commit))
        do_set_innodb_flush_log_at_trx_commit(old_innodb_flush_log_at_trx_commit)
        cur_innodb_flush_log_at_trx_commit = old_innodb_flush_log_at_trx_commit

end_time = datetime.now()
time_delta = (end_time - start_time)
time_delta_seconds = time_delta.total_seconds()
m = ((int)(time_delta_seconds)) / 60
s = time_delta_seconds - (m * 60)

print_msg("------ END OF LOADING (used {} minutes {} seconds) -----".format(m, s))
