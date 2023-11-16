#!/bin/sh

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
# ABI="$(/usr/bin/printf '%s:%d:%s' $(/usr/bin/uname -s) $(($(/usr/bin/uname -U) / 100000)) $(/sbin/sysctl -n hw.machine_arch))"
OS_RELEASE="$(/sbin/sysctl -n kern.osrelease)"
OS_RELEASE="${OS_RELEASE%-p[0-9]*}"     # Strip patch
ZPOOL="${ZPOOL:-zroot}"
ZJAIL="${ZJAIL:-zjail}"
ZJAIL="${ZJAIL##/}"
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
# shellcheck disable=SC2016
_firstboot_run='
#!/bin/sh

# KEYWORD: firstboot
# PROVIDE: firstboot_run
# REQUIRE: NETWORKING
# BEFORE: LOGIN

. /etc/rc.subr

: ${firstboot_run:="NO"}

name="firstboot_run"
rcvar="firstboot_run_enable"
start_cmd="_firstboot_run"

_firstboot_run() {
    printf "Running firstboot_run scripts:\n"
    for x in $(/bin/ls /var/firstboot_run.d)
    do
        /usr/bin/printf "    /var/firstboot_run.d/$x: %s " 
        if /bin/sh "/var/firstboot_run.d/$x"; then
            /usr/bin/printf "OK\n"
        else
            /usr/bin/printf "FAILED\n"
        fi
    done
}

load_rc_config $name
run_rc_command "$1"
'

# shellcheck disable=SC2016
_update_instance='
PAGER="/usr/bin/tail -n0" /usr/sbin/freebsd-update --currently-running $(/bin/freebsd-version) --not-running-from-cron fetch
if /usr/sbin/freebsd-update updatesready
then
    PAGER=/bin/cat /usr/sbin/freebsd-update install
fi
if ! /usr/sbin/pkg -N
then
    ASSUME_ALWAYS_YES=YES /usr/sbin/pkg bootstrap
fi
ASSUME_ALWAYS_YES=YES /usr/sbin/pkg update
ASSUME_ALWAYS_YES=YES /usr/sbin/pkg upgrade
if [ -f /etc/resolv.conf.orig ]
then
    mv /etc/resolv.conf.orig /etc/resolv.conf
fi
'

