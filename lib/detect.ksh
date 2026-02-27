# pure.ksh/lib/detect.ksh — language/runtime version detection
#
# Auto-detects project languages from marker files and caches
# version strings with a long TTL (versions rarely change mid-session).
# Each detection runs async via defer on cache miss, result is
# read from cache on subsequent prompts.

# -- Detector table ------------------------------------------------------------
# Each entry: trigger_pattern  version_command  display_name  color_code
# Patterns are checked against files in $PWD.

typeset -a _PURE_LANG_DEFS=(
    'package.json:.nvmrc:.node-version'
    'pyproject.toml:requirements.txt:.python-version:Pipfile:setup.py'
    'Cargo.toml'
    'go.mod'
)
typeset -a _PURE_LANG_NAMES=(node py rust go)
typeset -a _PURE_LANG_COLORS=(2 3 208 6)   # green yellow orange cyan

# -- Version commands (defer-compatible) ---------------------------------------

function _pure_detect_node {
    typeset -n _r=$1
    typeset v
    v=$(command node --version 2>/dev/null) || { _r.err "node not found"; return 0; }
    _r.ok "${v#v}"
}

function _pure_detect_py {
    typeset -n _r=$1
    typeset v
    # Prefer python3, fall back to python
    v=$(command python3 --version 2>/dev/null) ||
    v=$(command python --version 2>/dev/null) || { _r.err "python not found"; return 0; }
    # "Python 3.12.1" → "3.12.1"
    _r.ok "${v##* }"
}

function _pure_detect_rust {
    typeset -n _r=$1
    typeset v
    v=$(command rustc --version 2>/dev/null) || { _r.err "rustc not found"; return 0; }
    # "rustc 1.75.0 (hash date)" → "1.75.0"
    v=${v#rustc }
    _r.ok "${v%% *}"
}

function _pure_detect_go {
    typeset -n _r=$1
    typeset v
    v=$(command go version 2>/dev/null) || { _r.err "go not found"; return 0; }
    # "go version go1.21.5 darwin/arm64" → "1.21.5"
    v=${v#go version go}
    _r.ok "${v%% *}"
}

typeset -a _PURE_LANG_FNS=(
    _pure_detect_node
    _pure_detect_py
    _pure_detect_rust
    _pure_detect_go
)

# -- Trigger detection ---------------------------------------------------------
# Checks if any trigger files exist in $PWD for a given language index.
# Returns 0 if triggered, 1 otherwise.
function _pure_lang_triggered {
    typeset -i idx=$1
    typeset triggers=${_PURE_LANG_DEFS[$idx]}
    typeset pattern

    # Split on ':' and check each pattern
    typeset IFS=':'
    for pattern in $triggers; do
        # Fast filesystem check — no fork
        [[ -f "$PWD/$pattern" ]] && return 0
    done

    return 1
}

# -- Refresh language versions -------------------------------------------------
# Called on directory change. Checks triggers, defers version detection
# for any newly-triggered languages.
function _pure_lang_refresh {
    typeset -i i n=${#_PURE_LANG_NAMES[@]}
    typeset name cache_file

    for (( i = 0; i < n; i++ )); do
        name=${_PURE_LANG_NAMES[$i]}
        cache_file="${_PURE_CACHE_DIR}/lang_${name}"

        if _pure_lang_triggered "$i"; then
            if _pure_cache_fresh "$cache_file" "${PURE.lang_async_ttl:-300}"; then
                _PURE_LANG_VERSIONS[$i]=$(< "$cache_file")
            else
                # Defer version detection to background
                defer -k "lang_${name}" "_PURE_LANG_FUT_${i}" "${_PURE_LANG_FNS[$i]}"
            fi
        else
            _PURE_LANG_VERSIONS[$i]=''
        fi
    done
}

# -- Collect completed language futures ----------------------------------------
function _pure_lang_collect {
    typeset -i i n=${#_PURE_LANG_NAMES[@]}
    typeset name
    Result_t _plc_r

    for (( i = 0; i < n; i++ )); do
        if poll "_PURE_LANG_FUT_${i}"; then
            name=${_PURE_LANG_NAMES[$i]}
            await _plc_r "_PURE_LANG_FUT_${i}"
            if _plc_r.is_ok; then
                _PURE_LANG_VERSIONS[$i]=${_plc_r.value}
                print -rn -- "${_plc_r.value}" >| "${_PURE_CACHE_DIR}/lang_${name}"
            else
                _PURE_LANG_VERSIONS[$i]=''
            fi
        fi
    done
}
