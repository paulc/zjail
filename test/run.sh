#!/bin/sh

set -o pipefail
set -o nounset
set -o errexit

. ./src/log.sh

export DEBUG=1 COLOUR=1

OS_RELEASE="$(/sbin/sysctl -n kern.osrelease)"
OS_RELEASE="${OS_RELEASE%-p[0-9]*}"     # Strip patch

if [ $(id -u) -ne 0 ]
then
	_fatal "ERROR: Must be run as root"
fi

export ZROOT="${ZROOT:-zroot}"
export ZJAIL="$(printf '/tmp/zjail-test %s' $(/usr/bin/od -v -An -N4 -tx4 /dev/urandom))"

./bin/zjail create_zfs_datasets
trap "./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance; _run /sbin/zfs destroy -Rf \'${ZROOT}${ZJAIL}\'" EXIT

./bin/zjail fetch_release "${OS_RELEASE}"
./bin/zjail create_base b1
./bin/zjail update_base b1
./bin/zjail clone_base b1 b2

VER1=$(./bin/zjail chroot_base b1 /bin/freebsd-version)
VER2=$(echo /bin/freebsd-version | ./bin/zjail jexec_base b2)

test "${VER1}" = "${VER2}"

ID=$(./bin/zjail create_instance b2 -j persist -r /bin/freebsd-version)
./bin/zjail stop_instance $ID
./bin/zjail start_instance $ID
./bin/zjail destroy_instance $ID

./bin/zjail create_instance b1 -j persist 
./bin/zjail create_instance b1 -j persist

./bin/zjail list_instances
./bin/zjail list_instances | xargs -n1 ./bin/zjail stop_instance
./bin/zjail list_instances | xargs -n1 ./bin/zjail start_instance
./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance

