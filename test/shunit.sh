#!/bin/sh
# file: ./test/shunit.sh

set -o nounset
set -o pipefail
set -o errexit

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

# We normally create a clean ZJAIL volume, populate with release and
# create/update a base (b1) - however this can be time consuming so if
# the ZJAIL env variable is set and valid we use this instead
#
# To prevent the volume from being destroyed at the end of the test
# (so that it can be reused) set the NODESTROY env variable
oneTimeSetUp() {
    if [ -z "${ZJAIL:-}" ]
    then
        # Create new volume and populate

        # We deliberately use a volume with a space in the name to test
        # possible quoting issues
        export ZJAIL="$(printf '/tmp/zjail-test %s' $(/usr/bin/od -v -An -N4 -tx4 /dev/urandom))"

        # Setup datasets
        ./bin/zjail create_zfs_datasets || fail CREATE_ZFS_DATASETS

        # Fetch release
        ./bin/zjail fetch_release "${OS_RELEASE}" || fail FETCH_RELEASE

        # Create and update base
        ./bin/zjail create_base b1 || fail CREATE_BASE
        ./bin/zjail update_base b1 || fail UPDATE_BASE

        # Create a sample site config (expects lo device to be passed as $lo in 
        # instance jail.conf)
        cat > "${ZJAIL}/config/lo.conf" <<'EOM'
            exec.clean;
            mount.devfs;
            devfs_ruleset = 4;
            persist;
            ip4.addr += "$lo|$ipv4_lo/32";
            ip6.addr += "$lo|::$suffix/128";
EOM
    else
        # Use existing ZJAIL 
        if ! [ -d "${ZJAIL}/dist/${ARCH}/${OS_RELEASE}" -a -d "${ZJAIL}/base/${ARCH}/b1" -a -f "${ZJAIL}/config/lo.conf" ] 
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

testCloneBase() {
    ./bin/zjail clone_base b1 b2 || fail CLONE_BASE
    [ -d "${ZJAIL}/base/${ARCH}/b2" ] || fail CLONE_BASE
    _run zfs destroy -r \""${ZROOT}${ZJAIL}/base/${ARCH}/b2"\"
}

testChrootBase() {
    VER="$(./bin/zjail chroot_base b1 /bin/freebsd-version)"
    assertContains "${VER}" "${OS_RELEASE}"
}

testJexecBase() {
    VER="$(echo /bin/freebsd-version | ./bin/zjail jexec_base b1)"
    assertContains "${VER}" "${OS_RELEASE}"
}

testSnapshotBase() {
    N1=$(zfs list -H -t snap "${ZROOT}${ZJAIL}/base/${ARCH}/b1" | wc -l)
    ./bin/zjail snapshot_base b1
    N2=$(zfs list -H -t snap "${ZROOT}${ZJAIL}/base/${ARCH}/b1" | wc -l)
    [ "$((N1 + 1))" -eq "${N2}" ] || fail SNAPSHOT_BASE
}

testLatestSnapshot() {
    LATEST="$(./bin/zjail get_latest_snapshot b1)"
    ./bin/zjail snapshot_base b1
    assertNotNull "${LATEST}"
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

testFromRelease() {
    ID=$(./bin/zjail create_instance ${OS_RELEASE} -r /bin/freebsd-version)
    assertContains "$(./bin/zjail list_instances)" $ID
    _silent jls -j $ID && fail JLS
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}

testInvalidBase() {
    ./bin/zjail create_instance INVALID -r /bin/freebsd-version && fail INVALID_BASE
    return 0
}

testPersistent() {
    ID=$(./bin/zjail create_instance b1 -j persist -r /bin/freebsd-version)
    assertContains "$(./bin/zjail list_instances)" $ID
    _silent jls -j $ID || fail JLS
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}

testAutostart() {
    ID=$(./bin/zjail create_instance b1 -j persist)
    assertContains "$(./bin/zjail list_instances)" $ID
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail set_autostart $ID || fail SET_AUTOSTART
    ./bin/zjail autostart || fail AUTOSTART
    _silent jls -j $ID || fail AUTOSTART
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail clear_autostart $ID || fail SET_AUTOSTART
    ./bin/zjail autostart || fail AUTOSTART
    _silent jls -j $ID && fail AUTOSTART
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}
testLoopback() {
    LO=$(_run ifconfig lo create)
    ID=$(./bin/zjail create_instance b1 -j allow.raw_sockets -j "\$lo=$LO" -c "${ZJAIL}/config/lo.conf")
    SUFFIX=$(zfs get -H -o value zjail:suffix "${ZJAIL}/run/${ARCH}/${ID}")
    _silent ping -q -c1 -t1 "::${SUFFIX}" || fail PING6
    _silent jexec $ID ping -q -c1 -t1 ::1 || fail PING6
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    ifconfig $LO destroy
}

. /usr/local/bin/shunit2

