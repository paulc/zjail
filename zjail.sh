#!/bin/sh

set -o pipefail 
set -o nounset
# We dont 'set -o errexit' as we handle errors in _check

DEBUG="${DEBUG:-}"
COLOUR="${COLOUR:-}"

### Utils 

_NORMAL="$(printf "\033[0m")"
_RED="$(printf "\033[0;31m")"
_YELLOW="$(printf "\033[0;33m")"
_CYAN="$(printf "\033[0;36m")"

_log_cmdline() {
    local _cmd="$@"
    printf '%s' "${COLOUR:+${_YELLOW}}" >&2
    printf '%s [%s]\n' "$(date '+%b %d %T')" "CMD: $_cmd" >&2
    printf '%s' "${COLOUR:+${_CYAN}}" >&2
}

_log() {
    # Run command optionally printing debug output if $DEBUG is set
    # (in colour if $COLOUR is set) and capture stdout/err
    #
    # Return exit status in $?
    #
    # Note: The cmdline is `eval`-ed so need to be careful with quoting .
    #   DIR="A B C"
    #   _log mkdir \"${DIR}\"
    #
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "CMD: $_cmd" >&2
        printf '%s' "${COLOUR:+${_CYAN}}" >&2
        eval "$_cmd" 2>&1 | sed -e 's/^/     | /' >&2
        local _status=$?
        if [ $_status -eq 0 ]
        then
            printf '%s' "${COLOUR:+${_NORMAL}}" >&2
        else
            printf '%s[ERROR (%s)]%s\n' "${COLOUR:+${_RED}}" "$_status" "${COLOUR:+${_NORMAL}}" >&2
        fi
        return $_status
    else 
        eval "$_cmd"
    fi 
}

_silent() {
    # Run command silently (if DEBUG set just output command)
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "CMD: $_cmd" >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    fi
    eval "$_cmd" >/dev/null 2>&1
}

_run() {
    # Run command directly (logs cmd if $DEBUG set)
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "CMD: $_cmd" >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    fi
    eval "$_cmd"
}


_check() {
    # Run command optionally printing debug output if $DEBUG is set
    # (in colour if $COLOUR is set) and exit if fails
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "CMD: $_cmd" >&2
        printf '%s' "${COLOUR:+${_CYAN}}" >&2
        eval "$_cmd" 2>&1 | sed -e 's/^/     | /' >&2
        local _status=$?
        if [ $_status -eq 0 ]
        then
            printf '%s' "${COLOUR:+${_NORMAL}}" >&2
            return $_status
        else
            printf '%s[FATAL (%s)]%s\n' "${COLOUR:+${_RED}}" "$_status" "${COLOUR:+${_NORMAL}}" >&2
            exit $_status
        fi
    else
        eval "$_cmd" || exit $?
    fi 

}

_install_stdin() {
    # Run install utility with input from stdin - needed as /bin/sh 
    # doesnt support <(...)
    local _args=""
    local _tmp=$(mktemp) || return $?
    local _opts=$(getopt bCcdpSsUvB:D:f:g:h:l:M:m:N:o:T: $*) || return $?
    set -- $_opts
    while :; do
      case "$1" in
        --) shift;break
            ;;
        *)  _args="${_args} $1";shift
            ;;
      esac
    done
    tee -a "${_tmp}" 2>&1
    install ${_args} "${_tmp}" $*
    local _status=$?
    rm -f "${_tmp}"
    return $_status
}

_fatal() {
    # Exit with message
    printf '%sFATAL: %s%s\n' "${COLOUR:+${_RED}}" "$@" "${COLOUR:+${_NORMAL}}"
    exit 1
}

_exitf() {
    printf '%s' "${COLOUR:+${_NORMAL}}"
}

trap _exitf EXIT

### ZFS Layout
#
# ${ZPOOL}/zjail mountpoint=${ZJAIL}
# ${ZPOOL}/zjail/dist/<arch>/<os-release>
# ${ZPOOL}/zjail/base/<arch>/<base>
# ${ZPOOL}/zjail/run/<arch>/<image>>
#

### Config

ARCH="$(/usr/bin/uname -m)" 
ABI="$(/usr/bin/printf '%s:%d:%s' $(/usr/bin/uname -s) $(($(/usr/bin/uname -U) / 100000)) $(/sbin/sysctl -n hw.machine_arch))"
OS_RELEASE="$(/sbin/sysctl -n kern.osrelease)" 
OS_RELEASE="${OS_RELEASE%-p[0-9]*}"     # Strip patch
ZPOOL="${ZPOOL:-zroot}"
ZJAIL="${ZJAIL:-/zjail}"
ZJAIL_ROOT_DATASET="${ZPOOL}/zjail"
ZJAIL_DIST_DATASET="${ZJAIL_ROOT_DATASET}/dist/${ARCH}"
ZJAIL_BASE_DATASET="${ZJAIL_ROOT_DATASET}/base/${ARCH}"
ZJAIL_RUN_DATASET="${ZJAIL_ROOT_DATASET}/run/${ARCH}"
ZJAIL_DIST="${ZJAIL}/dist/${ARCH}"
ZJAIL_BASE="${ZJAIL}/base/${ARCH}"
ZJAIL_RUN="${ZJAIL}/run/${ARCH}"
DIST_SRC="${DIST_SRC:-http://ftp.freebsd.org/pub/FreeBSD/releases/}"

create_zfs_datasets () {
    _silent /sbin/zfs list -H -o name \"${ZJAIL_ROOT_DATASET}\" && _fatal "Dataset ${ZJAIL_ROOT_DATASET} exists"
    _check /sbin/zfs create -o compression=lz4 -o mountpoint=\"${ZJAIL}\" -p \"${ZJAIL_ROOT_DATASET}\" 
    _check /sbin/zfs create -p \"${ZJAIL_DIST_DATASET}\" 
    _check /sbin/zfs create -p \"${ZJAIL_BASE_DATASET}\" 
    _check /sbin/zfs create -p \"${ZJAIL_RUN_DATASET}\" 
}

fetch_release() {
    local _release="${1:-${OS_RELEASE}}"
    _silent /bin/test -d \"${ZJAIL_DIST}\" || _fatal "ZJAIL_DIST [${ZJAIL_DIST}] not found"
    _check /bin/mkdir \"${ZJAIL_DIST}/${_release}\" 
    if [ "${ARCH}" = "amd64" ]
    then
        local _sets="base.txz lib32.txz"
    else 
        local _sets="base.txz"
    fi
    for _f in $_sets
    do
        _check /usr/bin/fetch -o \"${ZJAIL_DIST}/${_release}/${_f}\" \"${DIST_SRC}/${ARCH}/${_release}/${_f}\"
    done
}

create_base() {
    local _name="${1:-${OS_RELEASE}}"
    local _release="${2:-${OS_RELEASE}}"
    _silent /bin/test -d \"${ZJAIL_BASE}\" || _fatal "ZJAIL_BASE [${ZJAIL_BASE}] not found"
    _silent /bin/test -d \"${ZJAIL_DIST}/${_release}\" || _fatal "RELEASE [${ZJAIL_DIST}/${_release}] not found"
    _silent /bin/test -d \"${ZJAIL_BASE}/${_name}\" && _fatal "BASE [${ZJAIL_BASE}/${_name}] exists"
    _check /sbin/zfs create -p \"${ZJAIL_BASE_DATASET}/${_name}\" 
    for _f in "${ZJAIL_DIST}/${_release}"/*.txz
    do
        _check /usr/bin/tar -C \"${ZJAIL_BASE}/${_name}\" -xf \"${_f}\"
    done
    _check /sbin/zfs snapshot \"${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')\"
}

update_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: update_base <base>"
    fi
    _silent /bin/test -d \"${ZJAIL_BASE}/${_name}\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    # Copy local resolv.conf 
    _check /bin/cp /etc/resolv.conf \"${ZJAIL_BASE}/${_name}/etc/resolv.conf\"
    # Run freebsd-update in chroot
    _check PAGER=\\"/usr/bin/tail -n0\\" /usr/sbin/chroot \"${ZJAIL_BASE}/${_name}\" /usr/sbin/freebsd-update --not-running-from-cron fetch
    _check PAGER=/bin/cat /usr/sbin/chroot \"${ZJAIL_BASE}/${_name}\" /usr/sbin/freebsd-update --not-running-from-cron install 


}

snapshot_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: snapshot_base <base>"
    fi
    _silent /bin/test -d \"${ZJAIL_BASE}/${_name}\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    _check /sbin/zfs snapshot \"${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')\"
}

get_latest_snapshot() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: get_latest_snapshot <base>"
    fi
    _silent /bin/test -d \"${ZJAIL_BASE}/${_name}\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    _run "zfs list -H -t snap -s creation -o name \"${ZJAIL_BASE_DATASET}/${_name}\" | tail -1"
}

cli() {
    while :
    do
        read -p 'zjail> ' cmd
        ( 
          DEBUG=1
          COLOUR=1
          . ${0}
          eval $cmd
        )
    done
}

if [ "${1:-}" = "cli" ]
then
    cli
fi
