# pure.ksh — pretty, fast, informative prompt for ksh93u+m
#
# Inspired by pure.zsh (sindresorhus/pure) with starship-style extras.
# Designed as a pack.ksh plugin, depends on func.ksh for Result_t and
# async primitives (Future_t / defer / poll / await).
#
# Usage (via pack.ksh):
#   pack "$HOME/src/ksh/pure.ksh" load=now depends=(func.ksh)
#
# Usage (standalone):
#   . /path/to/func.ksh/init.ksh
#   . /path/to/pure.ksh/init.ksh
#
# Configuration (set PURE compound before sourcing, or ~/.config/ksh/pure.ksh):
#   PURE.cmd_max_exec_time=5      # seconds threshold for exec time display
#   PURE.git_untracked_dirty=true  # include untracked files in dirty check
#   PURE.git_async_ttl=30         # seconds before git cache expires
#   PURE.lang_async_ttl=300       # seconds before lang version cache expires
#   PURE.prompt_symbol='❯'        # prompt character

# Guard against double-sourcing
[[ -n ${_PURE_KSH_INIT:-} ]] && return 0

# Require func.ksh
if [[ -z ${_FUNC_KSH_INIT:-} ]]; then
    print -u2 "pure.ksh: func.ksh must be sourced first"
    return 1
fi

# -- Resolve root --------------------------------------------------------------
_PURE_ROOT=${.sh.file%/*}

# -- Read user config ----------------------------------------------------------
if [[ -z "${PURE+set}" ]]; then
    typeset -C PURE=(
        cmd_max_exec_time=5
        git_untracked_dirty=true
        git_async_ttl=30
        lang_async_ttl=300
        prompt_symbol='❯'
    )
fi

typeset _pure_config="${XDG_CONFIG_HOME:-$HOME/.config}/ksh/pure.ksh"
[[ -f "$_pure_config" ]] && . "$_pure_config"
unset _pure_config

# -- Source libraries (order matters: cache first, git/detect depend on it) ----
for _pure_lib in cache git detect segments; do
    . "${_PURE_ROOT}/lib/${_pure_lib}.ksh"
done
unset _pure_lib

# -- Global state --------------------------------------------------------------
# Git state (populated by _pure_git_refresh, read by segments)
typeset _PURE_GIT_TOPLEVEL=''
typeset _PURE_GIT_DIR=''
typeset _PURE_GIT_BRANCH=''
typeset _PURE_GIT_ACTION=''
typeset -i _PURE_GIT_STASH=0
typeset _PURE_GIT_STATUS=''
typeset _PURE_GIT_REMOTE=''
typeset -i _PURE_GIT_DIRTY=0

# Async futures for slow git operations
Future_t _PURE_GIT_STATUS_FUT
Future_t _PURE_GIT_REMOTE_FUT

# Language version state
typeset -a _PURE_LANG_VERSIONS=()
# Futures for language detection (one per language in _PURE_LANG_NAMES)
typeset -i _pure_i
for (( _pure_i = 0; _pure_i < ${#_PURE_LANG_NAMES[@]}; _pure_i++ )); do
    _PURE_LANG_VERSIONS+=('')
    eval "Future_t _PURE_LANG_FUT_${_pure_i}"
done
unset _pure_i

# Timing state
typeset -F _PURE_CMD_START=${SECONDS}
typeset -F _PURE_CMD_DURATION=0
typeset -i _PURE_LAST_STATUS=0
typeset _PURE_LAST_PWD=${PWD}
# Cached EUID (avoid fork to id -u on every prompt)
typeset -i _PURE_EUID=${EUID:-$(id -u)}
typeset -i _PURE_PROMPTED=1

# -- Initialize cache ----------------------------------------------------------
_pure_cache_init

# -- Preexec hook (DEBUG trap) -------------------------------------------------
# Fires before each command in the PARENT shell. Captures start time
# for exec duration tracking.
function _pure_preexec {
    # Gate: only capture on the first command after a prompt was shown.
    # The DEBUG trap fires before every simple command, so without this
    # gate we'd overwrite _PURE_CMD_START on internal commands too.
    if (( _PURE_PROMPTED )); then
        _PURE_CMD_START=$SECONDS
        _PURE_PROMPTED=0
    fi
}

# -- Precmd logic (runs at prompt time, in parent shell) -----------------------
# Called from the PS1 discipline function. All mutations persist because
# the discipline runs in the current shell, not a subshell.
function _pure_precmd {
    # Calculate command duration
    _PURE_CMD_DURATION=$(( SECONDS - _PURE_CMD_START ))

    # Detect directory change → refresh lang detection
    if [[ $PWD != "$_PURE_LAST_PWD" ]]; then
        _PURE_LAST_PWD=$PWD
        _pure_lang_refresh
        # Only clear lang caches on dir change — git caches are gated
        # on toplevel change inside _pure_git_refresh
        rm -f "${_PURE_CACHE_DIR}"/lang_* 2>/dev/null
    fi

    # Refresh git info (fast ops sync, slow ops deferred)
    _pure_git_refresh

    # Mark that we've shown a prompt (gates the next DEBUG trap capture)
    _PURE_PROMPTED=1
}

# -- Wire up PS1 via discipline function ---------------------------------------
# The discipline function fires in the CURRENT shell when ${_pure_ps1}
# is expanded, so all state mutations persist. This is the key
# architectural choice: zero-fork prompt rendering, full parent shell
# access for async collect/defer, correct $? tracking.
typeset _pure_ps1

function _pure_ps1.get {
    # Capture exit status. If hist.ksh is loaded, its PS1 discipline
    # fires first and clobbers $? — use its captured value instead.
    if [[ -n "${_HIST_LAST_EXIT+set}" ]]; then
        _PURE_LAST_STATUS=$_HIST_LAST_EXIT
    else
        _PURE_LAST_STATUS=$?
    fi
    _pure_precmd
    _pure_render "$_PURE_LAST_STATUS"
    # Escape ! → !! so ksh93's PS1 history-number expansion
    # doesn't mangle the prompt (e.g. +9!49 → +944649)
    .sh.value=${REPLY//'!'/'!!'}
}

trap '_pure_preexec' DEBUG
PS1=$'\n${_pure_ps1}'

# Initial language detection for the starting directory
_pure_lang_refresh

_PURE_KSH_INIT=1
