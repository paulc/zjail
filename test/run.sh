#!/bin/sh

set -o pipefail
set -o nounset
set -o errexit

. ./src/log.sh

export DEBUG="${DEBUG:-1}"
export COLOUR="${COLOUR:-1}"

OS_RELEASE="$(/sbin/sysctl -n kern.osrelease)"
OS_RELEASE="${OS_RELEASE%-p[0-9]*}"     # Strip patch

if [ $(id -u) -ne 0 ]
then
	_fatal "ERROR: Must be run as root"
fi

export ZROOT="${ZROOT:-zroot}"

if [ -z "${ZJAIL:-}" ]
then
    export ZJAIL="$(printf '/tmp/zjail-test %s' $(/usr/bin/od -v -An -N4 -tx4 /dev/urandom))"

    # Setup datasets
    ./bin/zjail create_zfs_datasets

    # Add cleanup trap 
    if [ -z "${NODESTROY:-}" ]
    then
        trap "./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance; _run /sbin/zfs destroy -Rf \'${ZROOT}${ZJAIL}\'; rmdir \'${ZROOT}${ZJAIL}\'" EXIT
    else
        trap "./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance" EXIT
    fi

    # fetch release
    ./bin/zjail fetch_release "${OS_RELEASE}"

    # Create 2 bases 
    ./bin/zjail create_base b1
    ./bin/zjail update_base b1
    ./bin/zjail clone_base b1 b2

    # Check chroot_base / jexec_base
    VER1=$(./bin/zjail chroot_base b1 /bin/freebsd-version)
    VER2=$(echo /bin/freebsd-version | ./bin/zjail jexec_base b2)
    test "${VER1}" = "${VER2}"
else 
    trap "./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance" EXIT
fi

# Non persistent instance
ID=$(./bin/zjail create_instance b2 -r /bin/freebsd-version)
./bin/zjail list_instances | grep -q "${ID}"
./bin/zjail stop_instance $ID
./bin/zjail start_instance $ID
./bin/zjail destroy_instance $ID
./bin/zjail list_instances | grep -q "${ID}" || true

# Persistent instance
ID=$(./bin/zjail create_instance b2 -j persist -r /bin/freebsd-version)
./bin/zjail list_instances | grep -q "${ID}"
./bin/zjail stop_instance $ID
./bin/zjail start_instance $ID
./bin/zjail destroy_instance $ID
./bin/zjail list_instances | grep -q "${ID}" || true

# Create 2 persistent instances
I1=$(./bin/zjail create_instance b1 -j persist)
I2=$(./bin/zjail create_instance b2 -j persist)

./bin/zjail list_instances | grep -q "${I1}"
./bin/zjail list_instances | grep -q "${I2}"

./bin/zjail list_instances | xargs -n1 ./bin/zjail stop_instance
./bin/zjail list_instances | xargs -n1 ./bin/zjail start_instance
./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance

./bin/zjail list_instances | grep -q "${I1}" || true
./bin/zjail list_instances | grep -q "${I2}" || true

cat > "${ZJAIL}/config/lo.conf" <<'EOM'
    exec.clean;
    mount.devfs;
    devfs_ruleset = 4;
    persist;
    ip4.addr += "$lo|$ipv4_lo/32";
    ip6.addr += "$lo|::$suffix/128";
EOM

(
    LO=$(_run ifconfig lo create)
    trap "_run ifconfig $LO destroy" EXIT
    I1=$(./bin/zjail create_instance b1 -j "\$lo=$LO" -c "${ZJAIL}/config/lo.conf")
    jexec "${I1}" ifconfig -a
    ./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance
)

echo OK
