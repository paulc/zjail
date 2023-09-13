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
    printf '%sFATAL: %s%s\n' "${COLOUR:+${_RED}}" "$@" "${COLOUR:+${_NORMAL}}" >&2
    exit 1
}

_exitf() {
    printf '%s' "${COLOUR:+${_NORMAL}}" >&2
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

### firstboot_zjail rc.d script
_firstboot_zjail='
#!/bin/sh

# KEYWORD: firstboot
# PROVIDE: firstboot_zjail
# REQUIRE: NETWORKING
# BEFORE: LOGIN

. /etc/rc.subr

: ${firstboot_zjail_enable:="NO"}

name="firstboot_zjail"
rcvar="firstboot_zjail_enable"
start_cmd="firstboot_zjail_run"

firstboot_zjail_run() {
    printf "Running firstboot_zjail scripts:\n"
    for x in $(ls /var/firstboot_zjail)
    do
        printf "/var/firstboot_zjail/$x:"
        /bin/sh "/var/firstboot_zjail/$x"
        printf "\n"
    done
}

load_rc_config $name
run_rc_command "$1"
'

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
    _check /sbin/mount -t devfs -o ruleset=1 devfs \""${ZJAIL_BASE}/${_name}/dev"\"
    _check /sbin/devfs -m \""${ZJAIL_BASE}/${_name}/dev"\" rule -s 2 applyset

    _log /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg -N
    if [ $? -ne 0 ]
    then
        _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg bootstrap
    fi
    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg update
    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/pkg upgrade

    # Unmount devfs
    _check /sbin/umount \""${ZJAIL_BASE}/${_name}/dev"\"

    # Create snapshot
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

install_firstboot() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: install_firstboot <base>"
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    
    # Initialise firstboot_zjail rc.d script (execs files in /var/firstboot_zjail)
    _check /bin/mkdir -p \""${ZJAIL_BASE}/${_name}/var/firstboot_zjail"\"
    _check /bin/mkdir -p \""${ZJAIL_BASE}/${_name}/usr/local/etc/rc.d"\"
    if ! /bin/echo "${_firstboot_zjail}" | _silent /usr/bin/tee -a \""${ZJAIL_BASE}/${_name}/usr/local/etc/rc.d/firstboot_zjail"\"
    then
        _fatal "Cant write ${ZJAIL_BASE}/${_name}/usr/local/etc/rc.d/firstboot_zjail"
    fi
    _check /bin/chmod 755 \""${ZJAIL_BASE}/${_name}/usr/local/etc/rc.d/firstboot_zjail"\"
    _check /usr/bin/touch \""${ZJAIL_BASE}/${_name}/firstboot"\"
    _check /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" /usr/sbin/sysrc firstboot_zjail_enable=YES

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

    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
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
    local _id="0000000000000"
    # Ensure id is not all-numeric (invalid jail name) 
    while expr "${_id}" : '^[0-9]*$' >/dev/null
    do
        # Get 2 x 32 bit unsigned ints from /dev/urandom
        # (od doesnt accept -t u8 so we multiply in bc)
        set -- $(od -v -An -N8 -t u4 /dev/urandom)
        # Reserve ::0 to ::ffff for system
        while [ ${1:-0} -eq 0 -a ${2:-0} -lt 65536 ]
        do
            set -- $(od -v -An -N8 -t u4 /dev/urandom)
        done
        # Use bc to generate pseudo-base32 encoded string from 64bit uint
        # (Note this isnt a normal base32 and just uses fixed 13 chars (13*5 = 65))
        _id="$(bc -l -e "x = $1 * $2" \
              -e 'for (i=0;i<13;i++) { mod = band(x,31); x = bshr(x,5); if (mod < 10) { c[12-i] = mod + 48 } else { c[12-i] = mod + 65 - 10 } }' \
              -e 'print asciify(c[]),"\n"')"
    done
    printf '%s\n' "${_id}"
}

# Generate random loopback address (note this only has 24 bits of entropy
# though in practice this isnt a major problem as we only use to separate
# loopback devices)
gen_lo() {
    /usr/bin/printf '127.%d.%d.%d\n' $(/usr/bin/od -v -An -N3 -t u1 /dev/urandom)
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
    local _usage="$0 create_instance
    [-a]                                # Set sutostart flag
    [-f]                                # Initialise firstboot rc.d script
    [-h <hostname>]                     # Set hostname
    [-s <site_template>]                # Set site jail.conf template
    [-j <jail_param>]..                 # Set jail parameters
    [-c <host_path>:<instance_path>]..  # Copy files from host to instance
    [-e <host_path>:<instance_path>]..  # Copy files filtering through envsubst(1)
    [-p <pkg>]..                        # Install pkg
    [-r <sysrc>]..                      # Set rc.local parameter (through sysrc)
    [-u <user> <pk>]..                  # Add user/ssh pk
"

    if [ -z "${_base}" ]
    then
        _fatal "Usage: ${_usage}"
    fi
    
    if [ "${_base}" = "-h" -o "${_base}" = "--help" -o "${_base}" = "-help" ]
    then
        echo "${_usage}"
        exit 1
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
    if [ ${#_instance_id} -ne 13 ] # should be 13 chars
    then
        _err "Invalid _instance_id: ${_instance_id}"
    fi

    local _ipv4_lo="$(_run gen_lo)"
    local _ipv6_suffix="$(_run get_ipv6_suffix \""$_instance_id"\")"

    # Clone base
    _check /sbin/zfs clone \""${_latest}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"

    # Delay options processing until after we have created the image dataset so
    # that we can operate on this directly
    
    local _site=""
    local _jail_params=""
    local _hostname="${_instance_id}"
    local _autostart="off"

    if [ -f "${ZJAIL_CONFIG}/site.conf" ]
    then
        _site="$(_run cat \""${ZJAIL_CONFIG}/site.conf"\")" || _fatal "Site template not found: ${OPTARG}"
    fi

    while getopts "ac:e:fh:s:t:j:p:r:" _opt; do
        case "${_opt}" in
            a)
                # Autostart
                _autostart="on"
                ;;
            c)
                # Copy file from host
                local _host_path="${OPTARG%:*}"
                local _instance_path="${OPTARG#*:}"
                _check /bin/cp \""${_host_path}"\" \""${ZJAIL_RUN}/${_instance_id}/${_instance_path}"\"
                ;;
            e)
                # Copy file from host filtering througfh envsubst(1)
                if [ ! -x /usr/local/bin/envsubst ] 
                then
                    _fatal "/usr/local/bin/envsubst not found (install gettext pkg)"
                fi
                local _host_path="${OPTARG%:*}"
                local _instance_path="${OPTARG#*:}"
                _check ID=\""${_instance_id}"\" HOSTNAME=\""${_hostname}"\" SUFFIX=\""${_ipv6_suffix}"\" \
                    envsubst \< \""${_host_path}"\" \> \""${ZJAIL_RUN}/${_instance_id}/${_instance_path}"\"
                ;;
            f)
                # Initialise firstboot_zjail rc.d script (execs files in /var/firstboot_zjail)
                _check /bin/mkdir -p \""${ZJAIL_RUN}/${_instance_id}/var/firstboot_zjail"\"
                _check /bin/mkdir -p \""${ZJAIL_RUN}/${_instance_id}/usr/local/etc/rc.d"\"
                if ! /bin/echo "${_firstboot_zjail}" | _silent /usr/bin/tee -a \""${ZJAIL_RUN}/${_instance_id}/usr/local/etc/rc.d/firstboot_zjail"\"
                then
                    _fatal "Cant write ${ZJAIL_RUN}/${_instance_id}/usr/local/etc/rc.d/firstboot_zjail"
                fi
                _check /bin/chmod 755 \""${ZJAIL_RUN}/${_instance_id}/usr/local/etc/rc.d/firstboot_zjail"\"
                _check /usr/bin/touch \""${ZJAIL_RUN}/${_instance_id}/firstboot"\"
                _check /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/sysrc firstboot_zjail_enable=YES
                ;;
            h)
                # Set hostname
                _hostname="${OPTARG}"
                ;;
            s)
                # Set site template
                _site="$(_run cat \""${OPTARG}"\")" || _fatal "Site template not found: ${OPTARG}"
                ;;
            j)
                # Add jail param
                _jail_params="$(printf '%s\n%s;' "${_jail_params}" "${OPTARG}")"
                ;;
            p)
                # Install pkg

                # Make sure /dev/null is available in chroot
                _check /sbin/mount -t devfs -o ruleset=1 devfs \""${ZJAIL_RUN}/${_instance_id}/dev"\"
                _check /sbin/devfs -m \""${ZJAIL_RUN}/${_instance_id}/dev"\" rule -s 2 applyset

                # Check for resolv.conf in jail (copy host file is missing)
                if [ ! -f "${ZJAIL_RUN}/${_instance_id}/etc/resolv.conf" ]
                then
                    _check /bin/cp /etc/resolv.conf \""${ZJAIL_RUN}/${_instance_id}/etc/resolv.conf"\"
                fi

                # Bootstrap pkg
                _log /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg -N
                if [ $? -ne 0 ]
                then
                    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg bootstrap
                fi

                _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg install \""${OPTARG}"\"

                _check /sbin/umount \""${ZJAIL_RUN}/${_instance_id}/dev"\"
                ;;
            r)
                # Run sysrc
                _check /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/sysrc \""${OPTARG}"\"
                ;;
            h)
                _fatal "Usage: ${_usage}"
                ;;
            \?)
                _fatal "Usage: ${_usage}"
                ;;
            :)
                _fatal "Usage: ${_usage}"
                ;;
        esac
    done

    _check /sbin/zfs set zjail:id=\""${_instance_id}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:hostname=\""${_hostname}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:base=\""${_latest}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:suffix=\""${_ipv6_suffix}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:autostart=\""${_autostart}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"

    local _jail_conf="\
${_site}

${_instance_id} {
    \$id = ${_instance_id};
    \$hostname = \""${_hostname}"\";
    \$suffix = ${_ipv6_suffix};
    \$ipv4_lo = ${_ipv4_lo};
    \$root = \""${ZJAIL_RUN}/${_instance_id}"\";
    path = \""${ZJAIL_RUN}/${_instance_id}"\";
    host.hostname = \""${_hostname}"\";
    ${_jail_params}
}
"
    # Dont use _check to avoid double quoting problems
    _log_cmdline /sbin/zfs set zjail:conf=\""${_jail_conf}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    /sbin/zfs set zjail:conf="${_jail_conf}" "${ZJAIL_RUN_DATASET}/${_instance_id}" || _fatal "Cant set zjail:conf property"

    _check /sbin/zfs snapshot \""${ZJAIL_RUN_DATASET}/${_instance_id}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail -vf - -c ${_instance_id}"

    printf 'ID: %s\nSuffix: %s\n' $_instance_id $_ipv6_suffix
}

list_instances() {
    /sbin/zfs list -H -r -o zjail:id "${ZJAIL_RUN_DATASET}" | sed -e '/^-/d'
}

list_instance_details() {
    local _id _hostname _suffix _base _autostart

    local _header="1"

    _run "/sbin/zfs list -H -r -o zjail:id,zjail:hostname,zjail:suffix,zjail:base,zjail:autostart \""${ZJAIL_RUN_DATASET}"\" | sed -e '/^-/d'" | \
        while read _id _hostname _suffix _base _autostart 
        do
            if [ -n "${_header}" ]
            then
                printf '%-14s %-16s %-19s %-36s %-9s %s\n' ID HOSTNAME SUFFIX BASE AUTOSTART STATUS
                _header=""
            fi

            local _jid=$(jls -j "${_id}" jid 2>/dev/null)
            if [ -n "${_jid}" ]
            then 
                local _status="RUNNING [${_jid}]"
            else 
                local _status="NOT RUNNING"
            fi
            printf '%-14s %-16s %-19s %-36s %-9s %s\n' "${_id}" "${_hostname}" "${_suffix}" "${_base##*/}" "${_autostart}" "${_status}"
        done 
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
    # Wait for jail to stop
    while _run jls -dj "${_instance_id}" \>/dev/null 2\>\&1
    do
        sleep 0.5
    done
    _check /sbin/zfs destroy -r \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
}

autostart() {
    for _instance_id in $(_run /sbin/zfs list -r -H -o zjail:autostart,name \""${ZJAIL_RUN_DATASET}"\" | sed -ne 's/^on.*\///p')
    do
        if _silent /usr/sbin/jls -j "${_instance_id}" jid 
        then
            echo "INSTANCE [${_instance_id}] running"
        else
            _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail -vf - -c ${_instance_id}"
        fi
    done
}

cmd="${1}"
shift
${cmd} "$@"
