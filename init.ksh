# pure.ksh — minimal pure.zsh-style prompt for ksh93
# Zero dependencies. Self-contained.

# Absorb and clear any stale DEBUG trap from previous versions.
function _pure_preexec { :; }
trap - DEBUG
unset -f _pure_preexec 2>/dev/null

[[ -n ${_PURE_INIT:-} ]] && return 0

# -- Config --------------------------------------------------------------------
typeset -C PURE=(cmd_max_exec_time=5 git_async_ttl=5 prompt_symbol=$'\u276f')
typeset _pconf=${XDG_CONFIG_HOME:-$HOME/.config}/ksh/pure.ksh
[[ -f $_pconf ]] && . "$_pconf"
unset _pconf

# -- Cache ---------------------------------------------------------------------
typeset _PURE_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ksh/pure"
[[ -d $_PURE_CACHE_DIR ]] || mkdir -p "$_PURE_CACHE_DIR" 2>/dev/null

function _pure_cache_fresh {
	typeset file=$1 ttl=${2:-5}
	[[ -f $file ]] || return 1
	typeset -i now=${EPOCHSECONDS:-$(printf '%(%s)T')}
	typeset -i threshold=$(( now - ttl ))
	typeset ts
	ts=$(printf '%(%Y%m%d%H%M.%S)T' "#$threshold")
	typeset ref="${_PURE_CACHE_DIR}/.ttl_ref"
	touch -t "$ts" "$ref" 2>/dev/null || return 1
	[[ "$file" -nt "$ref" ]]
}

# -- Colors --------------------------------------------------------------------
# Detect 256-color support; fall back to 16-color ANSI for basic terminals.
typeset -i _p_has256=0
if [[ ${TERM:-} == *256color* || ${TERM:-} == *256* ]]; then
	_p_has256=1
elif command -v tput >/dev/null 2>&1; then
	typeset _p_tput_colors
	_p_tput_colors=$(command tput colors 2>/dev/null) || _p_tput_colors=0
	(( _p_tput_colors >= 256 )) && _p_has256=1
fi

if (( _p_has256 )); then
	typeset _pr=$'\033[0m'
	typeset _pb=$'\033[38;5;4m'
	typeset _pg=$'\033[38;5;242m'
	typeset _pm=$'\033[38;5;5m'
	typeset _pred=$'\033[38;5;1m'
	typeset _pc=$'\033[38;5;6m'
	typeset _py=$'\033[38;5;3m'
else
	typeset _pr=$'\033[0m'
	typeset _pb=$'\033[34m'
	typeset _pg=$'\033[37m'
	typeset _pm=$'\033[35m'
	typeset _pred=$'\033[31m'
	typeset _pc=$'\033[36m'
	typeset _py=$'\033[33m'
fi

# -- State ---------------------------------------------------------------------
typeset -F _pstart=0 _pdur=0
typeset -i _pstat=0 _peuid=${EUID:-0}
typeset _p_host=${HOSTNAME:-}
[[ -z $_p_host ]] && _p_host=$(command hostname 2>/dev/null)
[[ -z $_p_host ]] && _p_host=$(command uname -n 2>/dev/null)
[[ -z $_p_host ]] && _p_host='localhost'

# Git state
typeset _PURE_GIT_TOPLEVEL=''
typeset _PURE_GIT_BRANCH=''
typeset _PURE_GIT_ACTION=''
typeset -i _PURE_GIT_STASH=0
typeset _PURE_GIT_STATUS=''
typeset _PURE_GIT_REMOTE=''
typeset -i _PURE_GIT_DIRTY=0

# -- Helpers -------------------------------------------------------------------
function _pure_append {
	[[ -z $2 ]] && return 0
	[[ -n $REPLY ]] && REPLY+=' '
	REPLY+="${1}${2}${_pr}"
}

# -- Git refresh ---------------------------------------------------------------
function _pure_git_refresh {
	typeset toplevel=''
	toplevel=$(command git rev-parse --show-toplevel 2>/dev/null) || {
		_PURE_GIT_TOPLEVEL=''
		_PURE_GIT_BRANCH=''
		_PURE_GIT_ACTION=''
		_PURE_GIT_STASH=0
		_PURE_GIT_STATUS=''
		_PURE_GIT_REMOTE=''
		_PURE_GIT_DIRTY=0
		return 0
	}

	if [[ "$toplevel" != "$_PURE_GIT_TOPLEVEL" ]]; then
		_PURE_GIT_TOPLEVEL=$toplevel
		_PURE_GIT_STATUS=''
		_PURE_GIT_REMOTE=''
		_PURE_GIT_DIRTY=0
		rm -f "${_PURE_CACHE_DIR}"/git_* 2>/dev/null
	fi

	# Sync: branch
	_PURE_GIT_BRANCH=$(command git symbolic-ref --short HEAD 2>/dev/null) ||
		_PURE_GIT_BRANCH=$(command git rev-parse --short HEAD 2>/dev/null)

	# Sync: action
	typeset gd
	gd=$(command git rev-parse --git-dir 2>/dev/null)
	_PURE_GIT_ACTION=''
	if [[ -d $gd/rebase-merge ]]; then
		[[ -f $gd/rebase-merge/interactive ]] && _PURE_GIT_ACTION='rebase-i' || _PURE_GIT_ACTION='rebase-m'
	elif [[ -d $gd/rebase-apply ]]; then
		[[ -f $gd/rebase-apply/rebasing ]] && _PURE_GIT_ACTION='rebase'
		[[ -f $gd/rebase-apply/applying ]] && _PURE_GIT_ACTION='am'
		[[ -z $_PURE_GIT_ACTION ]] && _PURE_GIT_ACTION='am/rebase'
	elif [[ -f $gd/MERGE_HEAD ]]; then
		_PURE_GIT_ACTION='merge'
	elif [[ -f $gd/CHERRY_PICK_HEAD ]]; then
		_PURE_GIT_ACTION='cherry-pick'
	elif [[ -f $gd/REVERT_HEAD ]]; then
		_PURE_GIT_ACTION='revert'
	elif [[ -f $gd/BISECT_LOG ]]; then
		_PURE_GIT_ACTION='bisect'
	fi

	# Sync: stash
	_PURE_GIT_STASH=$(command git rev-list --count refs/stash 2>/dev/null) || _PURE_GIT_STASH=0

	# Async: status (uses pipe trick to avoid polluting parent's job table)
	typeset status_cache="${_PURE_CACHE_DIR}/git_status"
	typeset status_pid="${_PURE_CACHE_DIR}/git_status.pid"
	typeset ttl=${PURE.git_async_ttl:-5}
	if _pure_cache_fresh "$status_cache" "$ttl"; then
		_PURE_GIT_STATUS=$(< "$status_cache")
	elif [[ -f $status_pid ]]; then
		typeset pid=$(< "$status_pid")
		if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
			:
		else
			[[ -f $status_cache ]] && _PURE_GIT_STATUS=$(< "$status_cache")
			rm -f "$status_pid"
		fi
	else
		typeset _p_pid=''
		_p_pid=$(
			(
				export GIT_OPTIONAL_LOCKS=0
				cd "$toplevel" || exit
				typeset line staged=0 modified=0 untracked=0 conflicts=0
				typeset porc
				porc=$(command git status --porcelain -unormal 2>/dev/null)
				while IFS= read -r line; do
					[[ -z $line ]] && continue
					typeset x=${line:0:1} y=${line:1:1}
					case "${x}${y}" in
						UU|AA|DD|AU|UA|DU|UD) (( conflicts++ )); continue ;;
					esac
					case $x in [MADRC]) (( staged++ )) ;; esac
					case $y in [MD]) (( modified++ )) ;; esac
					[[ $x == '?' ]] && (( untracked++ ))
				done <<< "$porc"
				typeset -i dirty=0
				(( staged + modified + untracked + conflicts > 0 )) && dirty=1
				print -r -- "${staged} ${modified} ${untracked} ${conflicts} ${dirty}" >| "$status_cache"
				rm -f "$status_pid"
			) >|"${status_cache}.out" 2>|"${status_cache}.err" &
			print -r -- $!
		)
		print -r -- ${_p_pid:-0} >| "$status_pid"
	fi

	# Async: remote (30s TTL)
	typeset remote_cache="${_PURE_CACHE_DIR}/git_remote"
	typeset remote_pid="${_PURE_CACHE_DIR}/git_remote.pid"
	if _pure_cache_fresh "$remote_cache" 30; then
		_PURE_GIT_REMOTE=$(< "$remote_cache")
	elif [[ -f $remote_pid ]]; then
		typeset pid=$(< "$remote_pid")
		if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
			:
		else
			[[ -f $remote_cache ]] && _PURE_GIT_REMOTE=$(< "$remote_cache")
			rm -f "$remote_pid"
		fi
	else
		typeset _p_pid=''
		_p_pid=$(
			(
				export GIT_OPTIONAL_LOCKS=0
				cd "$toplevel" || exit
				typeset counts
				counts=$(command git rev-list --left-right --count HEAD...@{u} 2>/dev/null) || counts=$'0\t0'
				typeset ahead=${counts%%$'\t'*}
				typeset behind=${counts##*$'\t'}
				print -r -- "${ahead} ${behind}" >| "$remote_cache"
				rm -f "$remote_pid"
			) >|"${remote_cache}.out" 2>|"${remote_cache}.err" &
			print -r -- $!
		)
		print -r -- ${_p_pid:-0} >| "$remote_pid"
	fi

	# Parse dirty flag from status
	[[ -n $_PURE_GIT_STATUS ]] && _PURE_GIT_DIRTY=${_PURE_GIT_STATUS##* }
}

# -- Segments ------------------------------------------------------------------

function _pure_jobs {
	typeset j
	j=$(jobs -p 2>/dev/null) || return 0
	[[ -z $j ]] && return 0
	typeset -a p; set -A p -- $j
	(( ${#p[@]} > 0 )) && _pure_append "$_pred" "✦${#p[@]}"
}

function _pure_uh {
	[[ -n ${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-} ]] || return 0

	if (( _peuid == 0 )); then
		[[ -n $REPLY ]] && REPLY+=' '
		REPLY+="${_pred}${USER:-root}${_pg}@${_p_host%%.*}${_pr}"
	else
		_pure_append "$_pg" "${USER:-root}@${_p_host%%.*}"
	fi
}

function _pure_dir {
	typeset d=$PWD
	[[ $d == "$HOME"* ]] && d="~${d#"$HOME"}"
	_pure_append "$_pb" "$d"
}

function _pure_git {
	[[ -z $_PURE_GIT_BRANCH ]] && return 0

	_pure_append "$_pg" "$_PURE_GIT_BRANCH"
	(( _PURE_GIT_DIRTY )) && REPLY+="${_pm}*${_pr}"

	typeset detail=''
	if [[ -n $_PURE_GIT_STATUS ]]; then
		typeset s=$_PURE_GIT_STATUS
		typeset -i staged=${s%% *}
		s=${s#* }
		typeset -i modified=${s%% *}
		s=${s#* }
		typeset -i untracked=${s%% *}
		s=${s#* }
		typeset -i conflicts=${s%% *}

		(( staged > 0 )) && detail+="+${staged}"
		(( modified > 0 )) && detail+="!${modified}"
		(( untracked > 0 )) && detail+="?${untracked}"
		(( _PURE_GIT_STASH > 0 )) && detail+='$'"${_PURE_GIT_STASH}"
		(( conflicts > 0 )) && detail+="=${conflicts}"
	fi
	[[ -n $detail ]] && _pure_append "$_pc" "$detail"

	if [[ -n $_PURE_GIT_REMOTE ]]; then
		typeset -i ahead behind
		ahead=${_PURE_GIT_REMOTE%% *}
		behind=${_PURE_GIT_REMOTE##* }
		typeset arrows=''
		(( ahead > 0 )) && arrows+="⇡${ahead}"
		(( behind > 0 )) && arrows+="⇣${behind}"
		[[ -n $arrows ]] && _pure_append "$_pc" "$arrows"
	fi

	[[ -n $_PURE_GIT_ACTION ]] && _pure_append "$_py" "$_PURE_GIT_ACTION"
}

function _pure_time {
	typeset -i t=${_pdur%.*} th=${PURE.cmd_max_exec_time:-5}
	(( t < th )) && return 0
	typeset d
	if (( t < 60 )); then
		d="${t}s"
	elif (( t < 3600 )); then
		d="$(( t / 60 ))m $(( t % 60 ))s"
	else
		d="$(( t / 3600 ))h $(( (t % 3600) / 60 ))m"
	fi
	_pure_append "$_py" "$d"
}

# -- Render --------------------------------------------------------------------
function _pure_render {
	_pdur=$(( SECONDS - _pstart ))
	REPLY=''
	_pure_jobs
	_pure_uh
	_pure_dir
	_pure_git_refresh
	_pure_git
	_pure_time

	typeset sym=${PURE.prompt_symbol:-$'\u276f'}
	typeset color
	(( _pstat == 0 )) && color=$_pm || color=$_pred

	REPLY+=$'\n'"${color}${sym}${_pr} "
}

# -- PS1 discipline ------------------------------------------------------------
typeset _pps1
function _pps1.get {
	_pstat=$?
	_pure_render
	.sh.value=${REPLY//'!'/'!!'}
	_pstart=$SECONDS
}

PS1=$'\n${_pps1}'

_PURE_INIT=1
