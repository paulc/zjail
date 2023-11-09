### Setup environment

create_zfs_datasets() { #
    _silent /sbin/zfs list -H -o name \'"${ZJAIL_ROOT_DATASET}"\' && _fatal "Dataset ${ZJAIL_ROOT_DATASET} exists"
    _check /sbin/zfs create -o compression=lz4 -o mountpoint=\'"/${ZJAIL}"\' -p \'"${ZJAIL_ROOT_DATASET}"\'
    _check /sbin/zfs create -p \'"${ZJAIL_DIST_DATASET}"\'
    _check /sbin/zfs create -p \'"${ZJAIL_BASE_DATASET}"\'
    _check /sbin/zfs create -p \'"${ZJAIL_RUN_DATASET}"\'
    _check /sbin/zfs create -p \'"${ZJAIL_CONFIG_DATASET}"\'
    _check /sbin/zfs create -p \'"${ZJAIL_VOLUMES_DATASET}"\'
}

### Releases

fetch_release() { # [os_release]
    local _release="${1:-${OS_RELEASE}}"
    _silent /bin/test -d \'"${ZJAIL_DIST}"\' || _fatal "ZJAIL_DIST [${ZJAIL_DIST}] not found"
    _check /sbin/zfs create -p \'"${ZJAIL_DIST_DATASET}/${_release}"\'
    if [ "${ARCH}" = "amd64" ]
    then
        local _sets="base.txz lib32.txz"
    else
        local _sets="base.txz"
    fi
    for _f in $_sets
    do
        _check /usr/bin/fetch -o - \'"${DIST_SRC}/${ARCH}/${_release}/${_f}"\' \| /usr/bin/tar -C \'"${ZJAIL_DIST}/${_release}"\' -xf -
    done
    _check /sbin/zfs snapshot \'"${ZJAIL_DIST_DATASET}/${_release}@release"\'
    _check /sbin/zfs set readonly=on \'"${ZJAIL_DIST_DATASET}/${_release}"\'
}

