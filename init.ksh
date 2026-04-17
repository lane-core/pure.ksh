# pure.ksh — minimal pure.zsh-style prompt for ksh93
# Zero dependencies. Self-contained.

# Absorb and clear any stale DEBUG trap from previous versions.
function _pure_preexec { :; }
trap - DEBUG
unset -f _pure_preexec 2>/dev/null

[[ -n ${_PURE_INIT:-} ]] && return 0

# -- Config --------------------------------------------------------------------
typeset -C PURE=(
	cmd_max_exec_time=5
	git_async_ttl=5
	prompt_symbol=$'\u276f'
	shrink_path=0
	nerd_fonts=0
	show_exit_code=1
	show_venv=1
	show_container=1
)
typeset _pconf=${XDG_CONFIG_HOME:-$HOME/.config}/ksh/pure.ksh
[[ -f $_pconf ]] && . "$_pconf"
unset _pconf

# -- Cache ---------------------------------------------------------------------
# Isolate cache per shell session to prevent cross-shell PID races.
typeset _PURE_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ksh/pure/$$"
[[ -d $_PURE_CACHE_DIR ]] || mkdir -p "$_PURE_CACHE_DIR" 2>/dev/null

function _pure_startup_cleanup {
	typeset base="${XDG_CACHE_HOME:-$HOME/.cache}/ksh/pure"
	[[ -d $base ]] || return
	typeset d
	for d in "$base"/*; do
		[[ -d $d ]] || continue
		typeset pid=${d##*/}
		[[ $pid == +([0-9]) ]] || continue
		[[ $pid == $$ ]] && continue
		kill -0 "$pid" 2>/dev/null && continue
		rm -rf "$d"
	done
}
_pure_startup_cleanup


# Cache freshness uses a companion .ts file storing EPOCHSECONDS.
# This avoids touch -t races, stat portability issues, and extra forks.
function _pure_cache_fresh {
	typeset file=$1 ttl=${2:-5}
	[[ -f ${file}.ts ]] || return 1
	typeset -i now=${EPOCHSECONDS:-$(printf '%(%s)T')} mtime
	mtime=$(< "${file}.ts")
	(( now - mtime <= ttl ))
}

# -- Colors --------------------------------------------------------------------
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
	typeset _po=$'\033[38;5;208m'
else
	typeset _pr=$'\033[0m'
	typeset _pb=$'\033[34m'
	typeset _pg=$'\033[37m'
	typeset _pm=$'\033[35m'
	typeset _pred=$'\033[31m'
	typeset _pc=$'\033[36m'
	typeset _py=$'\033[33m'
	typeset _po=$_py
fi

# -- State ---------------------------------------------------------------------
typeset -F _pstart=0 _pdur=0
typeset -i _pstat=0 _peuid=${EUID:-0}
typeset _p_host=${HOSTNAME:-}
[[ -z $_p_host ]] && _p_host=$(command hostname 2>/dev/null)
[[ -z $_p_host ]] && _p_host=$(command uname -n 2>/dev/null)
[[ -z $_p_host ]] && _p_host='localhost'

# Prompt symbol state propagated to PS2
typeset _PURE_PROMPT_SYM=''
typeset _PURE_PROMPT_COLOR=''

# Directory memoization for git toplevel
typeset _PURE_LAST_PWD=''

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

	# Memoize toplevel only while still in the exact same directory.
	if [[ $PWD == "${_PURE_LAST_PWD:-}" && -n $_PURE_GIT_TOPLEVEL ]]; then
		toplevel=$_PURE_GIT_TOPLEVEL
	else
		_PURE_LAST_PWD=$PWD
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
	fi

	if [[ "$toplevel" != "$_PURE_GIT_TOPLEVEL" ]]; then
		_PURE_GIT_TOPLEVEL=$toplevel
		_PURE_GIT_STATUS=''
		_PURE_GIT_REMOTE=''
		_PURE_GIT_DIRTY=0
		rm -f "${_PURE_CACHE_DIR}"/git_* 2>/dev/null
	fi

	# Sync: branch (prefer tag name in detached HEAD)
	_PURE_GIT_BRANCH=$(command git symbolic-ref --short HEAD 2>/dev/null) || {
		typeset tag=''
		tag=$(command git describe --tags --exact-match 2>/dev/null)
		if [[ -n $tag ]]; then
			_PURE_GIT_BRANCH=$tag
		else
			_PURE_GIT_BRANCH=$(command git rev-parse --short HEAD 2>/dev/null)
		fi
	}

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

	# Async: status
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
				cd "$toplevel" && {
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
					print -rn -- "$EPOCHSECONDS" >| "${status_cache}.ts"
				}
				rm -f "$status_pid"
			) >/dev/null 2>&1 &
			print -r -- $!
		)
		if [[ $_p_pid == +([0-9]) ]] && (( _p_pid > 0 )); then
			print -r -- "$_p_pid" >| "$status_pid"
		fi
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
				cd "$toplevel" && {
					typeset counts
					counts=$(command git rev-list --left-right --count HEAD...@{u} 2>/dev/null) || counts=$'0\t0'
					typeset ahead=${counts%%$'\t'*}
					typeset behind=${counts##*$'\t'}
					print -r -- "${ahead} ${behind}" >| "$remote_cache"
					print -rn -- "$EPOCHSECONDS" >| "${remote_cache}.ts"
				}
				rm -f "$remote_pid"
			) >/dev/null 2>&1 &
			print -r -- $!
		)
		if [[ $_p_pid == +([0-9]) ]] && (( _p_pid > 0 )); then
			print -r -- "$_p_pid" >| "$remote_pid"
		fi
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

function _pure_shlvl {
	typeset -i lvl=${SHLVL:-1}
	(( lvl > 1 )) && _pure_append "$_pg" "↑${lvl}"
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

function _pure_venv {
	[[ ${PURE.show_venv:-0} == @(1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) ]] || return 0
	typeset v=''
	if [[ -n ${VIRTUAL_ENV:-} ]]; then
		v=${VIRTUAL_ENV##*/}
	elif [[ -n ${CONDA_DEFAULT_ENV:-} ]]; then
		v=$CONDA_DEFAULT_ENV
	elif [[ -n ${NIX_SHELL:-} ]]; then
		v='nix-shell'
	fi
	[[ -n $v ]] && _pure_append "$_pc" "$v"
}

function _pure_container {
	[[ ${PURE.show_container:-0} == @(1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) ]] || return 0
	typeset c=''
	if [[ -f /run/.containerenv ]]; then
		c='toolbox'
	elif [[ -f /.dockerenv ]]; then
		c='docker'
	elif [[ -n ${container:-} ]]; then
		c=$container
	elif [[ -n ${TOOLBOX_PATH:-} ]]; then
		c='toolbox'
	fi
	[[ -n $c ]] && _pure_append "$_pc" "⬢ $c"
}

function _pure_dir {
	typeset d=$PWD
	[[ $d == "$HOME"* ]] && d="~${d#"$HOME"}"

	if [[ ${PURE.shrink_path:-0} == @(1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) ]] && (( ${#d} > 30 )) && [[ $d != '/' ]]; then
		typeset out='' part leading=''
		typeset -a segs
		# Strip leading / before splitting to avoid empty first element.
		[[ ${d:0:1} == / ]] && leading='/' && d=${d:1}
		IFS=/ set -A segs -- $d
		typeset -i i=0 n=${#segs[@]}

		while (( i < n )); do
			part=${segs[i]}
			if (( i > 0 && i < n - 1 )) && [[ -n $part ]]; then
				if [[ $part == .* ]]; then
					out+="/.${part:1:1}"
				else
					out+="/${part:0:1}"
				fi
			else
				out+="/$part"
			fi
			(( i++ ))
		done
		d="${leading}${out}"
	fi

	_pure_append "$_pb" "$d"
}

function _pure_git {
	[[ -z $_PURE_GIT_BRANCH ]] && return 0

	typeset branch_sym=''
	[[ ${PURE.nerd_fonts:-0} == @(1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) ]] && branch_sym=$'\ue0a0 '
	_pure_append "$_pg" "${branch_sym}${_PURE_GIT_BRANCH}"

	typeset dirty_sym='*'
	[[ ${PURE.nerd_fonts:-0} == @(1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) ]] && dirty_sym=$'\u271a'
	(( _PURE_GIT_DIRTY )) && REPLY+="${_pm}${dirty_sym}${_pr}"

	typeset detail=''
	if [[ -n $_PURE_GIT_STATUS ]]; then
		typeset -a gs
		set -A gs -- $_PURE_GIT_STATUS
		typeset -i staged=${gs[0]:-0} modified=${gs[1]:-0} untracked=${gs[2]:-0} conflicts=${gs[3]:-0}

		(( staged > 0 )) && detail+="+${staged}"
		(( modified > 0 )) && detail+="!${modified}"
		(( untracked > 0 )) && detail+="?${untracked}"
		(( _PURE_GIT_STASH > 0 )) && detail+='$'"${_PURE_GIT_STASH}"
		(( conflicts > 0 )) && detail+="=${conflicts}"
	fi
	[[ -n $detail ]] && _pure_append "$_pc" "$detail"

	if [[ -n $_PURE_GIT_REMOTE ]]; then
		typeset -i ahead behind
		typeset arrows=''
		ahead=${_PURE_GIT_REMOTE%% *}
		behind=${_PURE_GIT_REMOTE##* }
		(( ahead > 0 )) && arrows+="⇡${ahead}"
		(( behind > 0 )) && arrows+="⇣${behind}"
		[[ -n $arrows ]] && _pure_append "$_pc" "$arrows"
	fi

	[[ -n $_PURE_GIT_ACTION ]] && _pure_append "$_py" "$_PURE_GIT_ACTION"
}

function _pure_time {
	typeset -i t=${_pdur%.*} th=${PURE.cmd_max_exec_time:-5}
	(( t < th )) && return 0

	typeset d='' color
	typeset -i h m s
	(( h = t / 3600 ))
	(( m = (t % 3600) / 60 ))
	(( s = t % 60 ))
	(( h > 0 )) && d+="${h}h "
	(( m > 0 )) && d+="${m}m "
	(( s > 0 )) && d+="${s}s"
	d=${d% }

	if (( t < 30 )); then
		color=$_py
	elif (( t < 120 )); then
		color=$_po
	else
		color=$_pred
	fi
	_pure_append "$color" "$d"
}

function _pure_exit {
	(( _pstat == 0 )) && return 0
	[[ ${PURE.show_exit_code:-0} == @(1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]) ]] || return 0
	_pure_append "$_pred" "✘ ${_pstat}"
}

# -- Render --------------------------------------------------------------------
function _pure_render {
	((_pdur = SECONDS - _pstart))
	REPLY=''
	_pure_jobs
	_pure_shlvl
	_pure_uh
	_pure_venv
	_pure_container
	_pure_dir
	_pure_git_refresh
	_pure_git
	_pure_time
	_pure_exit

	if (( _pstat == 0 )); then
		_PURE_PROMPT_SYM=${PURE.prompt_symbol:-$'\u276f'}
		_PURE_PROMPT_COLOR=$_pm
	else
		_PURE_PROMPT_SYM='✘'
		_PURE_PROMPT_COLOR=$_pred
	fi

	REPLY+=$'\n'"${_PURE_PROMPT_COLOR}${_PURE_PROMPT_SYM}${_pr} "
}

# -- PS1 discipline ------------------------------------------------------------
typeset _pps1
function _pps1.get {
	_pstat=$?
	_pure_render
	typeset _escaped
	_escaped=${REPLY//'\'/'\\'}
	_escaped=${_escaped//'!'/'!!'}
	.sh.value=$_escaped
	_pstart=$SECONDS
	PS2="${_PURE_PROMPT_COLOR}${_PURE_PROMPT_SYM}${_pr} "
}

PS1=$'\n${_pps1}'

_PURE_INIT=1
