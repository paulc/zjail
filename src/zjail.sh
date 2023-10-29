#!/bin/sh

set -o pipefail
set -o nounset
set -o errexit

# Insert modules 

# INSERT: log.sh
# INSERT: util.sh
# INSERT: config.sh
# INSERT: setup.sh
# INSERT: base.sh
# INSERT: instance.sh
# INSERT: create.sh
MERGED=""

# For testing
if [ -z "${MERGED}" ]
then
    _src=$(dirname "$0")
    . "${_src}/log.sh"
    . "${_src}/util.sh"
    . "${_src}/config.sh"
    . "${_src}/setup.sh"
    . "${_src}/base.sh"
    . "${_src}/instance.sh"
    . "${_src}/create.sh"
fi

DEBUG="${DEBUG:-}"
COLOUR="${COLOUR:-}"

cmd="${1}"
shift
${cmd} "$@"
