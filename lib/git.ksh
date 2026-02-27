# pure.ksh/lib/git.ksh — git information gathering
#
# Two tiers of git operations:
#   Fast (sync):  branch name, action state, stash count
#   Slow (async): porcelain status, ahead/behind remote
#
# Async operations use func.ksh's Future_t / defer / await.
# Results are written to cache files under $_PURE_CACHE_DIR
# and read by segment renderers in lib/segments.ksh.

# -- Git repo detection -------------------------------------------------------
# Sets REPLY to the git toplevel, or returns 1 if not in a repo.
# Uses rev-parse which is fast (~1ms).
function _pure_git_toplevel {
    REPLY=$(command git rev-parse --show-toplevel 2>/dev/null) || return 1
}

# -- Fast: branch name --------------------------------------------------------
# REPLY = branch name, or short SHA if detached, or empty.
function _pure_git_branch {
    REPLY=$(command git symbolic-ref --short HEAD 2>/dev/null) && return 0
    REPLY=$(command git rev-parse --short HEAD 2>/dev/null) && return 0
    REPLY=''
    return 1
}

# -- Fast: ongoing action (rebase, merge, etc.) -------------------------------
# Pure filesystem checks — no git commands, sub-millisecond.
# Uses $_PURE_GIT_DIR (set by _pure_git_refresh) to avoid forking.
# REPLY = action string or empty.
function _pure_git_action {
    typeset gitdir=${_PURE_GIT_DIR:-}
    [[ -z $gitdir ]] && { REPLY=''; return 1; }

    if [[ -d "$gitdir/rebase-merge" ]]; then
        if [[ -f "$gitdir/rebase-merge/interactive" ]]; then
            REPLY='rebase-i'
        else
            REPLY='rebase-m'
        fi
    elif [[ -d "$gitdir/rebase-apply" ]]; then
        if [[ -f "$gitdir/rebase-apply/rebasing" ]]; then
            REPLY='rebase'
        elif [[ -f "$gitdir/rebase-apply/applying" ]]; then
            REPLY='am'
        else
            REPLY='am/rebase'
        fi
    elif [[ -f "$gitdir/MERGE_HEAD" ]]; then
        REPLY='merge'
    elif [[ -f "$gitdir/CHERRY_PICK_HEAD" ]]; then
        REPLY='cherry-pick'
    elif [[ -f "$gitdir/REVERT_HEAD" ]]; then
        REPLY='revert'
    elif [[ -f "$gitdir/BISECT_LOG" ]]; then
        REPLY='bisect'
    else
        REPLY=''
    fi
}

# -- Fast: stash count --------------------------------------------------------
# REPLY = stash count (integer), 0 if none.
function _pure_git_stash {
    typeset -i count
    count=$(command git rev-list --count refs/stash 2>/dev/null) || count=0
    REPLY=$count
}

# -- Slow: porcelain status (runs async via defer) ----------------------------
# Parses `git status --porcelain` into counts.
# Output format (to channel/cache): "staged modified untracked conflicts dirty"
# This is a defer-compatible function (receives Result_t name as $1).
function _pure_git_status_gather {
    typeset -n _r=$1
    typeset line
    typeset -i staged=0 modified=0 untracked=0 conflicts=0

    typeset porcelain
    porcelain=$(command git status --porcelain -unormal 2>/dev/null) || {
        _r.err "git status failed" 1
        return 0
    }

    # Parse each line's two-char status code
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        typeset x=${line:0:1} y=${line:1:1}

        # Conflicts: both modified, or unmerged states
        case "${x}${y}" in
            UU|AA|DD|AU|UA|DU|UD)
                (( conflicts++ ))
                continue
                ;;
        esac

        # Index (staged) changes
        case $x in
            [MADRC]) (( staged++ )) ;;
        esac

        # Worktree (modified) changes
        case $y in
            [MD]) (( modified++ )) ;;
        esac

        # Untracked
        [[ $x == '?' ]] && (( untracked++ ))
    done <<< "$porcelain"

    typeset -i dirty=0
    (( staged + modified + untracked + conflicts > 0 )) && dirty=1

    _r.ok "${staged} ${modified} ${untracked} ${conflicts} ${dirty}"
}

# -- Slow: ahead/behind remote (runs async via defer) -------------------------
# Output format (to channel/cache): "ahead behind"
# This is a defer-compatible function.
function _pure_git_remote_gather {
    typeset -n _r=$1
    typeset counts
    counts=$(command git rev-list --left-right --count HEAD...@{u} 2>/dev/null) || {
        # No upstream configured — not an error, just no data
        _r.ok "0 0"
        return 0
    }

    # rev-list outputs "ahead\tbehind"
    typeset -i ahead behind
    ahead=${counts%%$'\t'*}
    behind=${counts##*$'\t'}

    _r.ok "${ahead} ${behind}"
}

# -- Orchestrator: refresh git info --------------------------------------------
# Called from the prompt preexec hook. Spawns async jobs for slow operations,
# collects fast info synchronously.
function _pure_git_refresh {
    # Detect repo change
    typeset toplevel=''
    _pure_git_toplevel && toplevel=$REPLY

    if [[ -z $toplevel ]]; then
        # Not in a git repo — clear state
        _PURE_GIT_TOPLEVEL=''
        _PURE_GIT_DIR=''
        _PURE_GIT_BRANCH=''
        _PURE_GIT_ACTION=''
        _PURE_GIT_STASH=0
        _PURE_GIT_STATUS=''
        _PURE_GIT_REMOTE=''
        _PURE_GIT_DIRTY=0
        return 0
    fi

    # Repo changed — clear stale in-memory state and caches
    if [[ "$toplevel" != "$_PURE_GIT_TOPLEVEL" ]]; then
        _PURE_GIT_STATUS=''
        _PURE_GIT_REMOTE=''
        _PURE_GIT_DIRTY=0
        _PURE_GIT_STATUS_FUT.reset
        _PURE_GIT_REMOTE_FUT.reset
        rm -f "${_PURE_CACHE_DIR}/git_status" "${_PURE_CACHE_DIR}/git_remote" 2>/dev/null
    fi

    _PURE_GIT_TOPLEVEL=$toplevel
    # Cache git-dir for _pure_git_action (avoids extra fork)
    _PURE_GIT_DIR=$(command git rev-parse --git-dir 2>/dev/null)

    # Fast operations — run synchronously every prompt
    _pure_git_branch;  _PURE_GIT_BRANCH=$REPLY
    _pure_git_action;  _PURE_GIT_ACTION=$REPLY
    _pure_git_stash;   _PURE_GIT_STASH=$REPLY

    # Slow operations — defer to background, read cached results
    # Only re-defer if no job is currently pending
    typeset status_cache="${_PURE_CACHE_DIR}/git_status"
    typeset remote_cache="${_PURE_CACHE_DIR}/git_remote"

    if _pure_cache_fresh "$status_cache" "${PURE.git_async_ttl:-30}"; then
        _PURE_GIT_STATUS=$(< "$status_cache")
    else
        defer -k git_status _PURE_GIT_STATUS_FUT _pure_git_status_gather
    fi

    if _pure_cache_fresh "$remote_cache" "${PURE.git_async_ttl:-30}"; then
        _PURE_GIT_REMOTE=$(< "$remote_cache")
    else
        defer -k git_remote _PURE_GIT_REMOTE_FUT _pure_git_remote_gather
    fi
}

# -- Collect completed futures -------------------------------------------------
# Non-blocking: reads results from any completed background jobs,
# writes them to cache files for the segments to read.
function _pure_git_collect {
    Result_t _pgc_r

    if poll _PURE_GIT_STATUS_FUT; then
        await _pgc_r _PURE_GIT_STATUS_FUT
        if _pgc_r.is_ok; then
            _PURE_GIT_STATUS=${_pgc_r.value}
            print -rn -- "${_pgc_r.value}" >| "${_PURE_CACHE_DIR}/git_status"
        fi
    fi

    if poll _PURE_GIT_REMOTE_FUT; then
        await _pgc_r _PURE_GIT_REMOTE_FUT
        if _pgc_r.is_ok; then
            _PURE_GIT_REMOTE=${_pgc_r.value}
            print -rn -- "${_pgc_r.value}" >| "${_PURE_CACHE_DIR}/git_remote"
        fi
    fi

    # Parse dirty flag from status
    if [[ -n $_PURE_GIT_STATUS ]]; then
        _PURE_GIT_DIRTY=${_PURE_GIT_STATUS##* }
    fi
}
