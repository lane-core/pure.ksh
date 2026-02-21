# pure.ksh/lib/cache.ksh — file-backed TTL cache
#
# Provides _pure_cache_fresh, which checks whether a cache file
# exists and is younger than a given TTL. This is the !A exponential
# at the application layer: a result can be read multiple times until
# the TTL expires, at which point it must be recomputed (re-deferred).

# Check if a cache file is fresh (within TTL)
# $1 = cache file path
# $2 = TTL in seconds
# Returns 0 if fresh, 1 if stale or missing
function _pure_cache_fresh {
    typeset file=${1:-}
    typeset -i ttl=${2:-0}

    [[ -n $file && -f $file ]] || return 1

    # Compare file mtime against a reference file aged $ttl seconds.
    # Avoids stat(1) entirely — ksh93u+m has a stat builtin whose
    # named parameters trigger spurious nounset errors when invoked
    # via `command stat -f ...` (command doesn't bypass builtins).
    # Instead: printf %(...)T (builtin) + touch -t (POSIX) + [[ -nt ]]
    typeset -i now=${EPOCHSECONDS:-$(printf '%(%s)T')}
    typeset -i threshold=$(( now - ttl ))
    typeset ts
    ts=$(printf '%(%Y%m%d%H%M.%S)T' "#$threshold")
    typeset ref="${_PURE_CACHE_DIR:-/tmp}/.ttl_ref"

    touch -t "$ts" "$ref" 2>/dev/null || return 1
    [[ "$file" -nt "$ref" ]]
}

# Initialize cache directory
function _pure_cache_init {
    _PURE_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ksh/pure"
    [[ -d $_PURE_CACHE_DIR ]] || mkdir -p "$_PURE_CACHE_DIR" 2>/dev/null
}

# Clear all cached data (e.g., on explicit user request)
function _pure_cache_clear {
    [[ -d ${_PURE_CACHE_DIR:-} ]] && rm -f "${_PURE_CACHE_DIR}"/* 2>/dev/null
}
