# pure.ksh/lib/segments.ksh — segment renderers and prompt composition
#
# Each segment is a function _pure_seg_NAME that:
#   1. Tests a contextual gate (should it display?)
#   2. Reads cached/global state (no forks)
#   3. Appends formatted text to REPLY
#
# The prompt is a composed pipeline: _pure_render calls each segment
# in order, accumulating the preprompt line. This follows func.ksh's
# composition philosophy — each segment is independent, the render
# function is the `sequence` that chains them.

# -- Color helpers (no forks — precomputed constants) --------------------------

typeset _PC_RESET=$'\033[0m'
typeset _PC_BLUE=$'\033[38;5;4m'
typeset _PC_GRAY=$'\033[38;5;242m'
typeset _PC_MAGENTA=$'\033[38;5;5m'
typeset _PC_RED=$'\033[38;5;1m'
typeset _PC_CYAN=$'\033[38;5;6m'
typeset _PC_YELLOW=$'\033[38;5;3m'
typeset _PC_GREEN=$'\033[38;5;2m'
typeset _PC_ORANGE=$'\033[38;5;208m'

# Append colored text to REPLY with automatic spacing
function _pure_append {
    typeset color=$1 text=$2
    [[ -z $text ]] && return 0
    [[ -n $REPLY ]] && REPLY+=' '
    REPLY+="${color}${text}${_PC_RESET}"
}

# -- Segments ------------------------------------------------------------------

# ✦N — background jobs indicator
# Note: $(jobs -p) in ksh93 uses the virtual subshell optimization
# (no real fork) since jobs is a builtin. The virtual subshell sees
# the parent's job table because it's the same process.
function _pure_seg_jobs {
    typeset jp
    jp=$(jobs -p 2>/dev/null) || return 0
    [[ -z $jp ]] && return 0

    # Word-split PIDs into array for fast counting (no loop)
    typeset -a _pids
    set -A _pids -- $jp
    typeset -i count=${#_pids[@]}

    (( count > 0 )) && _pure_append "$_PC_RED" "✦${count}"
}

# user@host — only in SSH, container, or root
function _pure_seg_userhost {
    # Root user (EUID cached at init to avoid fork)
    if (( ${_PURE_EUID} == 0 )); then
        _pure_append "$_PC_GRAY" "${USER:-root}@${HOSTNAME%%.*}"
        return 0
    fi

    # SSH session
    if [[ -n ${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-} ]]; then
        _pure_append "$_PC_GRAY" "${USER}@${HOSTNAME%%.*}"
        return 0
    fi

    # Container detection (common env vars and cgroup markers)
    if [[ -n ${container:-} || -f /.dockerenv ]]; then
        _pure_append "$_PC_GRAY" "${USER}@${HOSTNAME%%.*}"
        return 0
    fi
}

# ~/path — current directory with ~ substitution
function _pure_seg_dir {
    typeset dir=${PWD}
    # Replace $HOME prefix with ~ (pure string ops, no fork)
    [[ $dir == "$HOME"* ]] && dir="~${dir#"$HOME"}"
    _pure_append "$_PC_BLUE" "$dir"
}

# Language versions — contextual, from cache
function _pure_seg_lang {
    typeset -i i n=${#_PURE_LANG_NAMES[@]}
    typeset name ver color

    for (( i = 0; i < n; i++ )); do
        ver=${_PURE_LANG_VERSIONS[$i]:-}
        [[ -z $ver ]] && continue

        name=${_PURE_LANG_NAMES[$i]}
        # Map language index to color
        typeset color_code
        color_code=${_PURE_LANG_COLORS[$i]}
        color=$'\033[38;5;'"${color_code}m"

        _pure_append "$color" "${name}:${ver}"
    done
}

# Git branch + dirty marker
function _pure_seg_git_branch {
    [[ -z $_PURE_GIT_BRANCH ]] && return 0

    typeset display=$_PURE_GIT_BRANCH

    # Dirty marker
    if (( _PURE_GIT_DIRTY )); then
        _pure_append "$_PC_GRAY" "$display"
        # Append dirty marker in magenta (no space)
        REPLY+="${_PC_MAGENTA}*${_PC_RESET}"
    else
        _pure_append "$_PC_GRAY" "$display"
    fi
}

# Git status counts: +staged !modified ?untracked $stash =conflicts
function _pure_seg_git_status {
    [[ -z $_PURE_GIT_BRANCH ]] && return 0
    [[ -z $_PURE_GIT_STATUS ]] && return 0

    typeset -i staged modified untracked conflicts dirty
    # Parse "staged modified untracked conflicts dirty"
    typeset s=$_PURE_GIT_STATUS
    staged=${s%% *};    s=${s#* }
    modified=${s%% *};  s=${s#* }
    untracked=${s%% *}; s=${s#* }
    conflicts=${s%% *}

    typeset detail=''
    (( staged > 0 ))    && detail+="+${staged}"
    (( modified > 0 ))  && detail+="!${modified}"
    (( untracked > 0 )) && detail+="?${untracked}"

    # Stash (from separate fast check)
    (( _PURE_GIT_STASH > 0 )) && detail+='$'"${_PURE_GIT_STASH}"

    (( conflicts > 0 )) && detail+="=${conflicts}"

    [[ -n $detail ]] && _pure_append "$_PC_CYAN" "$detail"
}

# Git arrows: ⇡ahead ⇣behind
function _pure_seg_git_arrows {
    [[ -z $_PURE_GIT_BRANCH ]] && return 0
    [[ -z $_PURE_GIT_REMOTE ]] && return 0

    typeset -i ahead behind
    ahead=${_PURE_GIT_REMOTE%% *}
    behind=${_PURE_GIT_REMOTE##* }

    typeset arrows=''
    (( ahead > 0 ))  && arrows+="⇡${ahead}"
    (( behind > 0 )) && arrows+="⇣${behind}"

    [[ -n $arrows ]] && _pure_append "$_PC_CYAN" "$arrows"
}

# Git action: rebase, merge, cherry-pick, etc.
function _pure_seg_git_action {
    [[ -z $_PURE_GIT_ACTION ]] && return 0
    _pure_append "$_PC_YELLOW" "$_PURE_GIT_ACTION"
}

# Execution time: shown when last command took > threshold
function _pure_seg_exectime {
    typeset -i threshold=${PURE.cmd_max_exec_time:-5}
    typeset -i total=${_PURE_CMD_DURATION%.*}

    (( total < threshold )) && return 0

    # Format: concise human-readable duration
    typeset display
    if (( total < 60 )); then
        display="${total}s"
    elif (( total < 3600 )); then
        display="$(( total / 60 ))m $(( total % 60 ))s"
    else
        display="$(( total / 3600 ))h $(( (total % 3600) / 60 ))m"
    fi

    _pure_append "$_PC_YELLOW" "$display"
}

# -- Prompt composition --------------------------------------------------------

# Build the full preprompt line into REPLY.
# Each segment conditionally appends its content.
function _pure_render_preprompt {
    REPLY=''

    _pure_seg_jobs
    _pure_seg_userhost
    _pure_seg_dir
    _pure_seg_lang
    _pure_seg_git_branch
    _pure_seg_git_status
    _pure_seg_git_arrows
    _pure_seg_git_action
    _pure_seg_exectime
}

# Build the prompt symbol (line 2).
# $1 = last exit status
function _pure_render_symbol {
    typeset -i last=${1:-0}
    typeset sym=${PURE.prompt_symbol:-❯}

    if (( last == 0 )); then
        REPLY="${_PC_MAGENTA}${sym}${_PC_RESET}"
    else
        REPLY="${_PC_RED}${sym}${_PC_RESET}"
    fi
}

# Full prompt render — builds into REPLY (no fork, no print).
# Called from the PS1 discipline function.
# $1 = last exit status
function _pure_render {
    typeset -i last=${1:-0}

    # Collect any completed async results before rendering
    _pure_git_collect
    _pure_lang_collect

    _pure_render_preprompt
    typeset preprompt=$REPLY

    _pure_render_symbol "$last"
    typeset symbol=$REPLY

    # Two-line prompt: preprompt on line 1, symbol + space on line 2
    REPLY="${preprompt}"$'\n'"${symbol} "
}
