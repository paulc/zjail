#!/bin/sh

set -o pipefail
set -o nounset
set -o errexit

DEBUG="${DEBUG:-}"
COLOUR="${COLOUR:-}"

# Insert modules 

# INSERT: log.sh
# INSERT: util.sh
# INSERT: config.sh
# INSERT: setup.sh
# INSERT: base.sh
# INSERT: instance.sh
# INSERT: create_instance.sh
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
    . "${_src}/create_instance.sh"

    # We havent extracted subcommand logic so just try to run cmd
    cmd="${1}"
    shift
    ${cmd} "$@"
fi

# Generate usage from src
#    grep -h '^[a-z][a-zA-Z_].*(' src/* | \
#        sed -e 's/(.*#//' -e 's/(.*$//' -e 's/^/    /' | \
#        ( echo 'USAGE="'; sort; echo '"' ) 

# INSERT: USAGE

cmd="${1:-}"
shift

# Generate subcommand logic from src
#    grep -h '^[a-z][a-zA-Z_].*(' src/* | sed -e 's/\(.*\)(.*$/\1)  \1 "$@";;/' -e 's/^/    /' | \
#        ( printf 'case "${1:-}" in\n\n' ; sort; printf '    *) "Usage: $0 ${USAGE}";exit 1;;\nesac\n' )

# INSERT: CMDS

