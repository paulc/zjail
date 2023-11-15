#!/bin/sh

get_default_ipv4() {
    ifconfig "$(sh -c "route -n get default || route -n get 1.1.1.1" 2>/dev/null | awk '/interface:/ { print $2 }')" inet | awk '/inet/ { print $2; exit }'
}

get_default_ipv6() {
    ifconfig "$(sh -c "route -6n get default || route -6n get ::/1" 2>/dev/null | awk '/interface:/ { print $2 }')" inet6 | awk '/inet6/ && ! /fe80::/ { print $2; exit }'
}

install_firstboot_run() { # <root>
    local _root="${1:-}"
    if [ -z "${_root}" ]
    then
        _fatal "Usage: install_firstboot_run <root>"
    fi
    _silent /bin/test -d \'"${_root}"\' || _fatal "Root path [${_root}] not found"

    # Initialise firstboot_run rc.d script (execs files in /var/firstboot_run.d)
    _check /bin/mkdir -p \'"${_root}/var/firstboot_run.d"\'
    _check /bin/mkdir -p \'"${_root}/usr/local/etc/rc.d"\'
    if ! /bin/echo "${_firstboot_run}" | _silent /usr/bin/tee -a \'"${_root}/usr/local/etc/rc.d/firstboot_run"\'
    then
        _fatal "Cant write ${_root}/usr/local/etc/rc.d/firstboot_run"
    fi
    _check /bin/chmod 755 \'"${_root}/usr/local/etc/rc.d/firstboot_run"\'
    _check /usr/bin/touch \'"${_root}/firstboot"\'
    _check /usr/sbin/chroot \'"${_root}"\' /usr/sbin/sysrc firstboot_run_enable=YES >&2
}

# Generate random 64-bit ID as 13 character base32 encoded string
gen_id() {
    local _id="0000000000000"
    # Ensure id is not all-numeric (invalid jail name)
    while expr "${_id}" : '^[0-9]*$' >/dev/null
    do
        # Get 2 x 32 bit unsigned ints from /dev/urandom
        # (od doesnt accept -t u8 so we multiply in bc)

        # shellcheck disable=SC2046
        set -- $(od -v -An -N8 -t u4 /dev/urandom)

        # Reserve ::0 to ::ffff for system
        while [ "${1:-0}" -eq 0 ] && [ "${2:-0}" -lt 65536 ]
        do
            # shellcheck disable=SC2046
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
    # shellcheck disable=SC2046
    /usr/bin/printf '127.%d.%d.%d\n' $(/usr/bin/od -v -An -N3 -t u1 /dev/urandom)
}

# Generate random IPv6 Unique Local Address prefix
gen_ula() {
    # 48-bit ULA address - fdXX:XXXX:XXXX (add /16 subnet id and /64 device address)
    # shellcheck disable=SC2046
    printf "fd%s:%s%s:%s%s\n" $(od -v -An -N5 -t x1 /dev/urandom)
}

# Generate 64-bit IPv6 suffix from pseudo-base32 ID
get_ipv6_suffix() { # <id>
    local _id="${1:-}"
    if [ -z "${_id}" ]
    then
        _fatal "Usage: get_ipv6_suffix <id>"
    fi
    # shellcheck disable=SC2046,SC2183
    printf '%04x:%04x:%04x:%04x\n' $(
        awk -v x="${_id}" '
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
increment_counter() { # <file>
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

# Set counter (only set forwards)
set_counter() { # <file> <value>
    local _file="${1:-}"
    local _value="${2:-}"
    if [ -z "${_file}" ]
    then
        _fatal "Usage: set_counter <file> <value>"
    fi

    /usr/bin/lockf -k -s -t 2 "${_file}.lock" /bin/sh -eu <<EOM
CURRENT=\$(cat "${_file}" 2>/dev/null || echo 0)
if [ ${_value} -gt \${CURRENT} ] 2>/dev/null
then
    echo ${_value} > "${_file}"
else
    echo "ERROR: Cant set counter [CURRENT:\${CURRENT}]" >&2
fi
EOM
}

