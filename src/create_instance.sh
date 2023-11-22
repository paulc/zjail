#!/bin/sh

### 
### The create_instance and build methods use (almost) the same code so we 
### use the START_/END_ markers to automatically generate build.sh
###

### START_CREATE

create_instance() { # <base|release> [options]

    local _usage="$0 create_instance <base|release>
    [-a]                                # Set sutostart flag
    [-C <host_path>:<instance_path>]..  # Copy files from host to instance
    [-f <cmd>]..                        # Install firstboot cmd
    [-F <file>]..                       # Install firstboot file
    [-h <hostname>]                     # Set hostname
    [-j <jail_param>]..                 # Set jail parameters
    [-J <jail_conf>]                    # Set jail.conf template
    [-n]                                # Create but dont start instance
    [-p <pkg>]..                        # Install pkg
    [-r <cmd>]..                        # Run cmd (alias for -j 'exec.start = <cmd>')
    [-s <sysrc>]..                      # Set rc.local parameter (through sysrc)
    [-S <host_path>:<instance_path>]..  # Copy files filtering through envsubst(1)
    [-u '<user>:<pk>']..                # Add user/pk (note: pk needs to be quoted)
    [-U]                                # Update instance on firstboot
    [-v <volume>                        # Attach volume $ZJAIL/volumes/<volume>
    [-V <volume:size>                   # Attach volume $ZJAIL/volumes/<volume> (create if necessary)
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

### END_CREATE

### START_BUILD
#
#build() { # <build-file>
#    local _usage="$0 build <build-file>"
#    local _build_file="${1:-}"
#
#    if [ -z "${_build_file}" ]
#    then
#        _fatal "Usage: ${_usage}"
#    fi
#
#    if [ "${_build_file}" = "-" ]
#    then
#        # Use STDIN
#        _build_file="/dev/stdin"
#    elif [ ! -r "${_build_file}" ]
#    then
#        _fatal "ERROR: Build file not readable [${_build_file}]"
#    fi
#
#    # Strip comments and blank lines
#    sed -e '/^#/d' -e '/^[[:space:]]*$/d' "${_build_file}" | (
#
#    # Expect BASE as first line
#    read -r _option _base
#    if [ "${_option}" != "BASE" ]
#    then
#        _fatal "Expected BASE on first line"
#    fi
#
#    if [ -z "${_base}" ]
#    then
#        _fatal "Usage: ${_usage}"
#    fi
#
### END_BUILD

    # Check base/release image exists and get latest snapshot
    local _latest=""
    if _silent /bin/test -d \'"${ZJAIL_BASE}/${_base}"\'
    then
        # Base image
        _latest=$(get_latest_snapshot "${_base}")
        if [ -z "${_latest}" ]
        then
            _fatal "Cant find snapshot: ${ZJAIL_BASE}/${_base}"
        fi
    elif _silent /sbin/zfs list -H -o name \'"${ZJAIL_DIST_DATASET}/${_base}@release"\'
    then
        # Release image
        _latest="${ZJAIL_DIST_DATASET}/${_base}@release"
    else
        _fatal "BASE/RELEASE image [${_base}] not found"
    fi

    # Check run mount point exists
    _silent /bin/test -d \'"${ZJAIL_RUN}"\' || _fatal "ZJAIL_RUN [${ZJAIL_RUN}] not found"

    # Generate random 64-bit jail_id and IPv6 suffix
    local _instance_id
    _instance_id="$(_run gen_id)"

    # Check for ID collisions
    while _silent /bin/test -d \'"${ZJAIL_RUN}/${_instance_id}"\'
    do
        _instance_id="$(_run gen_id)"
    done

    if [ ${#_instance_id} -ne 13 ] # should be 13 chars
    then
        _err "Invalid _instance_id: ${_instance_id}"
    fi

    local _ipv4_lo
    _ipv4_lo="$(_run gen_lo)"
    local _ipv6_suffix
    _ipv6_suffix="$(_run get_ipv6_suffix \'"$_instance_id"\')"
    local _counter
    _counter="$(_run increment_counter \'"$ZJAIL_CONFIG/.counter"\')"

    # Clone base
    _check /sbin/zfs clone \'"${_latest}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'

    # Clean up if we exit with error
    # shellcheck disable=SC2064
    trap "_run /sbin/zfs destroy -Rf \'${ZJAIL_RUN_DATASET}/${_instance_id}\'" EXIT

    # Delay options processing until after we have created the image dataset so
    # that we can operate on this directly

    local _site=""
    local _jail_params=""
    local _hostname="${_instance_id}"
    local _autostart="off"
    local _firstboot_id=0
    local _run=0
    local _wheel=""
    local _start=1

### START_CREATE
    while getopts "aC:f:F:h:j:J:np:r:s:S:u:Uv:V:w" _opt; do
### END_CREATE
### START_BUILD
#    # shellcheck disable=SC2162
#    while read _opt OPTARG; do  
### END_BUILD
        case "${_opt}" in
            a|AUTOSTART)
                # Autostart
                _autostart="on"
                ;;
            C|COPY)
                # Copy file from host
                local _host_path="${OPTARG%:*}"
                local _instance_path="${OPTARG#*:}"
                _check /bin/cp \'"${_host_path}"\' \'"${ZJAIL_RUN}/${_instance_id}/${_instance_path}"\'
                ;;
            f|FIRSTBOOT_CMD)
                # Install command as firstboot script
                if [ ! -d "${ZJAIL_RUN}/${_instance_id}/var/firstboot_run.d" ]
                then
                    # Install firstboot_run
                    install_firstboot_run "${ZJAIL_RUN}/${_instance_id}"
                fi
                local _firstboot_file
                _firstboot_file="$(printf '%s/%s/var/firstboot_run.d/%04d-run' "${ZJAIL_RUN}" "${_instance_id}" "${_firstboot_id}")"
                _log_message "firstboot_file: ${_firstboot_file}"
                echo "${OPTARG}" | _check /usr/bin/tee \'"${_firstboot_file}"\' >&2
                _firstboot_id=$((_firstboot_id + 1))
                ;;
            F|FIRSTBOOT_FILE)
                # Iinstall file as firstboot script
                if [ ! -d "${ZJAIL_RUN}/${_instance_id}/var/firstboot_run.d" ]
                then
                    # Install firstboot_run
                    _log_message "Installing firstboot_run"
                    install_firstboot_run "${ZJAIL_RUN}/${_instance_id}"
                fi
                local _firstboot_file
                _firstboot_file="$(printf '%s/%s/var/firstboot_run.d/%04d-run' "${ZJAIL_RUN}" "${_instance_id}" "${_firstboot_id}")"
                _log_message "firstboot_file: ${_firstboot_file}"
                if [ "${OPTARG}" = "-" ]
                then
                    # Install from stdin
                    _check /usr/bin/tee \'"${_firstboot_file}"\'
                else
                    # Install from file
                    if [ ! -f "${OPTARG}" ]
                    then
                        _fatal "Run file [${OPTARG}] not found"
                    fi
                    _check /usr/bin/tee \'"${_firstboot_file}"\' >&2 <"${OPTARG}" 
                fi
                _firstboot_id=$((_firstboot_id + 1))
                ;;
            h|HOSTNAME)
                # Set hostname
                _hostname="${OPTARG}"
                ;;
            j|JAIL_PARAM)
                # Add jail param
                _jail_params="$(printf '%s\n    %s;' "${_jail_params}" "${OPTARG}")"
                ;;
            J|JAIL_CONF)
                # Set jail.conf template
                _site="$(_run cat \'"${OPTARG}"\')" || _fatal "jail.conf template not found: ${OPTARG}"
                ;;
            n|NOSTART)  
                # Dont start instance
                _start=0
                ;;
            p|PKG)
                # Install pkg

                # Make sure /dev/null is available in chroot
                _check /sbin/mount -t devfs -o ruleset=4 devfs \'"${ZJAIL_RUN}/${_instance_id}/dev"\'
                # _check /sbin/devfs -m \'"${ZJAIL_RUN}/${_instance_id}/dev"\' rule -s 2 applyset

                # Check for resolv.conf in jail (copy host file is missing)
                if [ ! -f "${ZJAIL_RUN}/${_instance_id}/etc/resolv.conf" ]
                then
                    _check /bin/cp /etc/resolv.conf \'"${ZJAIL_RUN}/${_instance_id}/etc/resolv.conf"\'
                fi

                # Bootstrap pkg if needed
                if _log /usr/sbin/chroot \'"${ZJAIL_RUN}/${_instance_id}"\' /usr/sbin/pkg -N
                then
                    _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \'"${ZJAIL_RUN}/${_instance_id}"\' /usr/sbin/pkg bootstrap >&2
                fi

                _check ASSUME_ALWAYS_YES=YES /usr/sbin/chroot \'"${ZJAIL_RUN}/${_instance_id}"\' /usr/sbin/pkg install "${OPTARG}" >&2

                _check /sbin/umount \'"${ZJAIL_RUN}/${_instance_id}/dev"\'
                ;;
            r|RUN)
                # Run command instead of /etc/rc (shortcut for -j 'exec.start=...')
                # (We try to quote any embedded " characters but this will fail with escaped quotes)
                if [ "${_run}" -eq 0 ]
                then
                    # Clear any existing exec.start items
                    _jail_params="$(printf '%s\n    exec.start = "%s";' "${_jail_params}" "$(echo "${OPTARG}" | sed -e 's/"/\\"/g')" )"
                    _run=1
                else
                    _jail_params="$(printf '%s\n    exec.start += "%s";' "${_jail_params}" "$(echo "${OPTARG}" | sed -e 's/"/\\"/g')" )"
                fi
                ;;
            s|SYSRC)
                # Run sysrc
                _check /usr/sbin/chroot \'"${ZJAIL_RUN}/${_instance_id}"\' /usr/sbin/sysrc \'"${OPTARG}"\' >&2
                ;;
            S|COPY_ENVSUBST)
                # Copy file from host filtering througfh envsubst(1)
                if [ ! -x /usr/local/bin/envsubst ]
                then
                    _fatal "/usr/local/bin/envsubst not found (install gettext pkg)"
                fi
                local _host_path="${OPTARG%%:*}"
                local _instance_path="${OPTARG#*:}"
                _check ID=\'"${_instance_id}"\' HOSTNAME=\'"${_hostname}"\' SUFFIX=\'"${_ipv6_suffix}"\' \
                    envsubst \< \'"${_host_path}"\' \> \'"${ZJAIL_RUN}/${_instance_id}/${_instance_path}"\'
                ;;
            u|USER)
                # Add user (name:pk)
                local _name="${OPTARG%%:*}"
                local _pk="${OPTARG#*:}"
                local _uid=0
                local _home="/root"
                # Check if user exists
                if ! _silent /usr/sbin/pw -R \'"${ZJAIL_RUN}/${_instance_id}"\' usershow -n \'"${_name}"\'
                then
                    # Create user
                    # shellcheck disable=SC2086
                    _check /usr/sbin/pw -R \'"${ZJAIL_RUN}/${_instance_id}"\' useradd -n \'"${_name}"\' -m -s /bin/sh -h - ${_wheel}
                fi
                _uid=$(_run /usr/sbin/pw -R \'"${ZJAIL_RUN}/${_instance_id}"\' usershow -n \'"${_name}"\' \| awk -F: "'{ print \$3 }'")
                _home=$(_run /usr/sbin/pw -R \'"${ZJAIL_RUN}/${_instance_id}"\' usershow -n \'"${_name}"\' \| awk -F: "'{ print \$9 }'")
                _check /bin/mkdir -p -m 700 \'"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh"\'
                _check /usr/bin/printf "'%s\n'" \'"${_pk}"\' \>\> \'"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh/authorized_keys"\'
                # We assume uid == gid
                _check /usr/sbin/chown -R \'"${_uid}:${_uid}"\' \'"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh"\'
                _check /bin/chmod 600 \'"${ZJAIL_RUN}/${_instance_id}/${_home}/.ssh/authorized_keys"\'
                ;;
            U|UPDATE)  # Update instance (before boot)
                # Copy local resolv.conf
                if [ -f "${ZJAIL_BASE}/${_instance_id}/etc/resolv.conf" ]
                then
                    _check /bin/cp \'"${ZJAIL_RUN}/${_instance_id}/etc/resolv.conf"\' \'"${ZJAIL_RUN}/${_instance_id}/etc/resolv.conf.orig"\'
                fi
                _check /bin/cp /etc/resolv.conf \'"${ZJAIL_RUN}/${_instance_id}/etc/resolv.conf"\'

                /bin/echo "${_update_instance}" | _check /usr/sbin/chroot \'"${ZJAIL_RUN}/${_instance_id}"\' /bin/sh | _log_output
                ;;
            v|VOLUME) 
                # Attach volume $ZJAIL/volumes/<volume>
                local _volume="${OPTARG}"
                if ! _silent /sbin/zfs list -o name \'"${ZJAIL_VOLUMES_DATASET}/${_volume}"\'
                then
                    _fatal "Dataset ${ZJAIL_VOLUMES_DATASET}/${_volume} not found"
                fi
                _jail_params="$(printf '%s\n    exec.prepare += "mkdir -p $root/volumes/%s";\n    mount += "%s/%s $root/volumes/%s zfs rw 0 0";' \
                        "${_jail_params}" "${_volume}" "${ZJAIL_VOLUMES_DATASET}" "${_volume}" "${_volume}")"
                ;;
            V|VOLUME_CREATE) 
                # Attach volume $ZJAIL/volumes/<volume> (create if needed)
                # (To specify volume size use <volume:size> argument)
                local _volume="${OPTARG%%:*}"
                if ! _silent /sbin/zfs list -o name \'"${ZJAIL_VOLUMES_DATASET}/${_volume}"\'
                then
                    _check /sbin/zfs create -o canmount=noauto \'"${ZJAIL_VOLUMES_DATASET}/${_volume}"\'
                    local _quota
                    if _quota=$(expr "${OPTARG}" : '.*:\(.*\)')
                    then
                        _check /sbin/zfs set quota="${_quota}" \'"${ZJAIL_VOLUMES_DATASET}/${_volume}"\'
                    fi
                fi
                _jail_params="$(printf '%s\n    exec.prepare += "mkdir -p $root/volumes/%s";\n    mount += "%s/%s $root/volumes/%s zfs rw 0 0";' \
                        "${_jail_params}" "${_volume}" "${ZJAIL_VOLUMES_DATASET}" "${_volume}" "${_volume}")"
                ;;
            w|WHEEL)
                # Add subsequent users to the wheel group
                _wheel="-G wheel"
                ;;
            *)
                _fatal "Usage: ${_usage}"
                ;;
        esac
    done

    _check /sbin/zfs set zjail:id=\'"${_instance_id}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    _check /sbin/zfs set zjail:hostname=\'"${_hostname}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    _check /sbin/zfs set zjail:base=\'"${_latest}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    _check /sbin/zfs set zjail:suffix=\'"${_ipv6_suffix}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    _check /sbin/zfs set zjail:loopback=\'"${_ipv4_lo}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    _check /sbin/zfs set zjail:autostart=\'"${_autostart}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    _check /sbin/zfs set zjail:counter=\'"${_counter}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'

    local _counter24
    local _counter16
    local _counter8
    _counter24="$(/usr/bin/bc -l -e "c=${_counter}" -e 'print band(bshr(c,16),255),".",band(bshr(c,8),255),".",band(c,255)')"
    _counter16="$(/usr/bin/bc -l -e "c=${_counter}" -e 'print band(bshr(c,8),255),".",band(c,255)')"
    _counter8="$(/usr/bin/bc -l -e "c=${_counter}" -e 'print band(c,255)')"

    local _jail_conf

    # shellcheck disable=1078,1079,2027,2086
    { 
    _jail_conf="
${_site}

${_instance_id} {
    \$id = \"${_instance_id}\";
    \$hostname = \""${_hostname}"\";
    \$suffix = \"${_ipv6_suffix}\";
    \$ipv4_lo = \"${_ipv4_lo}\";
    \$counter = \"${_counter}\";
    \$counter24 = \"${_counter24}\";
    \$counter16 = \"${_counter16}\";
    \$counter8 = \"${_counter8}\";
    \$root = \""${ZJAIL_RUN}/${_instance_id}"\";
    path = \""${ZJAIL_RUN}/${_instance_id}"\";
    host.hostname = \$hostname;
    ${_jail_params}
}
"
    }

    # Dont use _check to avoid double quoting problems
    _log_cmdline /sbin/zfs set zjail:conf=\'"${_jail_conf}"\' \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\'
    /sbin/zfs set zjail:conf="${_jail_conf}" "${ZJAIL_RUN_DATASET}/${_instance_id}" || _fatal "Cant set zjail:conf property"

    _check /sbin/zfs snapshot \'"${ZJAIL_RUN_DATASET}/${_instance_id}@$(date -u +'%Y-%m-%dT%H:%M:%SZ')"\'

    if [ "${_start}" = "1" ] 
    then
        local _jail_verbose=""
        if [ -n "$DEBUG" ]
        then
            _jail_verbose="-v"
        fi

        _check /sbin/zfs get -H -o value zjail:conf \'"${ZJAIL_RUN_DATASET}/${_instance_id}"\' \| /usr/sbin/jail ${_jail_verbose} -f - -c "${_instance_id}" >&2
    fi

    trap - EXIT
    printf '%s\n' "$_instance_id"

### START_BUILD
#    )
### END_BUILD
}
