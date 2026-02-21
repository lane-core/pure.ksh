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
    typeset file=$1
    typeset -i ttl=$2

    [[ -f $file ]] || return 1

    # Get file age via ksh93's stat-like test
    # We compare file mtime against current SECONDS offset
    # Since SECONDS is a float timer, we use a cached birth time
    typeset -i now=${EPOCHSECONDS:-$(printf '%(%s)T')}
    typeset -i mtime

    # ksh93u+m: use printf for epoch time of file
    # Portable fallback: stat
    if mtime=$(command stat -f '%m' "$file" 2>/dev/null) ||
       mtime=$(command stat -c '%Y' "$file" 2>/dev/null); then
        (( now - mtime < ttl )) && return 0
    fi

    return 1
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
