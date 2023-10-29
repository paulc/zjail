
### Utils

_NORMAL="$(printf "\033[0m")"
_RED="$(printf "\033[0;31m")"
_YELLOW="$(printf "\033[0;33m")"
_CYAN="$(printf "\033[0;36m")"

_log_cmdline() {
    # Log command line if DEBUG set (optionally in colour)
    if [ -n "$DEBUG" ]
    then
        local _cmd="$@"
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "CMD: $_cmd" >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    fi
}

_log_message() {
    # Log command line if DEBUG set (optionally in colour)
    if [ -n "$DEBUG" ]
    then
        local _msg="$@"
        printf '%s' "${COLOUR:+${_YELLOW}}" >&2
        printf '%s [%s]\n' "$(date '+%b %d %T')" "INFO: $_msg" >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    fi
}

_log() {
    # Run command optionally printing debug output if $DEBUG is set
    # (in colour if $COLOUR is set) and capture stdout/err
    #
    # Return exit status in $?
    #
    # Note: The cmdline is `eval`-ed so need to be careful with quoting .
    #   DIR="A B C"
    #   _log mkdir \'"${DIR}"\'
    #
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        _log_cmdline "$_cmd"
        printf '%s' "${COLOUR:+${_CYAN}}" >&2
        eval "$_cmd" 2>&1 | sed -e 's/^/     | /' >&2
        local _status=$?
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
        return $_status
    else
        eval "$_cmd"
    fi
}

_log_output() {
    local _status=$?
    if [ -n "$DEBUG" ]
    then
        printf '%s' "${COLOUR:+${_CYAN}}" >&2
        sed -e 's/^/     | /' >&2
        printf '%s' "${COLOUR:+${_NORMAL}}" >&2
    else
        cat >&2
    fi
    return $_status
}

_run() {
    # Run command directly via eval (logs cmd if $DEBUG set)
    local _cmd="$@"
    [ -n "$DEBUG" ] && _log_cmdline "$_cmd"
    eval "$_cmd"
}

_silent() {
    # Run command silently (if DEBUG set just output command)
    local _cmd="$@"
    [ -n "$DEBUG" ] && _log_cmdline "$_cmd"
    eval "$_cmd" >/dev/null 2>&1
}

_check() {
    # Run command optionally printing debug output if $DEBUG is set
    # (in colour if $COLOUR is set) and exit if fails
    local _cmd="$@"
    if [ -n "$DEBUG" ]
    then
        _log_cmdline "$_cmd"
        printf '%s' "${COLOUR:+${_CYAN}}" >&2
        eval "$_cmd" 2>&1 | sed -e 's/^/     | /' >&2
        local _status=$?
        if [ $_status -eq 0 ]
        then
            printf '%s' "${COLOUR:+${_NORMAL}}" >&2
            return $_status
        else
            printf '%s[FATAL (%s)]%s\n' "${COLOUR:+${_RED}}" "$_status" "${COLOUR:+${_NORMAL}}" >&2
            exit $_status
        fi
    else
        eval "$_cmd" || exit $?
    fi

}

_fatal() {
    # Exit with message
    printf '%sFATAL: %s%s\n' "${COLOUR:+${_RED}}" "$@" "${COLOUR:+${_NORMAL}}" >&2
    exit 1
}

