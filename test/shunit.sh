#!/bin/sh
# file: ./test/shunit.sh

. ./src/log.sh

if [ $(id -u) -ne 0 ]
then
	_fatal "ERROR: Must be run as root"
fi

OS_RELEASE="$(/sbin/sysctl -n kern.osrelease)"
OS_RELEASE="${OS_RELEASE%-p[0-9]*}"     # Strip patch
ARCH="$(/usr/bin/uname -m)"

export DEBUG="${DEBUG:-}"
export COLOUR="${COLOUR:-}"
export ZROOT="${ZROOT:-zroot}"

oneTimeSetUp() {
    if [ -z "${ZJAIL:-}" ]
    then
        export ZJAIL="$(printf '/tmp/zjail-test %s' $(/usr/bin/od -v -An -N4 -tx4 /dev/urandom))"

        # Setup datasets
        ./bin/zjail create_zfs_datasets || fail CREATE_ZFS_DATASETS

        # Fetch release
        ./bin/zjail fetch_release "${OS_RELEASE}" || fail FETCH_RELEASE

        # Create base
        ./bin/zjail create_base b1 || fail CREATE_BASE
        ./bin/zjail update_base b1 || fail UPDATE_BASE
    else
        # Use existing ZJAIL 
        if ! [ -d "${ZJAIL}/dist/${ARCH}/${OS_RELEASE}" -a -d "${ZJAIL}/base/${ARCH}/b1" ] 
        then
            _fatal "ERROR: ZJAIL [$ZJAIL] invalid"
        fi
        # Make sure we dont delete
        export NODESTROY=1
    fi
}

oneTimeTearDown() {
    # Strangely 'oneTimeTearDown' runs twice (https://github.com/kward/shunit2/issues/112)
    # Check that we havent already destroyed the ZJAIL directory
    if [ -d "${ZJAIL}/run" ]
    then
        ./bin/zjail list_instances | xargs -n1 ./bin/zjail destroy_instance
        if [ -z "${NODESTROY:-}" ]
        then
            _run /sbin/zfs destroy -Rf \""${ZROOT}${ZJAIL}"\"
            _run rmdir \""${ZJAIL}"\"
        fi
    fi
}

testNonPersistent() {
    ID=$(./bin/zjail create_instance b1 -r /bin/freebsd-version)
    assertContains "$(./bin/zjail list_instances)" $ID
    _silent jls -j $ID && fail JLS
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}

testPersistent() {
    ID=$(./bin/zjail create_instance b1 -j persist -r /bin/freebsd-version)
    assertContains "$(./bin/zjail list_instances)" $ID
    _silent jls -j $ID || fail JLS
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail start_instance $ID && fail START_INSTANCE
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}


. /usr/local/bin/shunit2

