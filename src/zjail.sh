#!/bin/sh

set -o pipefail
set -o nounset
set -o errexit

# For testing - merged in bin
_src=$(dirname "$0")
. "${_src}/log.sh"
. "${_src}/util.sh"
. "${_src}/config.sh"
. "${_src}/setup.sh"
. "${_src}/base.sh"
. "${_src}/instance.sh"
. "${_src}/create.sh"

DEBUG="${DEBUG:-}"
COLOUR="${COLOUR:-}"

cmd="${1}"
shift
${cmd} "$@"
