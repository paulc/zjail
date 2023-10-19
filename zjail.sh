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
    # Log command line if DEBUG set (optionally in colour)
    if [ -n "$DEBUG" ]
    then
        local _cmd="$@"
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "CMD: $_cmd" >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    fi
}

_log_message() {
    # Log command line if DEBUG set (optionally in colour)
    if [ -n "$DEBUG" ]
    then
        local _msg="$@"
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "INFO: $_msg" >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    fi
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

### firstboot_run rc.d script
_firstboot_run='
#!/bin/sh

# KEYWORD: firstboot
# PROVIDE: firstboot_run
# REQUIRE: NETWORKING
# BEFORE: LOGIN

. /etc/rc.subr

: ${firstboot_run:="NO"}
: ${firstboot_run_reboot:="NO"}

name="firstboot_run"
rcvar="firstboot_run_enable"
start_cmd="firstboot_run"

firstboot_run() {
    printf "Running firstboot_run scripts:\n"
    for x in $(ls /var/firstboot_run.d)
    do
        printf "    /var/firstboot_run.d/$x: %s\n" "$(/bin/sh "/var/firstboot_run.d/$x")"
    done

    if checkyesno firstboot_run_reboot; then
        printf "Requesting reboot."
        touch ${firstboot_sentinel}-reboot
    fi
}

load_rc_config $name
run_rc_command "$1"
'

_update_instance='
set -o errexit
set -o pipefail
set -o nounset
PAGER="/usr/bin/tail -n0" /usr/sbin/freebsd-update --currently-running $(/bin/freebsd-version) --not-running-from-cron fetch
if /usr/sbin/freebsd-update updatesready
then
    PAGER=/bin/cat /usr/sbin/freebsd-update install
fi
if ! /usr/sbin/pkg -N
then
    ASSUME_ALWAYS_YES=YES /usr/sbin/pkg bootstrap
fi
/usr/sbin/pkg update
/usr/sbin/pkg upgrade
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
    _check /sbin/zfs create -p \""${ZJAIL_DIST_DATASET}/${_release}"\"
    if [ "${ARCH}" = "amd64" ]
    then
        local _sets="base.txz lib32.txz"
    else
        local _sets="base.txz"
    fi
    for _f in $_sets
    do
        _check /usr/bin/fetch -o - \""${DIST_SRC}/${ARCH}/${_release}/${_f}"\" \| /usr/bin/tar -C \""${ZJAIL_DIST}/${_release}"\" -xf -
    done
    _check /sbin/zfs snapshot \""${ZJAIL_DIST_DATASET}/${_release}@release"\"
    _check /sbin/zfs set readonly=on \""${ZJAIL_DIST_DATASET}/${_release}"\"
}

### Manage bases

create_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: create_base <name> [os_release]"
    fi
    local _release="${2:-${OS_RELEASE}}"
    _silent /bin/test -d \""${ZJAIL_BASE}"\" || _fatal "ZJAIL_BASE [${ZJAIL_BASE}] not found"
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" && _fatal "BASE [${ZJAIL_BASE}/${_name}] exists"
    _silent /sbin/zfs list -o name -H \""${ZJAIL_DIST_DATASET}/${_release}@release"\" || _fatal "RELEASE [${_release}] not found"
    _check /sbin/zfs clone \""${ZJAIL_DIST_DATASET}/${_release}@release"\" \""${ZJAIL_BASE_DATASET}/${_name}"\"
    _check /sbin/zfs set zjail:release=\""${_release}"\" \""${ZJAIL_DIST_DATASET}/${_release}"\"
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@release"\"
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

get_default_ipv4() {
    ifconfig $(sh -c "route -n get default || route -n get 1.1.1.1" 2>/dev/null | awk '/interface:/ { print $2 }') inet | awk '/inet/ { print $2; exit }'
}

get_default_ipv6() {
    ifconfig $(sh -c "route -6n get default || route -6n get ::/1" 2>/dev/null | awk '/interface:/ { print $2 }') inet6 | awk '/inet6/ && ! /fe80::/ { print $2; exit }'
}

update_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: update_base <base>"
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

    # Get primary ipv4/ipv6 addresses - we check default route and 1.1.1.1 / ::/1 in case we have wireguard tunnel
    local _ipv4_default="$(get_default_ipv4)"
    local _ipv6_default="$(get_default_ipv6)"
    local _jail_ip=""
    if [ -n "${_ipv4_default}" ]
    then
        _jail_ip="ip4.addr=${_ipv4_default}"
    fi
    if [ -n "${_ipv6_default}" ]
    then
        _jail_ip="${_jail_ip} ip6.addr=${_ipv6_default}"
    fi
    if [ -z "${_jail_ip}" ]
    then
        _fatal "Cant find ipv4/ipv6 default addresses"
    fi

    # Copy local resolv.conf
    if [ -f "${ZJAIL_BASE}/${_name}/etc/resolv.conf" ]
    then
        _check /bin/cp \""${ZJAIL_BASE}/${_name}/etc/resolv.conf"\" \""${ZJAIL_BASE}/${_name}/etc/resolv.conf.orig"\"
    fi
    _check /bin/cp /etc/resolv.conf \""${ZJAIL_BASE}/${_name}/etc/resolv.conf"\"

    # Run freebsd-update in jail
    jexec_base "${_name}" ${_jail_ip} <<'EOM'
set -o errexit
set -o pipefail
set -o nounset
PAGER="/usr/bin/tail -n0" /usr/sbin/freebsd-update --currently-running $(/bin/freebsd-version) --not-running-from-cron fetch
if /usr/sbin/freebsd-update updatesready
then
    PAGER=/bin/cat /usr/sbin/freebsd-update install
fi
if ! /usr/sbin/pkg -N
then
    ASSUME_ALWAYS_YES=YES /usr/sbin/pkg bootstrap
fi
/usr/sbin/pkg update
/usr/sbin/pkg upgrade
if [ -f /etc/resolv.conf.orig ]
then
    mv /etc/resolv.conf.orig /etc/resolv.conf
fi
EOM

}

jexec_base() {
    # Create temporary jail and run /bin/sh
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: jail_base <base> [jail_params].."
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

    shift
    if [ "$#" -gt 0 ]
    then
        _run /usr/sbin/jail -c path=\""${ZJAIL_BASE}/${_name}"\" mount.devfs devfs_ruleset=4 exec.clean "$@" command /bin/sh
    else
        _run /usr/sbin/jail -c path=\""${ZJAIL_BASE}/${_name}"\" mount.devfs devfs_ruleset=4 exec.clean command /bin/sh
    fi

    # jail -c doesnt appear to unmount devfs for non-persistent jails on clean exit so umount manually
    _check /sbin/umount -f \""${ZJAIL_BASE}/${_name}/dev"\"

    # Create snapshot
    _check /sbin/zfs snapshot \""${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\"
}

chroot_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: chroot_base <base> [cmd].."
    fi
    _silent /bin/test -d \""${ZJAIL_BASE}/${_name}"\" || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

    shift
    if [ "$#" -gt 0 ]
    then
        _run /usr/sbin/chroot \""${ZJAIL_BASE}/${_name}"\" "$@"
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

install_firstboot_run() {
    local _root="${1:-}"
    if [ -z "${_root}" ]
    then
        _fatal "Usage: install_firstboot_run <root>"
    fi
    _silent /bin/test -d \""${_root}"\" || _fatal "Root path [${_root}] not found"

    # Initialise firstboot_run rc.d script (execs files in /var/firstboot_run.d)
    _check /bin/mkdir -p \""${_root}/var/firstboot_run.d"\"
    _check /bin/mkdir -p \""${_root}/usr/local/etc/rc.d"\"
    if ! /bin/echo "${_firstboot_run}" | _silent /usr/bin/tee -a \""${_root}/usr/local/etc/rc.d/firstboot_run"\"
    then
        _fatal "Cant write ${_root}/usr/local/etc/rc.d/firstboot_run"
    fi
    _check /bin/chmod 755 \""${_root}/usr/local/etc/rc.d/firstboot_run"\"
    _check /usr/bin/touch \""${_root}/firstboot"\"
    _check /usr/sbin/chroot \""${_root}"\" /usr/sbin/sysrc firstboot_run_enable=YES
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

# Generate random IPv6 Unique Local Address prefix
gen_ula() {
    # 48-bit ULA address - fdXX:XXXX:XXXX (add /16 subnet id and /64 device address)
    printf "fd%s:%s%s:%s%s\n" $(od -v -An -N5 -t x1 /dev/urandom)
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

# Increment counter from file
increment_counter() {
    local _file="${1:-}"
    if [ -z "${_file}" ]
    then
        _fatal "Usage: increment_counter <file>"
    fi

    /usr/bin/lockf -k -s -t 2 "${_file}.lock" /bin/sh -eu <<EOM
NEXT=\$(( \$(cat "${_file}" 2>/dev/null || echo 0) + 1 ))
echo \$NEXT | tee "${_file}"
EOM

}

create_instance() {
    local _usage="$0 create_instance <base|release>
    [-a]                                # Set sutostart flag
    [-c <site_config>]                  # Set jail.conf template
    [-C <host_path>:<instance_path>]..  # Copy files from host to instance
    [-f <cmd>]..                        # Install firstboot cmd
    [-F <file>]..                       # Install firstboot file
    [-h <hostname>]                     # Set hostname
    [-j <jail_param>]..                 # Set jail parameters
    [-p <pkg>]..                        # Install pkg
    [-r <cmd>]..                        # Run cmd (alias for -j 'exec.start = <cmd>')
    [-s <sysrc>]..                      # Set rc.local parameter (through sysrc)
    [-S <host_path>:<instance_path>]..  # Copy files filtering through envsubst(1)
    [-u '<user>:<pk>']..                # Add user/pk (note: pk needs to be quoted)
    [-U]                                # Update instance on firstboot
    [-w]                                # Add subsequent users to 'wheel' group
"
    case "${1:-}" in
        -h|-help|--help|help) _fatal "Usage: ${_usage}"
        ;;
    esac

    local _base="${1:-}"
    shift

    if [ -z "${_base}" ]
    then
        _fatal "Usage: ${_usage}"
    fi

    # Check base/release image exists and get latest snapshot
    local _latest=""
    if _silent /bin/test -d \""${ZJAIL_BASE}/${_base}"\"
    then
        # Base image
        _latest=$(get_latest_snapshot "${_base}")
        if [ -z "${_latest}" ]
        then
            _fatal "Cant find snapshot: ${ZJAIL_BASE}/${_base}"
        fi
    elif _silent /sbin/zfs list -H -o name \""${ZJAIL_DIST_DATASET}/${_base}@release"\"
    then
        # Release image
        _latest="${ZJAIL_DIST_DATASET}/${_base}@release"
    else
        _fatal "BASE/RELEASE image [${_base}] not found"
    fi

    # Check run mount point exists
    _silent /bin/test -d \""${ZJAIL_RUN}"\" || _fatal "ZJAIL_RUN [${ZJAIL_RUN}] not found"

    # Generate random 64-bit jail_id and IPv6 suffix
    local _instance_id="$(_run gen_id)"

    # Check for ID collisions
    while _silent /bin/test -d \""${ZJAIL_RUN}/${_instance_id}"\"
    do
        _instance_id="$(_run gen_id)"
    done

    if [ ${#_instance_id} -ne 13 ] # should be 13 chars
    then
        _err "Invalid _instance_id: ${_instance_id}"
    fi

    local _ipv4_lo="$(_run gen_lo)"
    local _ipv6_suffix="$(_run get_ipv6_suffix \""$_instance_id"\")"
    local _counter="$(_run increment_counter \""$ZJAIL_CONFIG/.counter"\")"

    # Clone base
    _check /sbin/zfs clone \""${_latest}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"

    # Clean up if we exit with error
    trap "_run /sbin/zfs destroy -r \"${ZJAIL_RUN_DATASET}/${_instance_id}\"" EXIT

    # Delay options processing until after we have created the image dataset so
    # that we can operate on this directly

    local _site=""
    local _jail_params=""
    local _hostname="${_instance_id}"
    local _autostart="off"
    local _firstboot_id=0
    local _run=0
    # Add users to wheel group
    local _wheel=""

    if [ -f "${ZJAIL_CONFIG}/site.conf" ]
    then
        _site="$(_run cat \""${ZJAIL_CONFIG}/site.conf"\")" || _fatal "Site template not found: ${OPTARG}"
    fi

    while getopts "ac:C:f:F:h:j:p:r:s:S:u:Uw" _opt; do
        case "${_opt}" in
            a)
                # Autostart
                _autostart="on"
                ;;
            c)
                # Set site config
                _site="$(_run cat \""${OPTARG}"\")" || _fatal "Site config not found: ${OPTARG}"
                ;;
            C)
                # Copy file from host
                local _host_path="${OPTARG%:*}"
                local _instance_path="${OPTARG#*:}"
                _check /bin/cp \""${_host_path}"\" \""${ZJAIL_RUN}/${_instance_id}/${_instance_path}"\"
                ;;
            f)
                # Install command as firstboot script
                if [ ! -d "${ZJAIL_RUN}/${_instance_id}/var/firstboot_run.d" ]
                then
                    # Install firstboot_run
                    install_firstboot_run "${ZJAIL_RUN}/${_instance_id}"
                fi
                local _firstboot_file="$(printf '%s/%s/var/firstboot_run.d/%04d-run' "${ZJAIL_RUN}" "${_instance_id}" "${_firstboot_id}")"
                _log_message "firstboot_file: ${_firstboot_file}"
                echo "${OPTARG}" | _check /usr/bin/tee \""${_firstboot_file}"\"
                _firstboot_id=$(($_firstboot_id + 1))
                ;;
            F)
                # Iinstall file as firstboot script
                if [ ! -d "${ZJAIL_RUN}/${_instance_id}/var/firstboot_run.d" ]
                then
                    # Install firstboot_run
                    _log_message "Installing firstboot_run"
                    install_firstboot_run "${ZJAIL_RUN}/${_instance_id}"
                fi
                local _firstboot_file="$(printf '%s/%s/var/firstboot_run.d/%04d-run' "${ZJAIL_RUN}" "${_instance_id}" "${_firstboot_id}")"
                _log_message "firstboot_file: ${_firstboot_file}"
                if [ "${OPTARG}" = "-" ]
                then
                    # Install from stdin
                    _check /usr/bin/tee \""${_firstboot_file}"\"
                else
                    # Install from file
                    if [ ! -f "${OPTARG}" ]
                    then
                        _fatal "Run file [${OPTARG}] not found"
                    fi
                    cat "${OPTARG}" | _check /usr/bin/tee \""${_firstboot_file}"\"
                fi
                _firstboot_id=$(($_firstboot_id + 1))
                ;;
            h)
                # Set hostname
                _hostname="${OPTARG}"
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

                # Bootstrap pkg if needed
                _log /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg -N
                if [ $? -ne 0 ]
                then
                    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg bootstrap
                fi

                _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/pkg install \""${OPTARG}"\"

                _check /sbin/umount \""${ZJAIL_RUN}/${_instance_id}/dev"\"
                ;;
            r)
                # Run command instead of /etc/rc (shortcut for -j 'exec.start=...')
                if [ "${_run}" -eq 0 ]
                then
                    # Clear any existing exec.start items
                    _jail_params="$(printf '%s\n%s;' "${_jail_params}" "exec.start = \"${OPTARG}\"")"
                    _run=1
                else
                    _jail_params="$(printf '%s\n%s;' "${_jail_params}" "exec.start += \"${OPTARG}\"")"
                fi
                ;;
            s)
                # Run sysrc
                _check /usr/sbin/chroot \""${ZJAIL_RUN}/${_instance_id}"\" /usr/sbin/sysrc \""${OPTARG}"\"
                ;;
            S)
                # Copy file from host filtering througfh envsubst(1)
                if [ ! -x /usr/local/bin/envsubst ]
                then
                    _fatal "/usr/local/bin/envsubst not found (install gettext pkg)"
                fi
                local _host_path="${OPTARG%%:*}"
                local _instance_path="${OPTARG#*:}"
                _check ID=\""${_instance_id}"\" HOSTNAME=\""${_hostname}"\" SUFFIX=\""${_ipv6_suffix}"\" \
                    envsubst \< \""${_host_path}"\" \> \""${ZJAIL_RUN}/${_instance_id}/${_instance_path}"\"
                ;;
            u)
                # Add user (name:pk)
                local _name="${OPTARG%%:*}"
                local _pk="${OPTARG#*:}"
                local _uid=0
                local _home="/root"
                # Check if user exists
                if ! _silent /usr/sbin/pw -R \""${ZJAIL_RUN}/${_instance_id}"\" usershow -n \""${_name}"\"
                then
                    # Create user
                    _check /usr/sbin/pw -R \""${ZJAIL_RUN}/${_instance_id}"\" useradd -n \""${_name}"\" -m -s /bin/sh -h - ${_wheel}
                fi
                _uid=$(_run /usr/sbin/pw -R \""${ZJAIL_RUN}/${_instance_id}"\" usershow -n \""${_name}"\" \| awk -F: "'{ print \$3 }'")
                _home=$(_run /usr/sbin/pw -R \""${ZJAIL_RUN}/${_instance_id}"\" usershow -n \""${_name}"\" \| awk -F: "'{ print \$9 }'")
                _check /bin/mkdir -p -m 700 \"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh\"
                _check /usr/bin/printf "'%s\n'" \""${_pk}"\" \>\> \"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh/authorized_keys\"
                # We assume uid == gid
                _check /usr/sbin/chown -R \""${_uid}:${_uid}"\" \"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh\"
                _check /bin/chmod 600 \"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh/authorized_keys\"
                ;;
            U)  # Update instance on firstboot
                if [ ! -d "${ZJAIL_RUN}/${_instance_id}/var/firstboot_run.d" ]
                then
                    # Install firstboot_run
                    install_firstboot_run "${ZJAIL_RUN}/${_instance_id}"
                fi
                local _run_file="$(printf '%s/%s/var/firstboot_run.d/%04d-update' "${ZJAIL_RUN}" "${_instance_id}" "${_run_id}")"
                echo "${_update_instance}" | _check /usr/bin/tee -a \""${_run_file}"\"
                _run_id=$((_run_id + 1))
                ;;
            w)
                # Add subsequent users to the wheel group
                _wheel="-G wheel"
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
    _check /sbin/zfs set zjail:loopback=\""${_ipv4_lo}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:autostart=\""${_autostart}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
    _check /sbin/zfs set zjail:counter=\""${_counter}"\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"

    local _jail_conf="\
${_site}

${_instance_id} {
    \$id = ${_instance_id};
    \$hostname = \""${_hostname}"\";
    \$suffix = ${_ipv6_suffix};
    \$ipv4_lo = ${_ipv4_lo};
    \$counter = ${_counter};
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

    local _jail_verbose=""
    if [ -n "$DEBUG" ]
    then
        _jail_verbose="-v"
    fi

    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail ${_jail_verbose} -f - -c ${_instance_id} >&2"

    trap - EXIT
    printf '%s\n' $_instance_id
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
        _fatal "Usage: $0 edit_jail_conf <instance>"
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
        _fatal "Usage: $0 start_instance <instance>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"
    _silent /usr/sbin/jls -j "${_instance_id}" jid && _fatal "INSTANCE [${_instance_id}] running"

    local _jail_verbose=""
    if [ -n "${DEBUG}" ]
    then
        _jail_verbose="-v"
    fi

    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail ${_jail_verbose} -f - -c ${_instance_id} >&2"
}

stop_instance() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 stop_instance <instance>"
    fi

    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"
    _silent /usr/sbin/jls -j "${_instance_id}" jid || _fatal "INSTANCE [${_instance_id}] not running"

    local _jail_verbose=""
    if [ -n "${DEBUG}" ]
    then
        _jail_verbose="-v"
    fi

    _check "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail ${_jail_verbose} -f - -r ${_instance_id} >&2"

    # Cleanup any mounts
    cleanup_mounts "${_instance_id}"
}

destroy_instance() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 destroy_instance <instance>"
    fi

    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"

    local _jail_verbose=""
    if [ -n "${DEBUG}" ]
    then
        _jail_verbose="-v"
    fi

    # XXX Check for -f flag before shutting down
    _silent /usr/sbin/jls -j "${_instance_id}" jid && \
        _log "/sbin/zfs get -H -o value zjail:conf \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" | jail ${_jail_verbose} -f - -r ${_instance_id} >&2"

    # Cleanup any mounts
    cleanup_mounts "${_instance_id}"

    # Wait for jail to stop
    while _run jls -dj "${_instance_id}" \>/dev/null 2\>\&1
    do
        sleep 0.5
    done
    _check /sbin/zfs destroy -r \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
}

set_autostart() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 set_autostart <instance>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"

    # Set autostart flag
    _check /sbin/zfs set zjail:autostart=\"on\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
}

clear_autostart() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 clear_autostart <instance>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \""${ZJAIL_RUN_DATASET}/${_instance_id}"\" || _fatal "INSTANCE [${_instance_id}] not found"

    # Set autostart flag
    _check /sbin/zfs set zjail:autostart=\"off\" \""${ZJAIL_RUN_DATASET}/${_instance_id}"\"
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

cleanup_mounts() {
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 cleanup_mounts <instance>"
    fi

    # Need to deal with possible spaces in mount point so we use libxo XML output
    _run "/sbin/mount -t nozfs --libxo xml,pretty | awk -F '<|>' -v id=${_instance_id} '\$3 ~ id { system(sprintf(\"/sbin/umount -f \\\"%s\\\"\",\$3)) }'"
}

cmd="${1}"
shift
${cmd} "$@"
