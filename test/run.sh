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
export ZJAIL="$(printf '/tmp/zjail-test %s' $(/usr/bin/od -v -An -N4 -tx4 /dev/urandom))"

# Setup datasets
./bin/zjail create_zfs_datasets

# Add cleanup trap 
trap "./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance; _run /sbin/zfs destroy -Rf \'${ZROOT}${ZJAIL}\'" EXIT

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

# Non persistent instance
ID=$(./bin/zjail create_instance b2 -r /bin/freebsd-version)
./bin/zjail stop_instance $ID
./bin/zjail start_instance $ID
./bin/zjail destroy_instance $ID

# Persistent instance
ID=$(./bin/zjail create_instance b2 -j persist -r /bin/freebsd-version)
./bin/zjail stop_instance $ID
./bin/zjail start_instance $ID
./bin/zjail destroy_instance $ID

# Create 2 persistent instances
I1=$(./bin/zjail create_instance b1 -j persist)
I2=$(./bin/zjail create_instance b2 -j persist)

./bin/zjail list_instances | grep -q "${I1}"
./bin/zjail list_instances | grep -q "${I2}"

./bin/zjail list_instances | xargs -n1 ./bin/zjail stop_instance
./bin/zjail list_instances | xargs -n1 ./bin/zjail start_instance
./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance

[ $(./bin/zjail list_instances | wc -l) -eq 0 ]

echo OK
