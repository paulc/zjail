#!/bin/sh
# file: ./test/shunit.sh

set -o nounset
set -o pipefail
set -o errexit

. ./src/log.sh

if [ $(id -u) -ne 0 ]
then
	_fatal "ERROR: Must be run as root" 2>&1
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

    else
        # Use existing ZJAIL 
        if ! [ -d "${ZJAIL}/dist/${ARCH}/${OS_RELEASE}" -a -d "${ZJAIL}/base/${ARCH}/b1" ] 
        then
            _fatal "ERROR: ZJAIL [$ZJAIL] invalid" 2>&1
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
}

testLoopback() {
    # Create a sample site config (expects lo device to be passed as $lo in 
    # instance jail.conf)
    cat > "${ZJAIL}/config/lo.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        exec.clean;
        mount.devfs;
        devfs_ruleset = 4;
        persist;
        ip4.addr += "$lo|$ipv4_lo/32";
        ip6.addr += "$lo|::$suffix/128";
EOM
    LO=$(_run ifconfig lo create)
    ID=$(./bin/zjail create_instance b1 -j allow.raw_sockets -j "\$lo=$LO" -J "${ZJAIL}/config/lo.conf")
    SUFFIX=$(zfs get -H -o value zjail:suffix "${ZJAIL}/run/${ARCH}/${ID}")
    _silent ping -q -c1 -t1 "::${SUFFIX}" || fail PING6
    _silent jexec $ID ping -q -c1 -t1 ::1 || fail PING6
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    ifconfig $LO destroy
    rm "${ZJAIL}/config/lo.conf"
}

testCounter() {
    ID1=$(./bin/zjail create_instance b1 -r /bin/freebsd-version)
    ID2=$(./bin/zjail create_instance b1 -r /bin/freebsd-version)
    C1=$(zfs get -H -o value zjail:counter "${ZJAIL}/run/${ARCH}/${ID1}")
    C2=$(zfs get -H -o value zjail:counter "${ZJAIL}/run/${ARCH}/${ID2}")
    [ $(($C1 + 1)) -eq ${C2} ] || fail COUNTER
    ./bin/zjail destroy_instance $ID1 || fail DESTROY_INSTANCE
    ./bin/zjail destroy_instance $ID2 || fail DESTROY_INSTANCE
}

testSetHostname() {
    ID=$(./bin/zjail create_instance b1 -j persist -h OLD)
    assertContains "$(jexec $ID hostname)" OLD
    ./bin/zjail set_hostname $ID NEW || fail SET_HOSTNAME
    assertContains "$(jexec $ID hostname)" NEW
    assertContains "$(zfs get -H -o value zjail:hostname "${ZJAIL}/run/${ARCH}/${ID}")" NEW
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    assertContains "$(jexec $ID hostname)" NEW
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
}

testListInstanceDetails() {
    ID=$(./bin/zjail create_instance b1 -j persist)
    assertContains "$(./bin/zjail list_instance_details)" $ID
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
}

testListInstanceDetailsSingle() {
    ID=$(./bin/zjail create_instance b1 -j persist)
    assertContains "$(./bin/zjail list_instance_details $ID)" $ID
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
}

testEditJailConf() {
    ID=$(./bin/zjail create_instance b1 -j persist)
    export EDITOR=/bin/cat
    assertContains "$(./bin/zjail edit_jail_conf $ID)" $ID
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
}

testCreateInstanceAutostart() {
    ID=$(./bin/zjail create_instance b1 -a -j persist)
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail autostart || fail AUTOSTART
    _silent jls -j $ID name || fail JLS
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
}

testCreateInstanceJailConfig() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/usr/bin/touch /TEST";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    ID=$(./bin/zjail create_instance b1 -J "${ZJAIL}/config/test.conf")
    _silent jexec $ID ls /TEST || fail JEXEC
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
}

testCreateInstanceCopy() {
    cat > "${ZJAIL}/config/DATA" <<'EOM'
TEST
EOM
    ID=$(./bin/zjail create_instance b1 -j persist -C "${ZJAIL}/config/DATA:/DATA")
    assertEquals "$(jexec $ID cat /DATA)" TEST
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
}

testCreateInstanceFirstbootCommand() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    ID=$(./bin/zjail create_instance b1 -J "${ZJAIL}/config/test.conf" -f "touch /FIRSTBOOT1" -f "touch /FIRSTBOOT2")
    _silent jexec $ID ls /FIRSTBOOT1 || fail JEXEC
    _silent jexec $ID ls /FIRSTBOOT2 || fail JEXEC
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
}

testCreateInstanceFirstbootFile() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    cat > "${ZJAIL}/config/firstboot1" <<'EOM'
        touch /FIRSTBOOT1
EOM
    cat > "${ZJAIL}/config/firstboot2" <<'EOM'
        touch /FIRSTBOOT2
EOM
    ID=$(./bin/zjail create_instance b1 -J "${ZJAIL}/config/test.conf" -F "${ZJAIL}/config/firstboot1" -F "${ZJAIL}/config/firstboot2" -f "touch /FIRSTBOOT3")
    _silent jexec $ID ls /FIRSTBOOT1 || fail JEXEC
    _silent jexec $ID ls /FIRSTBOOT2 || fail JEXEC
    _silent jexec $ID ls /FIRSTBOOT3 || fail JEXEC
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf" "${ZJAIL}/config/firstboot1" "${ZJAIL}/config/firstboot2"
}

testCreateInstanceHostname() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    ID=$(./bin/zjail create_instance b1 -J "${ZJAIL}/config/test.conf" -h HOSTNAME)
    assertEquals "$(jexec $ID hostname)" HOSTNAME
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
}

testCreateInstanceJailParam() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    ID=$(./bin/zjail create_instance b1 -j "exec.start = 'touch /START'" -J "${ZJAIL}/config/test.conf")
    _silent jexec $ID ls /START || fail JEXEC
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
}

testCreateInstanceNoStart() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    ID=$(./bin/zjail create_instance b1 -n -J "${ZJAIL}/config/test.conf")
    _silent jls -j $ID name && fail JLS
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
}

testCreateInstancePackage() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    ID=$(./bin/zjail create_instance b1 -p bash -J "${ZJAIL}/config/test.conf")
    _silent jexec $ID /usr/local/bin/bash -c /usr/bin/uname || fail JEXEC
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
}

testCreateInstanceRun() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    ID=$(./bin/zjail create_instance b1 -r "touch /RUN1" -r "touch /RUN2" -J "${ZJAIL}/config/test.conf")
    _silent jexec $ID ls /RUN1 || fail JEXEC
    _silent jexec $ID ls /RUN2 || fail JEXEC
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
}

testCreateInstanceSysrc() {
    cat > "${ZJAIL}/config/test.conf" <<'EOM'
        exec.start = "/bin/sh /etc/rc";
        mount.devfs;
        devfs_ruleset = 4;
        persist;
EOM
    LO=$(_run ifconfig lo create)
    ID=$(./bin/zjail create_instance b1 -s sshd_enable=YES -j "ip6.addr = $LO|::\$suffix" -J "${ZJAIL}/config/test.conf")
    nc -z "::$(./bin/zjail get_ipv6_suffix $ID)" 22 || fail SSH
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    rm "${ZJAIL}/config/test.conf"
    ifconfig $LO destroy
}

testCreateInstanceEnvsubst() {
    if [ -x /usr/local/bin/envsubst ]
    then
        cat > "${ZJAIL}/config/ENVSUBST" <<'EOM'
${ABCD}
EOM
        export ABCD=TEST
        ID=$(./bin/zjail create_instance b1 -j persist -S "${ZJAIL}/config/ENVSUBST:/ENVSUBST")
        assertEquals "$(jexec $ID cat /ENVSUBST)" TEST
        ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    fi
}

testCreateInstanceAddUser() {
    # Create two users - one not in the wheel group (test1) and one in (test2)
    ID=$(./bin/zjail create_instance b1 -j persist -u 'test1:TEST1_PK' -w -u 'test2:TEST2_PK')
    assertNotContains "$(jexec $ID id -Gn test1)" wheel
    assertContains "$(jexec $ID id -Gn test2)" wheel
    assertEquals "$(jexec $ID stat -f %Sp /home/test1/.ssh)" "drwx------"
    assertEquals "$(jexec $ID stat -f %Sp /home/test2/.ssh)" "drwx------"
    assertEquals "$(jexec $ID stat -f %Sp /home/test1/.ssh/authorized_keys)" "-rw-------"
    assertEquals "$(jexec $ID stat -f %Sp /home/test2/.ssh/authorized_keys)" "-rw-------"
    assertEquals "$(jexec $ID cat /home/test1/.ssh/authorized_keys)" TEST1_PK
    assertEquals "$(jexec $ID cat /home/test2/.ssh/authorized_keys)" TEST2_PK
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
}

testCreateInstanceUpdate() {
    # Should have been updated when created
    ID1=$(./bin/zjail create_instance b1 -j persist)
    ID2=$(./bin/zjail create_instance ${OS_RELEASE} -U -j persist)
    V1=$(jexec $ID1 /bin/freebsd-version)
    V2=$(jexec $ID2 /bin/freebsd-version)
    assertEquals "${V1}" "${V2}"
    ./bin/zjail destroy_instance $ID1 || fail DESTROY_INSTANCE
    ./bin/zjail destroy_instance $ID2 || fail DESTROY_INSTANCE
}

testBuildNonPersistent() {
    cat > "${ZJAIL}/config/build-test" <<EOM
BASE b1
RUN /bin/freebsd-version
EOM
    ID=$(./bin/zjail build "${ZJAIL}/config/build-test")
    assertContains "$(./bin/zjail list_instances)" $ID
    _silent jls -j $ID && fail JLS
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}


testBuildFromRelease() {
    cat > "${ZJAIL}/config/build-test" <<EOM
BASE ${OS_RELEASE}
RUN /bin/freebsd-version
EOM
    ID=$(./bin/zjail build "${ZJAIL}/config/build-test")
    assertContains "$(./bin/zjail list_instances)" $ID
    _silent jls -j $ID && fail JLS
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}

testBuildInvalidBase() {
    cat > "${ZJAIL}/config/build-test" <<EOM
BASE INVALID
JAIL_PARAM persist
RUN /bin/freebsd-version
EOM
    ID=$(./bin/zjail build "${ZJAIL}/config/build-test") && fail INVALID
    return 0
}

testBuildPersistent() {
    cat > "${ZJAIL}/config/build-test" <<EOM
BASE b1
JAIL_PARAM persist
RUN /bin/freebsd-version
EOM
    ID=$(./bin/zjail build "${ZJAIL}/config/build-test")
    assertContains "$(./bin/zjail list_instances)" $ID
    _silent jls -j $ID || fail JLS
    ./bin/zjail stop_instance $ID || fail STOP_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail start_instance $ID || fail START_INSTANCE
    ./bin/zjail destroy_instance $ID || fail DESTROY_INSTANCE
    assertNotContains "$(./bin/zjail list_instances)" $ID
}

. /usr/local/bin/shunit2

