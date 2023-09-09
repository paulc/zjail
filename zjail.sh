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
    printf '%s' "${COLOUR:+${_NORMAL}}" >&2
}

_log() {
    # Run command optionally printing debug output if $DEBUG is set
    # (in colour if $COLOUR is set) and capture stdout/err
    #
    # Return exit status in $?
    #
    # Note: The cmdline is `eval`-ed so need to be careful with quoting .
    #   DIR="A B C"
    #   _log mkdir \""${DIR}"\"
    #
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        _log_cmdline "$_cmd"
        printf '%s' "${COLOUR:+${_CYAN}}" >&2
        eval "$_cmd" 2>&1 | sed -e 's/^/     | /' >&2
        local _status=$?
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
        return $_status
    else
        eval "$_cmd"
    fi
}

_run() {
    # Run command directly via eval (logs cmd if $DEBUG set)
    local _cmd="$@"
    [ -n "$DEBUG" ] && _log_cmdline "$_cmd"
    eval "$_cmd"
}

_silent() {
    # Run command silently (if DEBUG set just output command)
    local _cmd="$@"
    [ -n "$DEBUG" ] && _log_cmdline "$_cmd"
    eval "$_cmd" >/dev/null 2>&1
}

_check() {
    # Run command optionally printing debug output if $DEBUG is set
    # (in colour if $COLOUR is set) and exit if fails
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        _log_cmdline "$_cmd"
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
# ${ZPOOL}/${ZJAIL} mountpoint=${ZJAIL}
# ${ZPOOL}/${ZJAIL}/dist/<arch>/<os-release>
# ${ZPOOL}/${ZJAIL}/base/<arch>/<base>
# ${ZPOOL}/${ZJAIL}/run/<arch>/<image>>
# ${ZPOOL}/${ZJAIL}/config
# ${ZPOOL}/${ZJAIL}/volumes
#

### Config

ARCH="$(/usr/bin/uname -m)"
ABI="$(/usr/bin/printf '%s:%d:%s' $(/usr/bin/uname -s) $(($(/usr/bin/uname -U) / 100000)) $(/sbin/sysctl -n hw.machine_arch))"
OS_RELEASE="$(/sbin/sysctl -n kern.osrelease)"
OS_RELEASE="${OS_RELEASE%-p[0-9]*}"     # Strip patch
ZPOOL="${ZPOOL:-zroot}"
ZJAIL="${ZJAIL:-zjail}"
ZJAIL_ROOT_DATASET="${ZPOOL}/${ZJAIL}"
ZJAIL_DIST_DATASET="${ZJAIL_ROOT_DATASET}/dist/${ARCH}"
ZJAIL_BASE_DATASET="${ZJAIL_ROOT_DATASET}/base/${ARCH}"
ZJAIL_RUN_DATASET="${ZJAIL_ROOT_DATASET}/run/${ARCH}"
ZJAIL_CONFIG_DATASET="${ZJAIL_ROOT_DATASET}/config"
ZJAIL_VOLUMES_DATASET="${ZJAIL_ROOT_DATASET}/volumes"
ZJAIL_DIST="/${ZJAIL}/dist/${ARCH}"
ZJAIL_BASE="/${ZJAIL}/base/${ARCH}"
ZJAIL_RUN="/${ZJAIL}/run/${ARCH}"
ZJAIL_CONFIG="/${ZJAIL}/config"

DIST_SRC="${DIST_SRC:-http://ftp.freebsd.org/pub/FreeBSD/releases/}"

### Setup environment

create_zfs_datasets () {
    _silent /sbin/zfs list -H -o name \""${ZJAIL_ROOT_DATASET}"\" && _fatal "Dataset ${ZJAIL_ROOT_DATASET} exists"
    _check /sbin/zfs create -o compression=lz4 -o mountpoint=\""/${ZJAIL}"\" -p \""${ZJAIL_ROOT_DATASET}"\"
    _check /sbin/zfs create -p \""${ZJAIL_DIST_DATASET}"\"
    _check /sbin/zfs create -p \""${ZJAIL_BASE_DATASET}"\"
    _check /sbin/zfs create -p \""${ZJAIL_RUN_DATASET}"\"
    _check /sbin/zfs create -p \""${ZJAIL_CONFIG_DATASET}"\"
    _check /sbin/zfs create -p \""${ZJAIL_VOLUMES_DATASET}"\"
}

### Releases

fetch_release() {
    local _release="${1:-${OS_RELEASE}}"
    _silent /bin/test -d \""${ZJAIL_DIST}"\" || _fatal "ZJAIL_DIST [${ZJAIL_DIST}] not found"
    _check /bin/mkdir \""${ZJAIL_DIST}/${_release}"\"
    if [ "${ARCH}" = "amd64" ]
    then
        local _sets="base.txz lib32.txz"
    else
        local _sets="base.txz"
    fi
    for _f in $_sets
    do
        _check /usr/bin/fetch -o \""${ZJAIL_DIST}/${_release}/${_f}"\" \""${DIST_SRC}/${ARCH}/${_release}/${_f}"\"
    done
}

### Manage bases

create_base() {
    local _name="${1:-${OS_RELEASE}}"
    local _release="${2:-${OS_RELEASE}}"
    _silent /bin/test -d \""${ZJAIL_BASE}"\" || _fatal "ZJAIL_BASE [${ZJAIL_BASE}] not found"
    _silent /bin/test -d \""${ZJAIL_DIST}/${_release}"\" || _fatal "RELEASE [${ZJAIL_DIST}/${_release}] not found"
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" && _fatal "BASE [${ZJAIL_BASE}/${_name}] exists"
    _check /sbin/zfs create -p \""${ZJAIL_BASE_DATASET}/${_name}"\"
    for _f in "${ZJAIL_DIST}/${_release}"/*.txz
    do
        _check /usr/bin/tar -C \""${ZJAIL_BASE}/${_name}"\" -xf \""${_f}"\"
    done
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

update_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: update_base <base>"
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

    # Copy local resolv.conf
    _check /bin/cp /etc/resolv.conf \""${ZJAIL_BASE}/${_name}/etc/resolv.conf"\"

    # Set hostname
    _check /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /bin/hostname \""${_name}"\"

    # Run freebsd-update in chroot
    local _version=$(_run /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /bin/freebsd-version) || _fatal "Cant get freebsd-version"
    _check PAGER=\""/usr/bin/tail -n0"\" /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" \
        /usr/sbin/freebsd-update --currently-running \""${_version}"\" --not-running-from-cron fetch
    _log /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" \
        /usr/sbin/freebsd-update --not-running-from-cron updatesready
    if [ $? -eq 0 ]
    then
        _check PAGER=/bin/cat /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" \
            /usr/sbin/freebsd-update --not-running-from-cron install
    fi

    # Update pkg (bootstrap if necessary)
    
    # Make sure /dev/null is available in chroot
    _check /sbin/mount -t devfs -o ruleset=1 devfs \""${ZJAIL_RUN}/${_instance_id}/dev"\"
    _check /sbin/devfs -m \""${ZJAIL_RUN}/${_instance_id}/dev"\" rule -s 2 applyset

    _log /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg -N
    if [ $? -ne 0 ]
    then
        _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg bootstrap
    fi
    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg update
    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg upgrade

    _check /sbin/umount \""${ZJAIL_RUN}/${_instance_id}/dev"\"

    # Create snapshot
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

chroot_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: chroot_base <base>"
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

    shift
    if [ "$#" -gt 0 ]
    then
        _run /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" $@
    else
        _run /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" env PS1=\""${_name} > "\" /bin/sh
    fi
    # _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

clone_base() {
    local _name="${1:-}"
    local _target="${2:-}"
    if [ -z "${_name}" -o -z "${_target}" ]
    then
        _fatal "Usage: clone_base <base> <target>"
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    _silent /bin/test -d \""${ZJAIL_BASE}/${_target}"\" && _fatal "TARGET [${ZJAIL_BASE}/${_target}] exists"

    local _latest=$(get_latest_snapshot "${_name}")
    if [ -z "${_latest}" ]
    then
        _fatal "Cant find snapshot: ${ZJAIL_BASE}/${_name}"
    fi

    _check /sbin/zfs clone \""${_latest}"\" \""${ZJAIL_BASE_DATASET}/${_target}"\"
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_target}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

snapshot_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: snapshot_base <base>"
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

get_latest_snapshot() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: get_latest_snapshot <base>"
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    _run "/sbin/zfs list -H -t snap -s creation -o name \""${ZJAIL_BASE_DATASET}/${_name}"\" | tail -1"
}

### Instances

# Generate random 64-bit ID as 13 character base32 encoded string
gen_id() {
    # Get 2 x 32 bit unsigned ints from /dev/urandom
    # (od doesnt accept -t u8 so we multiply in bc)
    set -- $(od -v -An -N8 -t u4 /dev/urandom)
    # Reserve ::0 to ::ffff for system
    while [ ${1:-0} -eq 0 -a ${2:-0} -lt 65536 ]
    do
        set -- $(od -v -An -N8 -t u4 /dev/urandom)
    done
    # Ensure id is not all-numeric (invalid jail name) - probability is very low (c. 2.6e-07) but check anyway
    local _id="0000000000000"
    while expr "${_id}" : '^[0-9]*$' >/dev/null
    do
        # Use bc to generate pseudo-base32 encoded string from 64bit uint
        # (Note this isnt a normal base32 and just uses fixed 13 chars (13*5 = 65))
        _id="$(bc -l -e "x = $1 * $2" \
              -e 'for (i=0;i<13;i++) { mod = band(x,31); x = bshr(x,5); if (mod < 10) { c[12-i] = mod + 48 } else { c[12-i] = mod + 65 - 10 } }' \
              -e 'print asciify(c[]),"\n"')"
    done
    printf '%s\n' "${_id}"
}

# Generate 64-bit IPv6 suffix from pseudo-base32 ID
get_ipv6_suffix() {
    printf '%04x:%04x:%04x:%04x\n' $(
        awk -v x="${1}" '
            BEGIN {
                c = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
                for (i=0;i<length(c);i++) {
                    v[substr(c,i+1,1)] = i
                }
                for (i=0;i<13;i++) {
                    print v[substr(x,i+1,1)]
                }
            }' </dev/null \
        | bc -l -e  '
            for (i=0;i<13;i++) {
                out = bshl(out,5) + read()
            }
            print bshr(out,48), " ", band(bshr(out,32),65535), " ", band(bshr(out,16),65535), " ", band(out,65535), "\n"
        ')
}

create_instance() {
    local _base="${1:-}"
    local _usage="$0 [-a] [-h <hostname>] [-s <site_template>] [-t <jail_template>] [-j <jail_param>].. [-c <host_path>:<instance_path>].."

    if [ -z "${_base}" ]
    then
        _fatal "Usage: ${_usage}"
    fi

    shift

    # Check base image and run mount point exists
    _silent /bin/test -d \""${ZJAIL_BASE}/${_base}"\" || _fatal "BASE [${ZJAIL_BASE}/${_base}] not found"
    _silent /bin/test -d \""${ZJAIL_RUN}"\" || _fatal "ZJAIL_RUN [${ZJAIL_RUN}] not found"

    local _latest=$(get_latest_snapshot "${_base}")
    if [ -z "${_latest}" ]
    then
        _fatal "Cant find snapshot: ${ZJAIL_BASE}/${_base}"
    fi
    
    # Generate random 64-bit jail_id and IPv6 suffix
    local _instance_id="$(_run gen_id)"
    if [ ${#_instance_id} -ne 13 ]
    then
        _err "Invalid _instance_id: ${_instance_id}"
    fi

    local _jail_ipv6_suffix=$(get_ipv6_suffix "$_instance_id")

    # Clone base
    _check /sbin/zfs clone \""${_latest}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"

    # Delay options processing until after we have created the image dataset so
    # that we can operate on this directly
    
    local _template=""
    local _site=""
    local _jail_params=""
    local _hostname=""
    local _autostart="off"

    while getopts "ac:s:t:j:h:p:" _opt; do
        case "${_opt}" in
            a)
                _autostart="on"
                ;;
            c)
                local _host_path="${OPTARG%:*}"
                local _instance_path="${OPTARG#*:}"
                _check cp \""${_host_path}"\" \""${ZJAIL_RUN}/${_instance_id}/${_instance_path}"\"
                ;;
            h)
                _hostname="${OPTARG}"
                ;;
            s)
                _site="$(_run cat \""${OPTARG}"\")" || _fatal "Site template not found: ${OPTARG}"
                ;;
            j)
                _jail_params="$(printf '%s\n%s;' "${_jail_params}" "${OPTARG}")"
                ;;
            p)
                # Make sure /dev/null is available in chroot
                _check /sbin/mount -t devfs -o ruleset=1 devfs \""${ZJAIL_RUN}/${_instance_id}/dev"\"
                _check /sbin/devfs -m \""${ZJAIL_RUN}/${_instance_id}/dev"\" rule -s 2 applyset

                # Update pkg (bootstrap if necessary)
                _log /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg -N
                if [ $? -ne 0 ]
                then
                    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg bootstrap
                fi

                _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg install \""${OPTARG}"\"

                _check /sbin/umount \""${ZJAIL_RUN}/${_instance_id}/dev"\"
                ;;
            t)
                _template="$(_run cat \""${OPTARG}"\")" || _fatal "Jail template not found: ${OPTARG}"
                ;;
            \?)
                _fatal "Usage: ${_usage}"
                ;;
            :)
                _fatal "Usage: ${_usage}"
                ;;
        esac
    done

    if [ -z "${_hostname}" ]
    then
        _hostname="${_instance_id}"
    fi

    _check /sbin/zfs set zjail:id=\""${_instance_id}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:hostname=\""${_hostname}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:base=\""${_latest}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:suffix=\""${_jail_ipv6_suffix}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:autostart=\""${_autostart}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"

    local _jail_conf="\
${_site}
${_instance_id} {
    \$id = ${_instance_id};
    \$hostname = \""${_hostname}"\";
    \$suffix = ${_jail_ipv6_suffix};
    path = \""${ZJAIL_RUN}/${_instance_id}"\";
    host.hostname = \""${_hostname}"\";
    persist;
    ${_template}
    ${_jail_params}
}
"
    # Dont use _check to avoid double quoting problems
    _log_cmdline /sbin/zfs set zjail:conf=\""${_jail_conf}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    /sbin/zfs set zjail:conf="${_jail_conf}" "${ZJAIL_RUN_DATASET}/${_instance_id}" || _fatal "Cant set zjail:conf property"

    _check /sbin/zfs snapshot \""${ZJAIL_RUN_DATASET}/${_instance_id}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail -vf - -c ${_instance_id}"

    printf 'ID: %s\nSuffix: %s\n' $_instance_id $_jail_ipv6_suffix
}

list_instances() {



}

edit_jail_conf() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 <instance>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"
    local _tmpfile=$(_run /usr/bin/mktemp) || _fatal "Cant create TMPFILE"
    trap "/bin/rm -f ${_tmpfile}" EXIT
    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" > ${_tmpfile}"
    _run ${EDITOR:-/usr/bin/vi} \""${_tmpfile}"\"
    local _jail_conf="$(cat ${_tmpfile})"
    _log_cmdline /sbin/zfs set zjail:conf=\""${_jail_conf}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    /sbin/zfs set zjail:conf="${_jail_conf}" "${ZJAIL_RUN_DATASET}/${_instance_id}" || _fatal "Cant set zjail:conf property"
    _check /bin/rm -f ${_tmpfile}
}

start_instance() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 <instance>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"
    _silent /usr/sbin/jls -j "${_instance_id}" jid && _fatal "INSTANCE [${_instance_id}] running"
    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail -vf - -c ${_instance_id}"
}

stop_instance() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 <instance>"
    fi

    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"
    _silent /usr/sbin/jls -j "${_instance_id}" jid || _fatal "INSTANCE [${_instance_id}] not running"
    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail -vf - -r ${_instance_id}"
}

destroy_instance() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 <instance>"
    fi

    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"
    # XXX Check for -f flag before shutting down
    _silent /usr/sbin/jls -j "${_instance_id}" jid && \
        _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail -vf - -r ${_instance_id}"
    _check /sbin/zfs destroy -r \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
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

