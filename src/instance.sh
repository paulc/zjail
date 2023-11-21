#!/bin/sh

### Instances

list_instances() { #
    /sbin/zfs list -H -r -o zjail:id "${ZJAIL_RUN_DATASET}" | sed -e '/^-/d'
}

list_instance_details() { # [instance_id]
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _run /sbin/zfs list -H -r -s creation -o zjail:id,zjail:hostname,zjail:counter,zjail:suffix,zjail:base,zjail:autostart \'"${ZJAIL_RUN_DATASET}"\' \
            | sed -e '/^-/d' | \
            (
                IFS="	"
                local _id _hostname _counter _suffix _base _autostart
                local _header="1"
                while read -r _id _hostname _counter _suffix _base _autostart
                do
                    if [ -n "${_header}" ]
                    then
                        /usr/bin/printf '%-14s %-16s %-7s %-19s %-30s %-9s %s\n' ID HOSTNAME COUNTER SUFFIX BASE AUTOSTART STATUS
                        _header=""
                    fi

                    local _jid
                    if _jid=$(jls -j "${_id}" jid 2>/dev/null)
                    then
                        local _status="RUNNING [${_jid}]"
                    else
                        local _status="NOT RUNNING"
                    fi
                    /usr/bin/printf '%-14s %-16s %-7d %-19s %-30s %-9s %s\n' "${_id}" "${_hostname}" "${_counter}" "${_suffix}" "${_base##*/}" "${_autostart}" "${_status}"
                done
            )
    else
        # Check we have a valid instance
        _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"
        local _id _hostname _counter _suffix _loopback _base _autostart
        _run /sbin/zfs list -H -o zjail:id,zjail:hostname,zjail:counter,zjail:suffix,zjail:loopback,zjail:base,zjail:autostart \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' \
            | sed -e '/^-/d' | \
            (
                IFS="	"
                local _id _hostname _counter _suffix _loopback _base _autostart
                read -r _id _hostname _counter _suffix _loopback _base _autostart
                local _jid
                if _jid=$(jls -j "${_id}" jid 2>/dev/null)
                then
                    local _status="RUNNING [${_jid}]"
                else
                    local _status="NOT RUNNING"
                fi
                /usr/bin/printf '%-12s\t%s\n' ID "${_id}"
                /usr/bin/printf '%-12s\t%s\n' STATUS "${_status}"
                /usr/bin/printf '%-12s\t%s\n' HOSTNAME "${_hostname}"
                /usr/bin/printf '%-12s\t%s\n' COUNTER "${_counter}"
                /usr/bin/printf '%-12s\t%s\n' SUFFIX "${_suffix}"
                /usr/bin/printf '%-12s\t%s\n' LOOPBACK "${_loopback}"
                /usr/bin/printf '%-12s\t%s\n' BASE "${_base}"
                /usr/bin/printf '%-12s\t%s\n' AUTOSTART "${_autostart}"
                /usr/bin/printf 'JAIL.CONF\n' 
                /sbin/zfs get -H -o value zjail:conf "${ZJAIL_RUN_DATASET}/${_instance_id}" | sed -e 's/^/    /'
            )
    fi
}

edit_jail_conf() { # <instance_id>
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 edit_jail_conf <instance_id>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"
    local _tmpfile
    _tmpfile=$(_run /usr/bin/mktemp) || _fatal "Cant create TMPFILE"

    # shellcheck disable=SC2064
    trap "/bin/rm -f ${_tmpfile}" EXIT

    _check /sbin/zfs get -H -o value zjail:conf \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' \> "${_tmpfile}"
    _run "${EDITOR:-/usr/bin/vi}" \'"${_tmpfile}"\'
    local _jail_conf
    _jail_conf="$(cat "${_tmpfile}")"
    _log_cmdline /sbin/zfs set zjail:conf=\'"${_jail_conf}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    /sbin/zfs set zjail:conf="${_jail_conf}" "${ZJAIL_RUN_DATASET}/${_instance_id}" || _fatal "Cant set zjail:conf property"
    _check /bin/rm -f "${_tmpfile}"
}

start_instance() { # <instance_id>
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 start_instance <instance_id>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"
    if _silent /usr/sbin/jls -j "${_instance_id}" jid
    then
        echo "INSTANCE [${_instance_id}] running" >&2
        return
    fi

    local _jail_verbose=""
    if [ -n "${DEBUG}" ]
    then
        _jail_verbose="-v"
    fi

    _check /sbin/zfs get -H -o value zjail:conf \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' \| jail ${_jail_verbose} -f - -c "${_instance_id}" >&2
}

stop_instance() { # <instance_id>
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 stop_instance <instance_id>"
    fi

    _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"
    if ! _silent /usr/sbin/jls -j "${_instance_id}" jid 
    then
        echo "INSTANCE [${_instance_id}] not running" >&2
        return
    fi

    local _jail_verbose=""
    if [ -n "${DEBUG}" ]
    then
        _jail_verbose="-v"
    fi

    _check /sbin/zfs get -H -o value zjail:conf \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' \| jail ${_jail_verbose} -f - -r "${_instance_id}" >&2

    # Cleanup any mounts
    cleanup_mounts "${_instance_id}"
}

destroy_instance() { # <instance_id>
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 destroy_instance <instance_id>"
    fi

    _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"

    local _jail_verbose=""
    if [ -n "${DEBUG}" ]
    then
        _jail_verbose="-v"
    fi

    # XXX Check for flag before shutting down??
    _silent /usr/sbin/jls -j "${_instance_id}" jid && \
        _log /sbin/zfs get -H -o value zjail:conf \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' \| jail ${_jail_verbose} -f - -r "${_instance_id}" >&2

    # Cleanup any mounts
    cleanup_mounts "${_instance_id}"

    # Wait upto 30s for jail to stop
    local _counter=0
    while _run jls -dj "${_instance_id}" \>/dev/null 2\>\&1
    do
        sleep 0.5
        _counter=$((_counter + 1))
        if [ "${_counter}" -gt 60 ]
        then
            _fatal "Jail still running [${_instance_id}]"
        fi
    done
    _check /sbin/zfs destroy -Rf \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
}

set_hostname() { # <instance_id> <hostname>
    local _instance_id="${1:-}"
    local _hostname="${2:-}"
    if [ -z "${_instance_id}" ] || [ -z "${_hostname}" ]
    then
        _fatal "Usage: $0 set_hostname <instance_id> <hostname>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"
    
    # Modify jail.conf
    local _jail_conf
    _jail_conf="$(/sbin/zfs get -H -o value zjail:conf "${ZJAIL_RUN_DATASET}/${_instance_id}" | sed -e "s/\(^[[:space:]]*\$hostname\).*/\1 = \"${_hostname}\";/")"
    _check /sbin/zfs set zjail:conf=\'"${_jail_conf}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    
    # Update zfs property
    _check /sbin/zfs set zjail:hostname=\'"${_hostname}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'

    # If the jail is running reset host.hostname
    if _silent /usr/sbin/jls -j "${_instance_id}" jid
    then
        _check /usr/sbin/jail -m \'"name=${_instance_id}"\' \'"host.hostname=\"${_hostname}\""\'
    fi
}

set_autostart() { # <instance_id>
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 set_autostart <instance_id>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"

    # Set autostart flag
    _check /sbin/zfs set zjail:autostart=\'on\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
}

clear_autostart() { # <instance_id>
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 clear_autostart <instance_id>"
    fi

    # Check we have a valid instance
    _silent /sbin/zfs get -H -o value zjail:id \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' || _fatal "INSTANCE [${_instance_id}] not found"

    # Set autostart flag
    _check /sbin/zfs set zjail:autostart=\'off\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
}

autostart() { #
    for _instance_id in $(_run /sbin/zfs list -r -H -o zjail:autostart,name \'"${ZJAIL_RUN_DATASET}"\' | sed -ne 's/^on.*\///p')
    do
        if _silent /usr/sbin/jls -j "${_instance_id}" jid
        then
            echo "INSTANCE [${_instance_id}] running"
        else
            _check /sbin/zfs get -H -o value zjail:conf \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' \| jail -f - -c "${_instance_id}" >&2
        fi
    done
}

cleanup_mounts() { # <instance_id>
    local _instance_id="${1:-}"
    if [ -z "${_instance_id}" ]
    then
        _fatal "Usage: $0 cleanup_mounts <instance_id>"
    fi

    # Need to deal with possible spaces in mount point so we use libxo XML output
    _run /sbin/mount -t nozfs --libxo xml,pretty | awk -F '<|>' -v id="${_instance_id}" '$3 ~ id { system(sprintf("/sbin/umount -f \"%s\"",$3)) }'
}

