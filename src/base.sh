
### Manage bases

create_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: create_base <name> [os_release]"
    fi
    local _release="${2:-${OS_RELEASE}}"
    _silent /bin/test -d \'"${ZJAIL_BASE}"\' || _fatal "ZJAIL_BASE [${ZJAIL_BASE}] not found"
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_name}"\' && _fatal "BASE [${ZJAIL_BASE}/${_name}] exists"
    _silent /sbin/zfs list -o name -H \'"${ZJAIL_DIST_DATASET}/${_release}@release"\' || _fatal "RELEASE [${_release}] not found"
    _check /sbin/zfs clone \'"${ZJAIL_DIST_DATASET}/${_release}@release"\' \'"${ZJAIL_BASE_DATASET}/${_name}"\'
    _check /sbin/zfs set zjail:release=\'"${_release}"\' \'"${ZJAIL_DIST_DATASET}/${_release}"\'
    _check /sbin/zfs snapshot \'"${ZJAIL_BASE_DATASET}/${_name}@release"\'
    _check /sbin/zfs snapshot \'"${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\'
}

update_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: update_base <base>"
    fi
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_name}"\' || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

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
        _check /bin/cp \'"${ZJAIL_BASE}/${_name}/etc/resolv.conf"\' \'"${ZJAIL_BASE}/${_name}/etc/resolv.conf.orig"\'
    fi
    _check /bin/cp /etc/resolv.conf \'"${ZJAIL_BASE}/${_name}/etc/resolv.conf"\'

    # Run freebsd-update in jail
    echo "${_update_instance}" | jexec_base "${_name}" ${_jail_ip} | _log_output
}

jexec_base() {
    # Create temporary jail and run /bin/sh
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: jail_base <base> [jail_params].."
    fi
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_name}"\' || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

    shift
    if [ "$#" -gt 0 ]
    then
        _run /usr/sbin/jail -c path=\'"${ZJAIL_BASE}/${_name}"\' mount.devfs devfs_ruleset=4 exec.clean "$@" command /bin/sh
    else
        _run /usr/sbin/jail -c path=\'"${ZJAIL_BASE}/${_name}"\' mount.devfs devfs_ruleset=4 exec.clean command /bin/sh
    fi

    # jail -c doesnt appear to unmount devfs for non-persistent jails on clean exit so umount manually
    if [ -r "${ZJAIL_BASE}/${_name}/dev/null" ]
    then
        _check /sbin/umount -f \'"${ZJAIL_BASE}/${_name}/dev"\'
    fi

    # Create snapshot
	snapshot_base "${_name}"
}

chroot_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: chroot_base <base> [cmd].."
    fi
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_name}"\' || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"

    shift
    if [ "$#" -gt 0 ]
    then
        _run /usr/sbin/chroot \'"${ZJAIL_BASE}/${_name}"\' "$@"
    else
        _run /usr/sbin/chroot \'"${ZJAIL_BASE}/${_name}"\' /bin/sh
    fi

	snapshot_base "${_name}"
}

clone_base() {
    local _name="${1:-}"
    local _target="${2:-}"
    if [ -z "${_name}" -o -z "${_target}" ]
    then
        _fatal "Usage: clone_base <base> <target>"
    fi
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_name}"\' || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_target}"\' && _fatal "TARGET [${ZJAIL_BASE}/${_target}] exists"

    local _latest=$(get_latest_snapshot "${_name}")
    if [ -z "${_latest}" ]
    then
        _fatal "Cant find snapshot: ${ZJAIL_BASE}/${_name}"
    fi

    _check /sbin/zfs clone \'"${_latest}"\' \'"${ZJAIL_BASE_DATASET}/${_target}"\'
	snapshot_base "${_target}"
}

snapshot_base() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: snapshot_base <base>"
    fi
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_name}"\' || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
	# Check we dont have two snapshots with the same timestamp
	if _silent /sbin/zfs list -H -o name -t snap \'"${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\'
	then
		sleep 1
	fi
    _check /sbin/zfs snapshot \'"${ZJAIL_BASE_DATASET}/${_name}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\'
}

get_latest_snapshot() {
    local _name="${1:-}"
    if [ -z "${_name}" ]
    then
        _fatal "Usage: get_latest_snapshot <base>"
    fi
    _silent /bin/test -d \'"${ZJAIL_BASE}/${_name}"\' || _fatal "BASE [${ZJAIL_BASE}/${_name}] not found"
    _run /sbin/zfs list -H -t snap -s creation -o name \'"${ZJAIL_BASE_DATASET}/${_name}"\' \| tail -1
}

