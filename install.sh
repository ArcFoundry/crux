#!/usr/bin/env bash
# ==============================================================================
# crux v5.1.0 — Zero-Daemon Multi-Harness Continuity & Verification Layer
# Compatible with: macOS (Bash 3.2+) & Linux (WSL2, Ubuntu, Debian, Arch, Fedora)
# Enforced Harnesses: Claude Code, Qoder, ZCode, OpenCode (v1 & v2), Google Antigravity (agy)
# Rules-Only Harnesses: DeepSeek Harness (dsh), MiniMax Code (mcode), Codex
# Hard deps: bash (3.2+), git, awk, grep, sed, find, cksum, tar, jq, make, mktemp
# Optional deps: timeout / gtimeout (reaped Bash watchdog fallback if absent)
# Footprint: 0 MB background RAM | 0 independent LLM API calls
# ==============================================================================
unset BASH_ENV
set -euo pipefail

CRUX_VERSION="5.1.0"
CLI_NAME="crux"
STATE_DIR=".crux"
HUB_DIR="${CRUX_HOME:-${HOME}/.crux-hub}"
BIN_DIR="${CRUX_BIN:-${HOME}/.local/bin}"
INSTALL_MODE=""
LOCAL_ONLY="false"

usage() {
    echo "Usage: bash install.sh [--local] [--manual|--auto] [--name NAME]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --local)  LOCAL_ONLY="true" ;;
        --auto)   INSTALL_MODE="auto" ;;
        --manual) INSTALL_MODE="manual" ;;
        --name)
            shift
            [ $# -gt 0 ] || { echo "ERROR: --name requires a value."; exit 1; }
            CLI_NAME="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown flag: $1"; usage; exit 1 ;;
    esac
    shift
done

case "${CLI_NAME}" in
    ""|*[!A-Za-z0-9._-]*|.|..)
        echo "ERROR: Invalid CLI name '${CLI_NAME}'."
        exit 1
        ;;
esac

for c in git awk grep sed find cksum tar jq make mktemp; do
    command -v "$c" >/dev/null 2>&1 || {
        echo "ERROR: required tool '$c' not found. Install '$c' first (e.g., brew install $c / apt install $c)."
        exit 1
    }
done

# True isolation for --local: keep hub & binary inside <repo>/.crux/local/ (zero global touches)
if [ "${LOCAL_ONLY}" = "true" ]; then
    REPO_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "${REPO_TOP}" ] || { echo "ERROR: --local requires running inside a Git repository."; exit 1; }
    REPO_TOP="$(cd "${REPO_TOP}" && pwd -P)"
    HUB_DIR="${REPO_TOP}/${STATE_DIR}/local/hub"
    BIN_DIR="${REPO_TOP}/${STATE_DIR}/local/bin"
fi

# Collision guard: check both PATH and exact destination
DEST_BIN="${BIN_DIR}/${CLI_NAME}"
if [ -L "${DEST_BIN}" ]; then
    echo "ERROR: Refusing to overwrite symlink at ${DEST_BIN}."
    exit 1
fi
if [ -e "${DEST_BIN}" ] && ! grep -qF '# CRUX-CLI-MARKER ' "${DEST_BIN}" 2>/dev/null; then
    echo "ERROR: '${DEST_BIN}' already exists and is not owned by crux. Use --name <other>."
    exit 1
fi
if [ "${LOCAL_ONLY}" = "false" ]; then
    EXISTING="$(command -v "${CLI_NAME}" 2>/dev/null || true)"
    if [ -n "${EXISTING}" ] && [ "${EXISTING}" != "${DEST_BIN}" ]; then
        if ! grep -qF '# CRUX-CLI-MARKER ' "${EXISTING}" 2>/dev/null; then
            echo "ERROR: '${CLI_NAME}' already exists on PATH at ${EXISTING} and is not ours. Use --name <other>."
            exit 1
        fi
    fi
fi

mkdir -p "${HUB_DIR}/hooks" "${HUB_DIR}/backups" "${HUB_DIR}/purge-backups" "${HUB_DIR}/trust" "${BIN_DIR}"
touch "${HUB_DIR}/exempt.list" "${HUB_DIR}/auto_roots.list"
echo "${CRUX_VERSION}" > "${HUB_DIR}/VERSION"
echo "${LOCAL_ONLY}" > "${HUB_DIR}/install_scope"

# ------------------------------------------------------------------------------
# 1. Interactive or Flagged Mode Selection (Preserves Choice on Upgrades)
# ------------------------------------------------------------------------------
if [ "${LOCAL_ONLY}" = "true" ] && [ -z "${INSTALL_MODE}" ]; then
    AUTO_INIT_DEFAULT="false"
elif [ -z "${INSTALL_MODE}" ] && [ -f "${HUB_DIR}/auto_init.conf" ]; then
    AUTO_INIT_DEFAULT="$(cat "${HUB_DIR}/auto_init.conf" 2>/dev/null || echo "false")"
elif [ "${INSTALL_MODE}" = "auto" ]; then
    AUTO_INIT_DEFAULT="true"
elif [ "${INSTALL_MODE}" = "manual" ]; then
    AUTO_INIT_DEFAULT="false"
else
    AUTO_INIT_DEFAULT="false"
    TTY_FD=""
    if [ -t 0 ]; then TTY_FD="0"; elif { exec 3</dev/tty; } 2>/dev/null; then TTY_FD="3"; fi
    if [ -n "${TTY_FD}" ]; then
        cat <<BANNER
==============================================================================
 ${CLI_NAME} v${CRUX_VERSION} Installer — Default Initialization Mode
------------------------------------------------------------------------------
  [1] Manual Mode (Default) — Only active where you run '${CLI_NAME} init'
  [2] Global Auto-Init Mode — Auto-scaffolds .crux/ on first turn in Git repos
      (Switch anytime with '${CLI_NAME} mode manual|auto'; exempt with '${CLI_NAME} exempt')
==============================================================================
BANNER
        printf "Select mode [1/2] (default: 1): "
        read -r CHOICE <&"${TTY_FD}" || CHOICE="1"
        [ "${CHOICE:-1}" = "2" ] && AUTO_INIT_DEFAULT="true"
    fi
fi
echo "${AUTO_INIT_DEFAULT}" > "${HUB_DIR}/auto_init.conf"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SRC_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    DST_REAL="${HUB_DIR}/install.sh"
    if [ "${SRC_REAL}" != "${DST_REAL}" ]; then
        cp "${SRC_REAL}" "${DST_REAL}" 2>/dev/null || true
        chmod +x "${DST_REAL}" 2>/dev/null || true
    fi
fi

# Safe template escaping helpers (no sed & / | corruption)
sed_escape() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }
shell_quote() { printf '%q' "$1"; }

# ------------------------------------------------------------------------------
# 2. Global Home Layer Sync (~/.zcode/AGENTS.md, ~/.qoder/AGENTS.md, etc.)
#    Safe replacement: requires BOTH begin and end markers; preserves first backup.
# ------------------------------------------------------------------------------
BUILDER_SOUL='<!-- crux:soul:begin -->
## Project Continuity & Contract (.crux/)
When `.crux/PLAN.md` exists in the current repository or workspace:
1. Read `.crux/INDEX.md`, `.crux/PLAN.md`, `.crux/PROGRESS.md`, and `.crux/PROJECT_STATE.md` at session start so you know the active plan, completed tasks (`.crux/PROGRESS.md` is append-only and never rotates), native wiki locations (check `[STALE]` warnings in `INDEX.md` — trust live code over stale wikis), and recent build receipts.
2. Never re-implement tasks already marked `- [x]` in `.crux/PROGRESS.md`. Use all of your native capabilities (subagents, internal planning, RepoWiki, and tools) at full strength on the next unchecked task in `.crux/PLAN.md`.
3. `.crux/PLAN.md` is read-only to agents (human updates via `crux plan` or direct editor); if code reality contradicts `.crux/PLAN.md`, log the conflict in `.crux/PROPOSALS.md` and stop rather than altering `.crux/PLAN.md`.
4. Run `make agent-verify` before claiming completion, and append one line to `.crux/PROGRESS.md` (`- [x] <TaskID> | <short-sha> | <harness> | <YYYY-MM-DD> | <1-line summary>`).
<!-- crux:soul:end -->'

sync_global_soul() {
    local target="$1" dir bak tmp
    dir="$(dirname "$target")"
    mkdir -p "$dir" 2>/dev/null || { echo "WARN: cannot create $dir; skipped $target" >&2; return 0; }
    if [ -f "$target" ]; then
        bak="${HUB_DIR}/backups/$(basename "$dir")-$(basename "$target").orig.bak"
        [ -f "$bak" ] || cp "$target" "$bak" 2>/dev/null || true
        if grep -q "crux:soul:begin" "$target" 2>/dev/null; then
            if ! grep -q "crux:soul:end" "$target" 2>/dev/null; then
                echo "WARN: $target has crux:soul:begin without crux:soul:end; refusing to modify." >&2
                return 0
            fi
            tmp="$(mktemp "${target}.XXXXXX" 2>/dev/null || true)"
            [ -n "$tmp" ] || { echo "WARN: cannot write to $dir; skipped $target" >&2; return 0; }
            SOUL="$BUILDER_SOUL" awk '
                /crux:soul:begin/ { print ENVIRON["SOUL"]; skip=1; next }
                /crux:soul:end/   { skip=0; next }
                !skip { print }
            ' "$target" > "$tmp" && mv -f "$tmp" "$target" || { rm -f "$tmp"; return 0; }
        else
            printf '\n%s\n' "$BUILDER_SOUL" >> "$target" 2>/dev/null || echo "WARN: cannot append to $target" >&2
        fi
    else
        printf '%s\n' "$BUILDER_SOUL" > "$target" 2>/dev/null || echo "WARN: cannot write $target" >&2
    fi
}

if [ "${LOCAL_ONLY}" = "false" ]; then
    { [ -d "${HOME}/.zcode" ]    || command -v zcode >/dev/null 2>&1; }    && sync_global_soul "${HOME}/.zcode/AGENTS.md"
    { [ -d "${HOME}/.qoder" ]    || command -v qoder >/dev/null 2>&1; }    && sync_global_soul "${HOME}/.qoder/AGENTS.md"
    { [ -d "${HOME}/.claude" ]   || command -v claude >/dev/null 2>&1; }   && sync_global_soul "${HOME}/.claude/CLAUDE.md"
    { [ -d "${HOME}/.gemini" ]   || command -v antigravity >/dev/null 2>&1 || command -v agy >/dev/null 2>&1 || command -v gemini >/dev/null 2>&1; } && sync_global_soul "${HOME}/.gemini/GEMINI.md"
    { [ -d "${HOME}/.config/opencode" ] || command -v opencode >/dev/null 2>&1; } && sync_global_soul "${HOME}/.config/opencode/AGENTS.md"
    { [ -d "${HOME}/.dsh" ]      || command -v dsh >/dev/null 2>&1; }      && sync_global_soul "${HOME}/.dsh/AGENTS.md"
    { [ -d "${HOME}/.codex" ]    || command -v codex >/dev/null 2>&1; }    && sync_global_soul "${HOME}/.codex/AGENTS.md"
    { [ -d "${HOME}/.minimax" ]  || [ -d "${HOME}/.minimax-code" ] || command -v mcode >/dev/null 2>&1; } && sync_global_soul "${HOME}/.minimax/AGENTS.md"
fi

# ------------------------------------------------------------------------------
# 3. Concurrency-Safe Hook Engine (`<HUB_DIR>/hooks/on_event.sh`)
#    Supports: Claude/Qoder/ZCode (exit 2), OpenCode (--observer), Antigravity (--agy JSON)
# ------------------------------------------------------------------------------
HOOK_TMPL="$(mktemp "${HUB_DIR}/hooks/on_event.tmpl.XXXXXX")"
cat <<'HOOK_EOF' > "${HOOK_TMPL}"
#!/usr/bin/env bash
# @@NAME@@ Hook Engine v@@VERSION@@ — Zero-Daemon Event Handler (Bash 3.2+ / macOS + Linux)
unset BASH_ENV
set -u
set -f
export GIT_OPTIONAL_LOCKS=0
PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"

HUB_DIR=@@HUB@@
BIN_DIR=@@BIN@@
NAME=@@NAME@@
SDIR=".crux"
[ "${CRUX_DISABLE:-0}" = "1" ] && exit 0

EVENT=""
KIND=""
AGY_MODE=0
OBSERVER_MODE=0
MANUAL_MODE=0
HARNESS="unknown"
for arg in "$@"; do
    case "$arg" in
        --agy)           AGY_MODE=1; HARNESS="agy" ;;
        --observer)      OBSERVER_MODE=1 ;;
        --manual-verify) MANUAL_MODE=1; HARNESS="manual" ;;
        --harness=*)     HARNESS="${arg#--harness=}" ;;
        *)               [ -z "$EVENT" ] && EVENT="$arg" ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
if ! have jq; then
    if [ "$AGY_MODE" = 1 ]; then
        printf '{"decision":"deny","reason":"crux requires jq on PATH"}\n'
        exit 0
    fi
    printf 'ERROR [%s]: jq is required on PATH.\n' "$NAME" >&2
    exit 2
fi

sha() {
    local h
    if have sha256sum; then h="$(sha256sum)" || return 1
    elif have shasum; then h="$(shasum -a 256)" || return 1
    else h="$(git hash-object --stdin)" || return 1; fi
    printf '%s\n' "${h%% *}"
}

TIMEOUT_BIN=""
if have timeout; then TIMEOUT_BIN="timeout"; elif have gtimeout; then TIMEOUT_BIN="gtimeout"; fi

run_timeout() {
    local secs="$1"; shift
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" -k 5 "$secs" "$@"
        return $?
    fi
    # Portable Bash 3.2 watchdog fallback (reaped immediately on early completion)
    local pid rc watch=""
    "$@" &
    pid=$!
    (
        i=0
        while [ "$i" -lt "$secs" ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 3
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) >/dev/null 2>&1 &
    watch=$!
    wait "$pid"
    rc=$?
    if [ -n "$watch" ]; then
        kill "$watch" 2>/dev/null || true
        wait "$watch" 2>/dev/null || true
    fi
    case "$rc" in 137|143) rc=124 ;; esac
    return "$rc"
}

json_str() { printf '%s' "$1" | jq -Rs .; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

allow_out() {
    if [ "$AGY_MODE" = 1 ]; then
        case "${KIND:-}" in
            pre|stop) printf '{"decision":"allow"}\n' ;;
            *)        printf '{}\n' ;;
        esac
    fi
    exit 0
}
block() {
    if [ "$AGY_MODE" = 1 ]; then
        printf '{"decision":"deny","reason":%s}\n' "$(json_str "$*")"
        exit 0
    fi
    printf '%s\n' "$*" >&2
    exit 2
}
stop_continue() {
    if [ "$AGY_MODE" = 1 ]; then
        printf '{"decision":"continue","reason":%s}\n' "$(json_str "$*")"
        exit 0
    fi
    printf '%s\n' "$*" >&2
    exit 2
}

PAYLOAD=""
if [ ! -t 0 ]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
fi

jget() {
    printf '%s' "$PAYLOAD" | jq -r --arg k "$1" '(.[$k] // empty) | select(type == "string")' 2>/dev/null | head -n1
}

[ -z "$EVENT" ] && EVENT="${CLAUDE_HOOK_EVENT:-${HOOK_EVENT_NAME:-}}"
[ -z "$EVENT" ] && EVENT="$(jget hook_event_name)"
[ -z "$EVENT" ] && EVENT="$(jget hookEventName)"

case "$EVENT" in
    SessionStart|pre_llm_call)                     KIND="start" ;;
    PreToolUse|pre_tool_call)                      KIND="pre" ;;
    PostToolUse|PostToolUseFailure|post_tool_call) KIND="post" ;;
    Stop|pre_verify)                               KIND="stop" ;;
    SessionEnd)                                    KIND="end" ;;
    *) allow_out ;;
esac

HCWD="$(jget cwd)"
[ -z "$HCWD" ] && HCWD="$(printf '%s' "$PAYLOAD" | jq -r '(.workspacePaths[0] // empty) | select(type == "string")' 2>/dev/null | head -n1)"
if [ -n "$HCWD" ] && [ -d "$HCWD" ]; then cd "$HCWD" 2>/dev/null || true; fi
CWD0="$(pwd -P 2>/dev/null || pwd)"

TOOL_CWD="$(printf '%s' "$PAYLOAD" | jq -r '(.toolCall.args.Cwd // .tool_input.workdir // .toolInput.workdir // .input.workdir // empty) | select(type == "string")' 2>/dev/null | head -n1)"
[ -n "$TOOL_CWD" ] || TOOL_CWD="$CWD0"
TOOL_CWD="${TOOL_CWD//\\//}"
case "$TOOL_CWD" in /*) ;; *) TOOL_CWD="$CWD0/$TOOL_CWD" ;; esac
TOOL_CWD="$(cd "$TOOL_CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD0")"

# ---- Resolve active .crux/ root (nested submodules inherit nearest ancestor; linked worktrees keep boundary) ----
ROOT=""; EXD=""
GIT_TOP="$(git -C "$CWD0" rev-parse --show-toplevel 2>/dev/null || true)"
NESTED_OK=0
if [ -n "$GIT_TOP" ]; then
    GIT_TOP="$(cd "$GIT_TOP" && pwd -P)"
    [ -f "$GIT_TOP/$SDIR/PROJECT_STATE.md" ] && ROOT="$GIT_TOP"
    if [ -f "$GIT_TOP/$SDIR/.exempt" ] || [ -f "$GIT_TOP/.crux-ignore" ]; then EXD="$GIT_TOP"; fi
    [ "$(git -C "$GIT_TOP" rev-parse --git-dir 2>/dev/null)" = "$(git -C "$GIT_TOP" rev-parse --git-common-dir 2>/dev/null)" ] && NESTED_OK=1
fi
if [ -z "$ROOT" ]; then
    d="$CWD0"
    while [ -n "$d" ]; do
        [ -z "$ROOT" ] && [ -f "$d/$SDIR/PROJECT_STATE.md" ] && {
            if [ -z "$GIT_TOP" ] || [ "$d" = "$GIT_TOP" ] || [ "$NESTED_OK" = 1 ] || [ -f "$d/$SDIR/WORKSPACE" ]; then
                ROOT="$d"
            fi
        }
        if [ -z "$EXD" ]; then
            if [ -f "$d/$SDIR/.exempt" ] || [ -f "$d/.crux-ignore" ]; then EXD="$d"; fi
        fi
        [ "$d" = "/" ] && break
        d="${d%/*}"; [ -z "$d" ] && d="/"
    done
fi
if [ -s "$HUB_DIR/exempt.list" ]; then
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        case "$CWD0/" in "${e%/}"/*) if [ -z "$EXD" ] || [ "${#e}" -gt "${#EXD}" ]; then EXD="$e"; fi ;; esac
    done < "$HUB_DIR/exempt.list"
fi
if [ -n "$EXD" ]; then
    if [ -z "$ROOT" ] || [ "${#ROOT}" -le "${#EXD}" ]; then allow_out; fi
fi

auto_allowed() {
    local top="$1" roots r found=0
    [ "$(cat "$HUB_DIR/auto_init.conf" 2>/dev/null || echo false)" = "true" ] || return 1
    [ "$top" = "$HOME" ] && return 1
    case "$top/" in "$HUB_DIR"/*|"$HOME/Downloads"/*|"$HOME/Desktop"/*) return 1 ;; esac
    roots="$(grep -v '^[[:space:]]*$' "$HUB_DIR/auto_roots.list" 2>/dev/null || true)"
    if [ -z "$roots" ]; then case "$top/" in "$HOME"/*) return 0 ;; esac; return 1; fi
    while IFS= read -r r; do case "$top/" in "${r%/}"/*) found=1 ;; esac; done <<EOF_R
$roots
EOF_R
    [ "$found" = 1 ]
}

CLI="$BIN_DIR/$NAME"
if [ -z "$ROOT" ]; then
    case "$KIND" in start|pre) ;; *) allow_out ;; esac
    [ -z "$GIT_TOP" ] && allow_out
    auto_allowed "$GIT_TOP" || allow_out
    [ -x "$CLI" ] && ( cd "$GIT_TOP" && "$CLI" init --silent ) >/dev/null 2>&1
    [ -f "$GIT_TOP/$SDIR/PROJECT_STATE.md" ] && ROOT="$GIT_TOP"
    [ -z "$ROOT" ] && allow_out
fi

# Prevent global hook from colliding with an actively wired --local repo installation
OWNER_FILE="$ROOT/$SDIR/local/bridge-owner"
if [ -f "$OWNER_FILE" ]; then
    OWNER_HUB="$(cat "$OWNER_FILE" 2>/dev/null || true)"
    [ -z "$OWNER_HUB" ] || [ "$OWNER_HUB" = "$HUB_DIR" ] || allow_out
fi

cd "$ROOT" || allow_out
STATE_FILE="$ROOT/$SDIR/PROJECT_STATE.md"
ARCHIVE_FILE="$ROOT/$SDIR/archive/PROJECT_STATE_ARCHIVE.md"
LOCAL_DIR="$ROOT/$SDIR/local"
SLOTS_DIR="$LOCAL_DIR/slots"
CKPT_FILE="$LOCAL_DIR/checkpoint.txt"
NOW="$(date '+%Y-%m-%d %H:%M')"
mkdir -p "$SLOTS_DIR" "$ROOT/$SDIR/archive" 2>/dev/null || allow_out

# Collision-resistant, branch-independent session slot ID
SID="$(jget session_id)"
[ -z "$SID" ] && SID="$(jget sessionId)"
[ -z "$SID" ] && SID="$(jget conversationId)"
[ -z "$SID" ] && SID="${CRUX_AGENT_ID:-shared}"
SLOT_HASH="$(printf '%s\0%s\0' "$HARNESS" "$SID" | sha | cut -c1-12)"
AGENT_SLOT="$(printf '%s-%s' "$HARNESS" "$SLOT_HASH" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)"
LOOP_FILE="$LOCAL_DIR/loop-$AGENT_SLOT.txt"
SLOT_FILE="$SLOTS_DIR/$AGENT_SLOT.status"
FAIL_FILE="$LOCAL_DIR/fail-$AGENT_SLOT"
STATE_LOCK="$LOCAL_DIR/state.lock"
VERIFY_LOCK="$LOCAL_DIR/verify.lock"
SLOT_TTL_SEC="${CRUX_SLOT_TTL_SEC:-600}"

# ---- Bash 3.2 Safe Locks (Array-backed for spaces in paths; $SECONDS PID-less recovery) ----
HELD_LOCKS=()
nap() { sleep "$1" 2>/dev/null || sleep 1; }
acquire_lock() {
    local dir="$1" tries="${2:-150}" nz="${3:-0.02}" owner t0="$SECONDS"
    while ! mkdir "$dir" 2>/dev/null; do
        owner="$(cat "$dir/pid" 2>/dev/null || true)"
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$dir" 2>/dev/null || true
            continue
        fi
        if [ -z "$owner" ] && [ $((SECONDS - t0)) -ge 2 ]; then
            rm -rf "$dir" 2>/dev/null || true
            continue
        fi
        tries=$((tries - 1))
        [ "$tries" -le 0 ] && return 1
        nap "$nz"
    done
    printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || { rmdir "$dir" 2>/dev/null || true; return 1; }
    HELD_LOCKS[${#HELD_LOCKS[@]}]="$dir"
    return 0
}
release_lock() {
    if [ "$(cat "$1/pid" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$1/pid" 2>/dev/null || true
        rmdir "$1" 2>/dev/null || rm -rf "$1" 2>/dev/null || true
    fi
}
release_all() {
    local x
    for x in ${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}; do
        release_lock "$x"
    done
}
trap release_all EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

atomic_copy() {
    local src="$1" dst="$2" tmp
    tmp="$(mktemp "${dst}.XXXXXX")" || return 1
    if cp "$src" "$tmp" && mv -f "$tmp" "$dst"; then return 0; fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}
atomic_text() {
    local dst="$1" tmp; shift
    tmp="$(mktemp "${dst}.XXXXXX")" || return 1
    if printf '%s\n' "$*" > "$tmp" && mv -f "$tmp" "$dst"; then return 0; fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

is_git() { git -C "$ROOT/$1" rev-parse --git-dir >/dev/null 2>&1; }
members() {
    local m found=0
    if [ -f "$ROOT/$SDIR/WORKSPACE" ]; then
        while IFS= read -r m; do
            case "$m" in ""|\#*) continue ;; esac
            is_git "$m" || continue
            printf '%s\n' "$m"
            found=1
        done < "$ROOT/$SDIR/WORKSPACE"
    fi
    [ "$found" = 1 ] || printf '.\n'
}
active_agents() {
    local f t now n=0
    now="$(date +%s)"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        t="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
        [ $((now - ${t:-0})) -le "$SLOT_TTL_SEC" ] && n=$((n + 1))
    done < <(find "$SLOTS_DIR" -type f -name '*.status' 2>/dev/null)
    echo "$n"
}
set_ckpt() {
    atomic_text "$CKPT_FILE" "[In-Flight Checkpoint]: $NOW $1" 2>/dev/null || true
}
touched_list() {
    local m pre line
    while IFS= read -r m; do
        [ -z "$m" ] && continue; is_git "$m" || continue
        pre=""; [ "$m" != "." ] && pre="$m/"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            printf '%s%s\n' "$pre" "${line#???}"
        done < <(git -C "$ROOT/$m" -c core.fsmonitor=false status --porcelain -- . ":(exclude)$SDIR" 2>/dev/null)
    done < <(members) | head -n "${1:-12}" | tr '\n' ' ' | sed 's/ *$//'
}
diff_stat() {
    local m out="" s
    while IFS= read -r m; do
        [ -z "$m" ] && continue; is_git "$m" || continue
        s="$(git -C "$ROOT/$m" -c core.fsmonitor=false diff --no-textconv --no-ext-diff HEAD --stat -- . ":(exclude)$SDIR" 2>/dev/null | tail -n1 | tr -s ' ' | sed 's/^ //')"
        [ -n "$s" ] && out="${out:+$out; }${m}: $s"
    done < <(members)
    printf '%s' "$out"
}

# SHA-256 fingerprint: HEAD + binary diffs + untracked files (pass "tracked" to ignore untracked test reports)
state_hash() {
    local m f head tracked_only="${1:-}"
    {
        while IFS= read -r m; do
            [ -z "$m" ] && continue; is_git "$m" || continue
            printf 'MEMBER:%s\n' "$m"
            head="$(git -C "$ROOT/$m" rev-parse --verify -q HEAD 2>/dev/null || echo UNBORN)"
            printf 'HEAD:%s\n' "$head"
            if [ -n "$tracked_only" ]; then
                git -C "$ROOT/$m" -c core.fsmonitor=false status --porcelain -- . ":(exclude)$SDIR" 2>/dev/null | grep -v '^?? ' || true
            else
                git -C "$ROOT/$m" -c core.fsmonitor=false status --porcelain -- . ":(exclude)$SDIR" 2>/dev/null
            fi
            if [ "$head" != "UNBORN" ]; then
                git -C "$ROOT/$m" -c core.fsmonitor=false diff --no-textconv --no-ext-diff --binary HEAD -- . ":(exclude)$SDIR" 2>/dev/null
            else
                git -C "$ROOT/$m" -c core.fsmonitor=false diff --no-textconv --no-ext-diff --binary -- . ":(exclude)$SDIR" 2>/dev/null
                git -C "$ROOT/$m" -c core.fsmonitor=false diff --no-textconv --no-ext-diff --binary --cached -- . ":(exclude)$SDIR" 2>/dev/null
            fi
            [ -n "$tracked_only" ] || while IFS= read -r -d '' f; do
                printf 'UNTRACKED:%s\n' "$f"
                if [ -L "$ROOT/$m/$f" ]; then
                    readlink "$ROOT/$m/$f" 2>/dev/null || true
                elif [ -f "$ROOT/$m/$f" ]; then
                    sha < "$ROOT/$m/$f" 2>/dev/null || true
                fi
            done < <(git -C "$ROOT/$m" ls-files -o --exclude-standard -z -- . ":(exclude)$SDIR" 2>/dev/null)
        done < <(members)
    } | sha
}

# Transactional receipt rotation (prevents duplicate archival on mid-write crash)
recover_receipt_txn() {
    local txn="$LOCAL_DIR/receipt-txn"
    [ -d "$txn" ] || return 0
    if [ -f "$txn/state" ] && [ -f "$txn/archive" ]; then
        atomic_copy "$txn/archive" "$ARCHIVE_FILE" || return 1
        atomic_copy "$txn/state" "$STATE_FILE" || return 1
    fi
    rm -rf "$txn" 2>/dev/null || true
}
write_receipt() {
    local txn="$LOCAL_DIR/receipt-txn" stage total keep drop rc=0
    acquire_lock "$STATE_LOCK" 150 0.02 || return 1
    recover_receipt_txn || { release_lock "$STATE_LOCK"; return 1; }
    stage="$(mktemp -d "$LOCAL_DIR/receipt.XXXXXX")" || { release_lock "$STATE_LOCK"; return 1; }
    if [ -f "$STATE_FILE" ]; then
        cp "$STATE_FILE" "$stage/full" || { rm -rf "$stage"; release_lock "$STATE_LOCK"; return 1; }
    else
        : > "$stage/full"
    fi
    printf '\n## [%s] | Agent: %s | %s\n- Verified Receipt: %s\n- Touched Files: %s (%s)\n- Next Deterministic Action: %s\n' \
        "$NOW" "$AGENT_SLOT" "$1" "$2" "${TOUCHED:-clean tree}" "${DSTAT:-0 changes}" "$3" >> "$stage/full"
    [ -f "$ARCHIVE_FILE" ] && cp "$ARCHIVE_FILE" "$stage/archive" || : > "$stage/archive"
    keep="${CRUX_KEEP_BLOCKS:-8}"
    total="$(awk '/^## \[/ {n++} END {print n+0}' "$stage/full")"
    drop=$((total - keep)); [ "$drop" -lt 0 ] && drop=0
    ARCH="$stage/archive" DROP="$drop" awk '
        /^## \[/ { b++ }
        { if (b > 0 && b <= ENVIRON["DROP"] + 0) print >> (ENVIRON["ARCH"]); else print }
    ' "$stage/full" > "$stage/state"
    mv "$stage" "$txn" 2>/dev/null && recover_receipt_txn || rc=1
    release_lock "$STATE_LOCK"
    return "$rc"
}

# Machine-local hub trust key (cloned repos can NEVER execute untrusted verify.command)
trust_key() {
    local g
    g="$(cd "$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
    printf '%s' "${g:-$ROOT}" | sha | cut -c1-16
}
gate_guard() {
    # 0 = trusted | 2 = empty/missing | 3 = never trusted on this machine | 1 = tampered
    local f="$ROOT/$SDIR/verify.command" base cur
    [ -s "$f" ] || return 2
    base="$(cat "$HUB_DIR/trust/$(trust_key)" 2>/dev/null || true)"
    [ -n "$base" ] || return 3
    cur="$(sha < "$f")" || return 1
    [ "$cur" = "$base" ]
}

# Post-hoc integrity guards: adopt git checkout/pull changes, revert in-session tampering or deletion
git_driven() {
    case "$(git -C "$ROOT" log -g -1 --format=%gs HEAD 2>/dev/null || true)" in commit*|"") return 1 ;; esac
    git -C "$ROOT" show "HEAD:$1" 2>/dev/null | cmp -s - "$ROOT/$1"
}
plan_guard() {
    local P="$ROOT/$SDIR/PLAN.md" B="$LOCAL_DIR/plan.base"
    [ -f "$B" ] || return 0
    if [ ! -f "$P" ]; then
        atomic_copy "$B" "$P" || true
        printf '\n- [%s] %s: deleted PLAN.md restored from baseline\n' "$NOW" "$AGENT_SLOT" >> "$ROOT/$SDIR/PROPOSALS.md"
        return 1
    fi
    cmp -s "$P" "$B" && return 0
    if git_driven "$SDIR/PLAN.md"; then
        cp "$P" "$B" 2>/dev/null || true
        return 0
    fi
    cp "$P" "$LOCAL_DIR/plan.rejected.$(date +%s)" 2>/dev/null || true
    atomic_copy "$B" "$P" || true
    printf '\n- [%s] %s: PLAN.md changed outside `%s plan`; reverted (copy saved in .crux/local/plan.rejected.*)\n' "$NOW" "$AGENT_SLOT" "$NAME" >> "$ROOT/$SDIR/PROPOSALS.md"
    return 1
}
progress_guard() {
    local P="$ROOT/$SDIR/PROGRESS.md" B="$LOCAL_DIR/progress.base" n
    [ -f "$B" ] || { [ -f "$P" ] && cp "$P" "$B" 2>/dev/null || true; return 0; }
    if [ ! -f "$P" ]; then
        atomic_copy "$B" "$P" || true
        return 0
    fi
    if git_driven "$SDIR/PROGRESS.md"; then
        cp "$P" "$B" 2>/dev/null || true
        return 0
    fi
    n="$(wc -c < "$B" | tr -d ' ')"
    if [ "$(head -c "$n" "$P" 2>/dev/null | sha)" != "$(sha < "$B")" ]; then
        { cat "$B"; grep -vxFf "$B" "$P" 2>/dev/null || true; } > "$P.tmp.$$" && mv -f "$P.tmp.$$" "$P"
    fi
    cp "$P" "$B" 2>/dev/null || true
}

# ---- Payload Extraction & Symlink-First Canonical Path Resolution ----
TOOL="$(jget tool_name)"
[ -z "$TOOL" ] && TOOL="$(jget toolName)"
[ -z "$TOOL" ] && TOOL="$(jget name)"
[ -z "$TOOL" ] && TOOL="$(printf '%s' "$PAYLOAD" | jq -r '(.toolCall.name // empty) | select(type == "string")' 2>/dev/null | head -n1)"
TOOL_LC="$(lc "$TOOL")"

extract_paths() {
    {
        printf '%s' "$PAYLOAD" | jq -r '(.tool_input // .toolInput // .toolCall.args // .input // .arguments // {}) | .. | objects | (.file_path, .path, .notebook_path, .filePath, .target_file, .file, .AbsolutePath, .TargetFile, .DirectoryPath, .SearchPath, .SearchDirectory, .destination, .dest, .new_path, .old_path) | select(type == "string")' 2>/dev/null
        # Also extract paths from patch/diff text blobs (e.g. apply_patch)
        printf '%s' "$PAYLOAD" | jq -r '(.tool_input // .toolInput // .toolCall.args // .input // .arguments // {}) | .. | strings | select(test("\n")) | split("\n")[] | capture("^(\\*\\*\\* (Add|Update|Delete) File: |\\*\\*\\* Move to: |\\+\\+\\+ [ab]/|--- [ab]/)(?<p>[^\\t]+)") | .p' 2>/dev/null
    } | awk 'NF'
}
extract_search_patterns() {
    printf '%s' "$PAYLOAD" | jq -r '(.tool_input // .toolInput // .toolCall.args // .input // .arguments // {}) | .. | objects | (.pattern, .Pattern, .SearchPattern, .glob, .Includes) | (if type == "array" then .[] else . end) | select(type == "string")' 2>/dev/null
}
extract_command() {
    printf '%s' "$PAYLOAD" | jq -r '(.tool_input // .toolInput // .toolCall.args // .input // .arguments // {}) | if type=="object" then ((.command // .cmd // .script // .CommandLine // empty) | if type=="array" then join(" ") else tostring end) elif type=="string" then . else empty end' 2>/dev/null
}

collapse_path() {
    local IFS=/ seg out=""
    for seg in $1; do
        case "$seg" in ""|.) ;; ..) out="${out%/*}" ;; *) out="$out/$seg" ;; esac
    done
    printf '%s' "${out:-/}"
}
canon_path() {
    local p="$1" d b t rd n=0
    p="${p//\\//}"
    case "$p" in "~"|"~/"*) p="$HOME${p#\~}" ;; esac
    case "$p" in /*) ;; *) p="$TOOL_CWD/$p" ;; esac
    d="$(dirname "$p")"; b="$(basename "$p")"
    if [ -d "$d" ]; then
        rd="$(cd -P "$d" 2>/dev/null && pwd -P)" || rd=""
        [ -n "$rd" ] && p="${rd%/}/$b"
    else
        p="$(collapse_path "$p")"
    fi
    while [ -L "$p" ] && [ "$n" -lt 40 ]; do
        t="$(readlink "$p" 2>/dev/null || true)"
        [ -z "$t" ] && break
        case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
        d="$(dirname "$p")"; b="$(basename "$p")"
        if [ -d "$d" ]; then
            rd="$(cd -P "$d" 2>/dev/null && pwd -P)" || rd=""
            [ -n "$rd" ] && p="${rd%/}/$b"
        else
            p="$(collapse_path "$p")"
        fi
        n=$((n + 1))
    done
    printf '%s' "$p"
}
HUB_PHYS="$(cd "$HUB_DIR" 2>/dev/null && pwd -P || printf '%s' "$HUB_DIR")"

# Write/mutating tool names ALWAYS win over read substrings (blocks search_replace / find_and_replace bypass)
is_read_tool() {
    case "$TOOL_LC" in
        *write*|*edit*|*patch*|*replace*|*create*|*insert*|*append*|*delete*|*move*|*rename*|*apply*) return 1 ;;
    esac
    case "$TOOL_LC" in *read*|*view*|*grep*|*glob*|*list*|*search*|*find*|ls) return 0 ;; esac
    return 1
}
is_secret_path() {
    local p="$1" mode="${2:-path}" b
    p="${p//\\//}"
    while :; do case "$p" in [@:=,]* ) p="${p#?}" ;; * ) break ;; esac; done
    b="${p##*/}"; b="${b##*:}"
    b="$(lc "$b")"
    if [ "$mode" = "cmd" ]; then
        case "$b" in
            .*[*?[{]*) case "${b#.}" in [*?[{]*|e[*?[{]*|en[*?[{]*|env[*?[{]*) return 0 ;; esac ;;
            id_rsa[*?[{]*|id_ed25519[*?[{]*|id_ecdsa[*?[{]*) return 0 ;;
        esac
    fi
    case "$b" in
        .env.example|.env.sample|.env.template|.env.dist|*.pub) return 1 ;;
        .env|.env.*|*.pem|*.key|*.jks|*.keystore|*.p12|*.pfx|id_rsa|id_rsa.*|id_ed25519|id_ecdsa|.netrc|.git-credentials) return 0 ;;
    esac
    return 1
}
protected_reason() {
    local c r h
    c="$(lc "$(canon_path "$1")")"; r="$(lc "$ROOT")"; h="$(lc "$HUB_PHYS")"
    case "$c" in
        "$h"|"$h"/*|*/.crux-hub|*/.crux-hub/*|*/.crux-ignore|"$r"/.crux|"$r"/.crux/.exempt|"$r"/.crux/workspace|"$r"/.crux/hooks|"$r"/.crux/hooks/*|"$r"/.crux/local|"$r"/.crux/local/*|"$r"/.crux/archive|"$r"/.crux/archive/*|"$r"/.crux/wiki-baselines|"$r"/.crux/wiki-baselines/*|"$r"/.crux/verify.command|"$r"/.crux/project_state.md|"$r"/.crux/index.md)
            echo "internal crux state" ;;
        */.claude/settings.json|*/.claude/settings.local.json|*/.qoder/settings*.json|*/.zcode/config.json|*/.zcode/cli/config.json|*/.agents/hooks.json|*/.gemini/config/hooks.json|*/.opencode/plugins/crux.js|*/.opencode/plugins/crux|*/.opencode/plugins/crux/*|*/.config/opencode/plugins/crux.js|*/.config/opencode/plugins/crux|*/.config/opencode/plugins/crux/*)
            echo "harness hook configuration" ;;
        "$r"/.crux/agents.md)
            echo "internal crux state" ;;
        "$r"/.crux/plan.md)
            echo "plan" ;;
    esac
}

SQ="'"; DQ='"'
QC="[${SQ}${DQ}]"
NQ="[^[:space:]${SQ}${DQ}]"
bash_mutates() {
    local cmd="$1" P="$2" END re
    cmd="$(lc "$cmd" | sed -E 's#[0-9]*>&[0-9-]+##g; s#[0-9]*>[[:space:]]*/dev/null##g')"
    END="(${QC}|[[:space:]]|[;&|)]|\$)"
    for re in \
        ">[[:space:]]*${QC}?${NQ}*(${P})${END}" \
        "(^|[^[:alnum:]_])tee[[:space:]][^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])(sed|perl|ruby|awk)[[:space:]][^|;&]*(-[a-z]*i|--in-place|-i[[:space:]]+inplace)[^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])(mv|rm|truncate|ln|install|dd|shred|touch|chmod|patch)[[:space:]][^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])cp[[:space:]][^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])find[[:space:]][^|;&]*(${P})[^|;&]*(-delete|-exec)" \
        "(^|[^[:alnum:]_])rsync[[:space:]][^|;&]*(${P})" \
        "(^|[^[:alnum:]_])(python[0-9.]*|node|nodejs|deno|bun|perl|ruby|php)[[:space:]]+(-[a-z]*[ce]|-)[[:space:]].*(${P})" \
        "(^|[^[:alnum:]_])git[[:space:]]+([^|;&]*[[:space:]])?(checkout|restore|reset|apply|am|stash|rm|mv|clean)[[:space:]][^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])(cd|pushd)[[:space:]]+[^;&|]*\\.crux(/|[[:space:];&|\"']|\$)" \
        "(^|[^[:alnum:]_])(git|make)[[:space:]]+-c[[:space:]]*[^[:space:]]*\\.crux"
    do
        if [[ "$cmd" =~ $re ]]; then return 0; fi
    done
    return 1
}
bash_destroys_state() {
    local c T re GC DRY SW SWF
    c="$(lc "$1")"
    T='(^|[[:space:]/=])\.crux(/?\*?)([[:space:];&|)]|$)'
    for re in \
        "(^|[^[:alnum:]_])(rm|rmdir|unlink|mv|shred|ln)[[:space:]][^;&|]*${T}" \
        "(^|[^[:alnum:]_])git[[:space:]]+([^;&|]*[[:space:]])?(rm|mv)[[:space:]][^;&|]*${T}"; do
        [[ "$c" =~ $re ]] && return 0
    done
    GC='(^|[^[:alnum:]_])git[[:space:]]+([^;&|]*[[:space:]])?clean([[:space:]]|$)'
    DRY='[[:space:]]-[a-z]*n[a-z]*([[:space:]]|$)|--dry-run|(-e|--exclude)[[:space:]=]*\.crux'
    if [[ "$c" =~ $GC ]] && ! [[ "$c" =~ $DRY ]]; then return 0; fi
    SW='(^|[^[:alnum:]_])git[[:space:]]+([^;&|]*[[:space:]])?stash([[:space:]]|$)'
    SWF='[[:space:]](-[a-z]*[ua][a-z]*|--include-untracked|--all)([[:space:]]|$)'
    if [[ "$c" =~ $SW ]] && [[ "$c" =~ $SWF ]] && ! [[ "$c" =~ \.crux ]]; then return 0; fi
    return 1
}
HUB_RE="$(printf '%s' "$(lc "$HUB_PHYS")" | sed 's#[][\.*^$+?(){}|/]#\\&#g')(/|${NQ}*)"
SOFT_RE='\.crux/plan\.md|\.crux/agents\.md'
HARD_RE="\\.crux([^a-z0-9_-]|$)|\\.crux-hub([^a-z0-9_-]|$)|\\.crux/(hooks|local|archive|wiki-baselines)/${NQ}*|\\.crux/(verify\\.command|project_state\\.md|index\\.md|workspace|\\.exempt)|\\.crux-ignore|${HUB_RE}|\\.claude/settings(\\.local)?\\.json|\\.qoder/settings[a-z.]*\\.json|\\.zcode/(cli/)?config\\.json|\\.agents/hooks\\.json|\\.gemini/config/hooks\\.json|\\.(config/)?opencode/plugins/crux${NQ}*"

# ===================================== Event Handlers ====================================
case "$KIND" in

start)
    rm -f "$FAIL_FILE" "$LOOP_FILE"
    if [ -f "$ROOT/$SDIR/PLAN.md" ] && { [ ! -f "$LOCAL_DIR/plan.base" ] || git_driven "$SDIR/PLAN.md"; }; then
        cp "$ROOT/$SDIR/PLAN.md" "$LOCAL_DIR/plan.base" 2>/dev/null || true
    fi
    if [ -f "$ROOT/$SDIR/PROGRESS.md" ] && { [ ! -f "$LOCAL_DIR/progress.base" ] || git_driven "$SDIR/PROGRESS.md"; }; then
        cp "$ROOT/$SDIR/PROGRESS.md" "$LOCAL_DIR/progress.base" 2>/dev/null || true
    fi
    [ -x "$CLI" ] && ( cd "$ROOT" && "$CLI" index-sync --quiet ) >/dev/null 2>&1 || true

    RECOV_MSG=""
    if grep -q 'IN-PROGRESS' "$CKPT_FILE" 2>/dev/null && [ "$(active_agents)" -eq 0 ]; then
        TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
        write_receipt "AUTO-RECOVERED INTERRUPTED SESSION" "Prior agent stopped mid-turn before verification" "Inspect git diff on touched files (${TOUCHED:-none}) and check .crux/PROGRESS.md + .crux/PLAN.md" || true
        find "$SLOTS_DIR" -type f -name '*.status' -exec rm -f {} \; 2>/dev/null || true
        set_ckpt "RECOVERED"
        RECOV_MSG="[$NAME] Auto-recovered interrupted session (touched: ${TOUCHED:-none}). "
    fi

    CTX="${RECOV_MSG}[$NAME] Continuity active. Read .crux/INDEX.md, .crux/PLAN.md, .crux/PROGRESS.md, and .crux/PROJECT_STATE.md before editing. PLAN.md is read-only (conflicts -> .crux/PROPOSALS.md). Finish with 'make agent-verify' and append '- [x] <TaskID> | <short-sha> | <harness> | <YYYY-MM-DD> | <summary>' to .crux/PROGRESS.md."
    if [ "$AGY_MODE" = 1 ]; then
        printf '{"injectSteps":[{"systemMessage":{"systemMessage":%s}}]}\n' "$(json_str "$CTX")"
        exit 0
    fi
    if [ "$HARNESS" = "zcode" ]; then
        jq -nc --arg msg "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$msg}}'
        exit 0
    fi
    printf '%s\n' "$CTX"
    exit 0
    ;;

pre)
    PATHS="$(extract_paths)"; CMD="$(extract_command)"; SEARCH="$(extract_search_patterns)"

    if [ -n "$SEARCH" ]; then
        while IFS= read -r sp; do
            [ -z "$sp" ] && continue
            is_secret_path "$sp" cmd && block "SECURITY BLOCK [$NAME]: search pattern references sensitive credential file '$sp'."
        done <<EOF_S
$SEARCH
EOF_S
    fi
    if [ -n "$PATHS" ]; then
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            is_secret_path "$p" path && block "SECURITY BLOCK [$NAME]: access to sensitive credential file '$p' is forbidden."
            cp_res="$(canon_path "$p")"
            is_secret_path "$cp_res" path && block "SECURITY BLOCK [$NAME]: symlink/path '$p' resolves to sensitive credential file '$cp_res'."
        done <<EOF_P
$PATHS
EOF_P
    fi
    if [ -n "$CMD" ]; then
        CMD_N="$(printf '%s' "$CMD" | tr -d "\\\\'\"")"
        TOKS="$(printf '%s\n' "$CMD_N" | tr -s '[:space:];|&<>()=:`' '\n')"
        while IFS= read -r tok; do
            [ -z "$tok" ] && continue
            is_secret_path "$tok" cmd && block "SECURITY BLOCK [$NAME]: command references sensitive credential file '$tok'."
        done <<EOF_T
$TOKS
EOF_T
        HUM="(^|[;&|[:space:]])([^;&|[:space:]]*/)?($(lc "$NAME")|crux)[[:space:]]+(exempt|unexempt|clear|purge|gate|mode|hooks|uninstall|plan|init|update|wiki-mark)([[:space:]]|$)"
        if [[ "$(lc "$CMD_N")" =~ $HUM ]]; then
            block "CONTRACT BLOCK [$NAME]: '${BASH_REMATCH[3]} ${BASH_REMATCH[4]}' is human-only."
        fi
    fi

    if ! is_read_tool && [ -n "$PATHS" ]; then
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            why="$(protected_reason "$p")"; [ -z "$why" ] && continue
            case "$why" in
                plan) block "CONTRACT BLOCK [$NAME]: .crux/PLAN.md is READ-ONLY to agents (human: edit directly or run '$NAME plan'). Log completed tasks to .crux/PROGRESS.md and blockers to .crux/PROPOSALS.md." ;;
                *)    block "CONTRACT BLOCK [$NAME]: '$p' is $why and never writable by agents." ;;
            esac
        done <<EOF_W
$PATHS
EOF_W
    fi
    if [ -n "$CMD" ]; then
        case "$(lc "$TOOL_CWD")" in
            "$(lc "$ROOT")/.crux"|"$(lc "$ROOT")/.crux/"*|"$(lc "$HUB_PHYS")"|"$(lc "$HUB_PHYS")/"*)
                block "CONTRACT BLOCK [$NAME]: refusing shell execution with working directory inside protected .crux state ($TOOL_CWD)." ;;
        esac
        bash_destroys_state "$CMD_N" && block "CONTRACT BLOCK [$NAME]: command would delete or sweep .crux state (rm/mv of .crux, 'git clean' without -n/-e .crux, 'git stash -u/-a')."
        CHECK_CMD="$(printf '%s' "$CMD_N" | sed 's#>>[[:space:]]*\.crux/PROGRESS\.md##g; s#>>[[:space:]]*\.crux/PROPOSALS\.md##g; s#tee[[:space:]]*-a[[:space:]]*\.crux/PROGRESS\.md##g; s#tee[[:space:]]*-a[[:space:]]*\.crux/PROPOSALS\.md##g')"
        bash_mutates "$CHECK_CMD" "$HARD_RE" && block "CONTRACT BLOCK [$NAME]: command modifies protected .crux or harness config files."
        bash_mutates "$CHECK_CMD" "$SOFT_RE" && block "CONTRACT BLOCK [$NAME]: .crux/PLAN.md is READ-ONLY to agents. Log completed tasks to .crux/PROGRESS.md and blockers to .crux/PROPOSALS.md."
    fi

    # 5x Identical Tool-Call Anti-Loop Breaker (non-read tools only)
    LOOP_MAX="${CRUX_LOOP_MAX:-5}"
    if ! is_read_tool && [ -n "$PAYLOAD" ] && [ "$LOOP_MAX" -gt 0 ]; then
        SIG="$(printf '%s' "$PAYLOAD" | jq -S -c '[(.tool_name // .toolName // .toolCall.name // .name), (.tool_input // .toolInput // .toolCall.args // .input // .arguments)]' 2>/dev/null | sha | cut -c1-16)"
        TS="$(date +%s)"; PH=""; PC=0; PT=0
        if [ -f "$LOOP_FILE" ]; then read -r PH PC PT < "$LOOP_FILE" 2>/dev/null || true; fi
        if [ "$SIG" = "$PH" ] && [ $((TS - ${PT:-0})) -le 120 ]; then PC=$((${PC:-0} + 1)); else PC=1; fi
        echo "$SIG $PC $TS" > "$LOOP_FILE"
        if [ "$PC" -ge "$LOOP_MAX" ]; then
            echo "$SIG 0 $TS" > "$LOOP_FILE"
            block "ANTI-LOOP FENCE [$NAME]: identical tool call repeated $PC times consecutively by $AGENT_SLOT. Change strategy or log blocker to .crux/PROPOSALS.md."
        fi
    fi

    atomic_text "$SLOT_FILE" "[$NOW] Agent=$AGENT_SLOT | IN-PROGRESS" 2>/dev/null || true
    set_ckpt "IN-PROGRESS (Active Agents: $(active_agents), Latest: $AGENT_SLOT)"
    allow_out
    ;;

post)
    if ! plan_guard; then
        [ "$AGY_MODE" = 1 ] || { echo "[$NAME] PLAN.md is read-only; edit reverted. Log conflicts in .crux/PROPOSALS.md." >&2; exit 2; }
    fi
    progress_guard
    if ! is_read_tool; then
        TOUCHED="$(touched_list 4 | tr ' ' ',')"
        atomic_text "$SLOT_FILE" "[$NOW] Agent=$AGENT_SLOT | Touched=${TOUCHED:-none}" 2>/dev/null || true
        set_ckpt "IN-PROGRESS (Active Agents: $(active_agents), Latest: $AGENT_SLOT) | Touched: ${TOUCHED:-none}"
    fi
    allow_out
    ;;

end)
    rm -f "$LOOP_FILE" "$FAIL_FILE" "$SLOT_FILE"
    if [ "$(active_agents)" -eq 0 ]; then
        set_ckpt "READY (session ended: $AGENT_SLOT)"
    fi
    allow_out
    ;;

stop)
    plan_guard >/dev/null 2>&1 || true
    progress_guard

    # Antigravity: do not finalize Stop while background tasks are still running
    if [ "$AGY_MODE" = 1 ]; then
        if printf '%s' "$PAYLOAD" | jq -e 'has("fullyIdle") and (.fullyIdle != true)' >/dev/null 2>&1; then
            allow_out
        fi
    fi

    [ -f "$LOCAL_DIR/gate.off" ] && [ "$MANUAL_MODE" = 0 ] && { rm -f "$SLOT_FILE" "$LOOP_FILE"; set_ckpt "READY (gate off)"; allow_out; }

    gate_guard; GRC=$?
    if [ "$GRC" -ne 0 ]; then
        if [ "$MANUAL_MODE" = 1 ]; then
            [ "$GRC" -eq 2 ] && echo "No verification command configured. Run: $NAME gate '<cmd>'" >&2
            [ "$GRC" -eq 3 ] && echo ".crux/verify.command is NOT trusted on this machine. Review it, then run: $NAME gate --accept" >&2
            [ "$GRC" -eq 1 ] && echo ".crux/verify.command changed outside '$NAME gate' (refused to execute). Review it, then run: $NAME gate --accept" >&2
            exit 1
        fi
        HASH_NOW="$(state_hash)"
        if [ "$HASH_NOW" != "$(cat "$LOCAL_DIR/last_receipt" 2>/dev/null || true)" ]; then
            TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
            if [ "$GRC" -eq 2 ]; then
                write_receipt "NO TESTS CONFIGURED" "verify.command not set yet" "Configure verification via '$NAME gate <cmd>'" || true
            else
                write_receipt "GATE NOT RUN (UNTRUSTED)" "verify.command not trusted on this machine; never executed" "Human: review .crux/verify.command, then run '$NAME gate --accept'" || true
            fi
            echo "$HASH_NOW" > "$LOCAL_DIR/last_receipt"
        fi
        rm -f "$SLOT_FILE" "$LOOP_FILE"
        set_ckpt "READY (gate inactive: code $GRC)"
        allow_out
    fi

    if ! acquire_lock "$VERIFY_LOCK" 200 0.5; then
        stop_continue "VERIFICATION BUSY [$NAME]: another agent is running verification. Retry once it finishes."
    fi

    HASH_BEFORE="$(state_hash)"
    TRK_BEFORE="$(state_hash tracked)"
    VLOG="$(mktemp "$LOCAL_DIR/verify-$AGENT_SLOT.XXXXXX")"
    chmod 600 "$VLOG" 2>/dev/null || true
    VTIMEOUT="${CRUX_VERIFY_TIMEOUT:-300}"

    run_timeout "$VTIMEOUT" bash --noprofile --norc "$ROOT/$SDIR/verify.command" >"$VLOG" 2>&1
    RC=$?
    TRK_AFTER="$(state_hash tracked)"

    if [ "$RC" -eq 0 ] && [ "$TRK_BEFORE" != "$TRK_AFTER" ]; then
        RC=98
        printf 'Tracked repository files changed during verification; re-run required.\n' >> "$VLOG"
    fi

    if [ "$RC" -ne 0 ]; then
        REASON="exit $RC"
        [ "$RC" -eq 124 ] && REASON="TIMEOUT after ${VTIMEOUT}s"
        [ "$RC" -eq 98 ]  && REASON="tracked files modified during verification"
        release_lock "$VERIFY_LOCK"

        if [ "$MANUAL_MODE" = 1 ]; then
            printf 'Verification failed (%s). Private log: %s\n' "$REASON" "$VLOG" >&2
            exit 1
        fi
        if [ "$OBSERVER_MODE" = 1 ]; then
            TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
            printf '\n- [%s] Observer gate failed for %s (%s) — private log: %s\n' "$NOW" "$AGENT_SLOT" "$REASON" "$VLOG" >> "$ROOT/$SDIR/PROPOSALS.md"
            write_receipt "GATE FAILED (OBSERVER)" "verify.command $REASON (log: ${VLOG##*/})" "Inspect private log in .crux/local/ and fix build" || true
            rm -f "$FAIL_FILE" "$SLOT_FILE" "$LOOP_FILE"
            set_ckpt "READY (observer logged failure)"
            allow_out
        fi
        N="$(cat "$FAIL_FILE" 2>/dev/null || echo 0)"
        case "$N" in ""|*[!0-9]*) N=0 ;; esac
        N=$((N + 1)); echo "$N" > "$FAIL_FILE"
        if [ "$N" -ge 3 ]; then
            TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
            printf '\n- [%s] Gate failed %s times for %s (%s); released — private log: %s\n' "$NOW" "$N" "$AGENT_SLOT" "$REASON" "$VLOG" >> "$ROOT/$SDIR/PROPOSALS.md"
            write_receipt "GATE FAILED x$N (RELEASED)" "verify.command $REASON (log: ${VLOG##*/})" "Human review: see private log in .crux/local/" || true
            rm -f "$FAIL_FILE" "$SLOT_FILE" "$LOOP_FILE"
            set_ckpt "READY (gate released after $N failures)"
            allow_out
        fi
        stop_continue "PRODUCTION GATE BLOCKED [$NAME] (Attempt $N/3): verification failed ($REASON). Inspect private log '$VLOG' and fix before stopping."
    fi

    TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
    if ! write_receipt "OBSERVED PASS" "verify.command exited 0 (pre/post tracked hash matched)" "Record completed task in .crux/PROGRESS.md and proceed to next unchecked task in .crux/PLAN.md"; then
        release_lock "$VERIFY_LOCK"
        stop_continue "RECEIPT WRITE FAILED [$NAME]: could not persist verification receipt to .crux/PROJECT_STATE.md."
    fi
    rm -f "$FAIL_FILE" "$SLOT_FILE" "$LOOP_FILE" "$VLOG"
    [ -x "$CLI" ] && ( cd "$ROOT" && "$CLI" index-sync --quiet ) >/dev/null 2>&1 || true
    if [ "$(active_agents)" -eq 0 ]; then
        set_ckpt "READY (Last verified: $AGENT_SLOT) | Observed pass"
    else
        set_ckpt "IN-PROGRESS (Active Agents: $(active_agents), Last verified: $AGENT_SLOT)"
    fi
    release_lock "$VERIFY_LOCK"
    allow_out
    ;;
esac
allow_out
HOOK_EOF

HUB_ESC="$(sed_escape "$(shell_quote "${HUB_DIR}")")"
BIN_ESC="$(sed_escape "$(shell_quote "${BIN_DIR}")")"
NAME_ESC="$(sed_escape "$(shell_quote "${CLI_NAME}")")"
VER_ESC="$(sed_escape "${CRUX_VERSION}")"
HOOK_OUT="$(mktemp "${HUB_DIR}/hooks/on_event.out.XXXXXX")"
sed -e "s|@@HUB@@|${HUB_ESC}|g" -e "s|@@BIN@@|${BIN_ESC}|g" -e "s|@@VERSION@@|${VER_ESC}|g" -e "s|@@NAME@@|${NAME_ESC}|g" \
    "${HOOK_TMPL}" > "${HOOK_OUT}"
rm -f "${HOOK_TMPL}"
bash -n "${HOOK_OUT}" || { rm -f "${HOOK_OUT}"; echo "ERROR: generated on_event.sh failed syntax check."; exit 1; }
chmod +x "${HOOK_OUT}"
mv -f "${HOOK_OUT}" "${HUB_DIR}/hooks/on_event.sh"

# ------------------------------------------------------------------------------
# 4. Zero-Friction `crux` CLI
# ------------------------------------------------------------------------------
CLI_TMPL="$(mktemp "${BIN_DIR}/${CLI_NAME}.tmpl.XXXXXX")"
cat <<'CLI_EOF' > "${CLI_TMPL}"
#!/usr/bin/env bash
# CRUX-CLI-MARKER @@NAME@@ @@VERSION@@
unset BASH_ENV
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0

NAME=@@NAME@@
SDIR=".crux"
HUB_DIR=@@HUB@@
BIN_DIR=@@BIN@@
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }
note() { [ "${QUIET:-0}" = 1 ] || echo "$*"; }

sha() {
    local h
    if have sha256sum; then h="$(sha256sum)" || return 1
    elif have shasum; then h="$(shasum -a 256)" || return 1
    else h="$(git hash-object --stdin)" || return 1; fi
    printf '%s\n' "${h%% *}"
}

CMD="${1:-status}"; [ $# -gt 0 ] && shift
CWD="$(pwd -P 2>/dev/null || pwd)"

find_root() {
    local d="$CWD"
    while [ -n "$d" ]; do
        [ -f "$d/$SDIR/PROJECT_STATE.md" ] && { printf '%s' "$d"; return 0; }
        [ "$d" = "/" ] && break
        d="${d%/*}"; [ -z "$d" ] && d="/"
    done
    return 1
}
git_top() { local t; t="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [ -n "$t" ] && (cd "$t" && pwd -P); }
ROOT="$(find_root || true)"
need_root() { [ -n "$ROOT" ] || die "no initialized $NAME project here (run '$NAME init')."; cd "$ROOT" || exit 1; LOCAL="$ROOT/$SDIR/local"; }
members() {
    local m found=0
    if [ -f "$SDIR/WORKSPACE" ]; then
        while IFS= read -r m; do
            case "$m" in ""|\#*) continue ;; esac
            git -C "$m" rev-parse --git-dir >/dev/null 2>&1 || continue
            printf '%s\n' "$m"; found=1
        done < "$SDIR/WORKSPACE"
    fi
    [ "$found" = 1 ] || printf '.\n'
}
pick_makefile() {
    local f
    for f in GNUmakefile makefile Makefile; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done
    printf 'Makefile'
}
trust_key() {
    local g
    g="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
    printf '%s' "${g:-$(pwd -P)}" | sha | cut -c1-16
}
trust_gate() {
    local c; c="$(sha < "$SDIR/verify.command")"
    mkdir -p "$HUB_DIR/trust" "$SDIR/local"
    printf '%s\n' "$c" > "$HUB_DIR/trust/$(trust_key)"
    printf '%s\n' "$c" > "$SDIR/local/gate.sha"
}
trusted_gate() {
    [ -s "$SDIR/verify.command" ] && [ "$(cat "$HUB_DIR/trust/$(trust_key)" 2>/dev/null || true)" = "$(sha < "$SDIR/verify.command")" ]
}
legacy_gate_cmd() {
    local mk; mk="$(pick_makefile)"; [ -f "$mk" ] || return 1
    awk '/^agent-verify[ \t]*:/{p=1;next} p&&/^\t/{sub(/^\t[@-]*/,""); if($0!~/^echo "==>/&&$0!~/verify\.sh/&&$0!~/CRUX_NO_TESTS/&&NF)print;next} p{exit}' "$mk" \
        | sed 's/\$(MAKE)/make/g' | awk 'NF{print;f=1} END{exit !f}'
}

detect_test_cmd() {
    local d="${1:-.}" c
    ( cd "$d" || exit 1
      mk=""; for f in GNUmakefile makefile Makefile; do [ -f "$f" ] && { mk="$f"; break; }; done
      if [ -n "$mk" ] && grep -q '^test:' "$mk"; then echo 'make test'
      elif [ -f package.json ] && grep -q '"test"' package.json && ! grep '"test"' package.json | grep -q 'no test specified'; then
          c="npm test"
          [ -f pnpm-lock.yaml ] && have pnpm && c="pnpm test"
          [ -f yarn.lock ]      && have yarn && c="yarn test"
          { [ -f bun.lockb ] || [ -f bun.lock ]; } && have bun && c="bun run test"
          echo "$c"
      elif [ -f Cargo.toml ]; then echo "cargo test"
      elif [ -f go.mod ]; then echo 'go test ./...'
      elif [ -f pytest.ini ] || [ -f pyproject.toml ] || [ -d tests ]; then
          py="python3"; [ -x .venv/bin/python ] && py=".venv/bin/python"
          echo "${py} -m pytest -q"
      else exit 1; fi )
}

wiki_key() { printf '%s\0%s\0' "$1" "$2" | sha | cut -c1-16; }
wiki_drift() {
    local m="$1" w="$2" key base head behind last
    key="$(wiki_key "$m" "$w")"
    base="$(cat "$SDIR/wiki-baselines/$key" 2>/dev/null || true)"
    if [ -n "$base" ]; then
        head="$(git -C "$m" rev-parse HEAD 2>/dev/null || true)"
        if [ -z "$head" ] || ! git -C "$m" cat-file -e "${base}^{commit}" 2>/dev/null; then
            printf ' [UNKNOWN: baseline unavailable]'; return 0
        fi
        if ! git -C "$m" merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
            printf ' [STALE: divergent history — verify against live code]'; return 0
        fi
        behind="$(git -C "$m" rev-list --count "${base}..${head}" 2>/dev/null || echo '?')"
        if [ "$behind" = "0" ]; then printf ' [FRESH]'; else printf ' [STALE: +%s commits behind HEAD — verify against live code]' "$behind"; fi
        return 0
    fi
    if git -C "$m" ls-files --error-unmatch -- "$w" >/dev/null 2>&1; then
        last="$(git -C "$m" log -1 --format=%H -- "$w" 2>/dev/null || true)"
        if [ -n "$last" ]; then
            behind="$(git -C "$m" rev-list --count "${last}..HEAD" 2>/dev/null || echo '?')"
            if [ "$behind" = "0" ]; then printf ' [FRESH]'; else printf ' [STALE: +%s commits behind HEAD — verify against live code]' "$behind"; fi
            return 0
        fi
    fi
    printf " [UNTRACKED: run '%s wiki-mark %s %s' to baseline]" "$NAME" "$m" "$w"
}

render_index() {
    local repo_base m w p cnt base_d sd sd_d sc drift_tag found_wiki=0 zmem
    repo_base="$(basename "$(pwd -P)")"
    echo "# Workspace Lookup Table (.crux/INDEX.md)"
    echo ""
    echo "## 1. Sovereign State & Contract Files (Inside .crux/)"
    echo "- Active Engineering Plan (Read-Only to AI, Editable by Human): \`.crux/PLAN.md\`"
    echo "- Durable Completed-Task Ledger (Append-Only, Never Rotates): \`.crux/PROGRESS.md\`"
    echo "- Chronological Session Receipts (Last 8; older in \`.crux/archive/\`): \`.crux/PROJECT_STATE.md\`"
    echo "- Agent Escalations & Blockers: \`.crux/PROPOSALS.md\`"
    echo "- Architectural Decisions Ledger: \`.crux/DECISIONS.md\`"
    echo ""
    echo "## 2. Intertwined Harness Wikis & Knowledge (Read On Demand — Zero Duplication)"
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        for w in .qoder/repowiki .zcode .minimax .mcode .opencode/docs docs/wiki .crux/docs; do
            p="$( [ "$m" = "." ] && echo "$w" || echo "$m/$w" )"
            if [ -d "$p" ]; then
                cnt="$(find "$p" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
                if [ "${cnt:-0}" -gt 0 ]; then
                    found_wiki=1
                    drift_tag="$(wiki_drift "$m" "$w")"
                    echo "- \`$p/\` ($cnt markdown chapters)${drift_tag}"
                    if [ "$cnt" -le 100 ]; then
                        find "$p" -name '*.md' 2>/dev/null | sort | while IFS= read -r ch; do echo "  - \`$ch\`"; done
                    else
                        base_d="$(printf '%s' "$p" | tr -cd '/' | wc -c | tr -d ' ')"
                        find "$p" -type d 2>/dev/null | sort | while IFS= read -r sd; do
                            [ "$sd" = "$p" ] && continue
                            sd_d="$(printf '%s' "$sd" | tr -cd '/' | wc -c | tr -d ' ')"
                            [ "$sd_d" -le $((base_d + 2)) ] || continue
                            sc="$(find "$sd" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
                            [ "${sc:-0}" -gt 0 ] && echo "  - \`$sd/\` ($sc chapters)"
                        done
                    fi
                fi
            fi
        done
    done < <(members)
    if [ -d "${HOME}/.zcode/cli/memories/projects" ]; then
        zmem="$(find "${HOME}/.zcode/cli/memories/projects" -type d -name "*${repo_base}*" 2>/dev/null | head -n1 || true)"
        if [ -n "$zmem" ] && [ -f "$zmem/memory/MEMORY.md" ]; then
            found_wiki=1
            echo "- ZCode Project Memory: \`$zmem/memory/MEMORY.md\`"
        fi
    fi
    if [ "$found_wiki" = 0 ]; then
        echo "- (No native harness wikis detected yet; .qoder/repowiki, .zcode, .minimax, and docs/wiki are auto-linked here when present)"
    fi
    return 0
}

index_sync() {
    mkdir -p "$SDIR/local"
    local tmp
    tmp="$(mktemp "$SDIR/INDEX.md.XXXXXX")" || return 1
    if render_index > "$tmp"; then
        mv -f "$tmp" "$SDIR/INDEX.md"
    else
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
}

# ---- Harness-Specific Hook Adapters (Verified Primary Schemas) ----
merge_json_hooks() {
    local f="$1" act="${2:-add}" harness="${3:-claude}" dir tmp hubhook bak
    dir="$(dirname "$f")"
    hubhook="${HUB_DIR}/hooks/on_event.sh"
    have jq || { echo "ERROR: jq required to configure $f" >&2; return 1; }
    mkdir -p "$dir"; [ -f "$f" ] || printf '{}\n' > "$f"
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "ERROR: $f is invalid JSON; skipped." >&2; return 1; }
    bak="${f}.crux-orig.bak"; [ -f "$bak" ] || cp "$f" "$bak"
    tmp="$(mktemp "${f}.XXXXXX")"
    if ! jq --arg hub "$hubhook" --arg act "$act" --arg harness "$harness" '
      def owned: (.command // "") | (contains("CRUX_HOOK=1") or contains($hub));
      def strip: map(.hooks = ((.hooks // []) | map(select(owned | not)))) | map(select(((.hooks // []) | length) > 0));
      def put(ev; t):
        .hooks[ev] = (((.hooks[ev] // []) | strip) +
          (if $act == "add"
           then [{hooks:[{type:"command", command:("CRUX_HOOK=1 env -u BASH_ENV bash " + ($hub | @sh) + " " + ev + " --harness=" + $harness), timeout:t}]}]
           else [] end));
      .hooks = (.hooks // {})
      | put("SessionStart"; 30) | put("PreToolUse"; 15) | put("PostToolUse"; 15)
      | put("PostToolUseFailure"; 15) | put("Stop"; 900) | put("SessionEnd"; 15)
      | .hooks |= with_entries(select(.value != []))
    ' "$f" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    note "==> [$NAME] Hooks ${act}ed in $f ($harness)"
}

merge_zcode_hooks() {
    local f="$1" act="${2:-add}" dir tmp hubhook bak
    dir="$(dirname "$f")"
    hubhook="${HUB_DIR}/hooks/on_event.sh"
    have jq || { echo "ERROR: jq required to configure $f" >&2; return 1; }
    mkdir -p "$dir"; [ -f "$f" ] || printf '{}\n' > "$f"
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "ERROR: $f is invalid JSON; skipped." >&2; return 1; }
    bak="${f}.crux-orig.bak"; [ -f "$bak" ] || cp "$f" "$bak"
    tmp="$(mktemp "${f}.XXXXXX")"
    if ! jq --arg hub "$hubhook" --arg act "$act" '
      def owned:
        ((.command == "bash") and (((.args // [])[0] // "") == $hub))
        or ((.command // "") | (contains("CRUX_HOOK=1") or contains($hub)));
      def clean: map(.hooks = ((.hooks // []) | map(select(owned | not)))) | map(select(((.hooks // []) | length) > 0));
      def put(ev; ms):
        .hooks.events[ev] = (((.hooks.events[ev] // []) | clean) +
          (if $act == "add"
           then [{matcher:".*", hooks:[{type:"process", command:"bash", args:[$hub, ev, "--harness=zcode"], enabled:true, timeoutMs:ms}]}]
           else [] end));
      .hooks = (.hooks // {})
      | .hooks |= del(.SessionStart, .PreToolUse, .PostToolUse, .Stop, .SessionEnd)
      | .hooks.events = (.hooks.events // {})
      | (if $act == "add" then .hooks.enabled = true else . end)
      | put("SessionStart"; 30000) | put("PreToolUse"; 15000) | put("PostToolUse"; 15000)
      | put("PostToolUseFailure"; 15000) | put("Stop"; 900000)
      | .hooks.events |= with_entries(select(.value != []))
    ' "$f" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    note "==> [$NAME] ZCode hooks ${act}ed in $f"
}

merge_agy_hooks() {
    local f="$1" act="${2:-add}" dir tmp hubhook bak
    dir="$(dirname "$f")"
    hubhook="${HUB_DIR}/hooks/on_event.sh"
    have jq || { echo "ERROR: jq required to configure $f" >&2; return 1; }
    mkdir -p "$dir"; [ -f "$f" ] || printf '{}\n' > "$f"
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "ERROR: $f is invalid JSON; skipped." >&2; return 1; }
    bak="${f}.crux-orig.bak"; [ -f "$bak" ] || cp "$f" "$bak"
    tmp="$(mktemp "${f}.XXXXXX")"
    if [ "$act" = "remove" ]; then
        jq 'del(.crux)' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        jq --arg hub "$hubhook" '
          def h(ev; t): {type:"command", command:("CRUX_HOOK=1 env -u BASH_ENV bash " + ($hub | @sh) + " " + ev + " --agy"), timeout:t};
          .crux = {
            enabled: true,
            SessionStart: [h("SessionStart"; 30)],
            PreToolUse:   [{matcher:".*", hooks:[h("PreToolUse"; 15)]}],
            PostToolUse:  [{matcher:".*", hooks:[h("PostToolUse"; 15)]}],
            Stop:         [h("Stop"; 900)]
          }
        ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
    note "==> [$NAME] Antigravity hooks ${act}ed in $f"
}

install_opencode_plugin() {
    local base_dir="$1" act="${2:-add}" hubhook oc_ver hook_js
    hubhook="${HUB_DIR}/hooks/on_event.sh"
    if [ "$act" = "remove" ]; then
        [ -f "$base_dir/plugins/crux.js" ] && grep -q 'CRUX-OPENCODE-BRIDGE\|CruxPlugin' "$base_dir/plugins/crux.js" 2>/dev/null && rm -f "$base_dir/plugins/crux.js"
        [ -f "$base_dir/plugins/crux/index.js" ] && grep -q 'CRUX-OPENCODE-BRIDGE' "$base_dir/plugins/crux/index.js" 2>/dev/null && rm -rf "$base_dir/plugins/crux"
        note "==> [$NAME] Removed OpenCode bridge plugin from $base_dir/plugins/"
        return 0
    fi
    oc_ver="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo '1.0')"
    hook_js="$(jq -nc --arg p "$hubhook" '$p')"
    mkdir -p "$base_dir/plugins"
    case "$oc_ver" in
        2.*)
            [ -f "$base_dir/plugins/crux.js" ] && grep -q 'CRUX-OPENCODE-BRIDGE\|CruxPlugin' "$base_dir/plugins/crux.js" 2>/dev/null && rm -f "$base_dir/plugins/crux.js"
            mkdir -p "$base_dir/plugins/crux"
            cat <<OC2_EOF > "$base_dir/plugins/crux/index.js"
// CRUX-OPENCODE-BRIDGE v2
import { spawnSync, spawn } from "node:child_process";
import { Plugin } from "@opencode/plugin";
const HOOK = ${hook_js};
const FALLBACK_SID = "opencode-" + process.pid + "-" + Date.now().toString(36);
function runCrux(args, payload, canBlock, syncStart) {
  if (!canBlock && !syncStart) {
    try {
      const c = spawn("bash", [HOOK, ...args, "--harness=opencode"], { stdio: ["pipe", "ignore", "ignore"], detached: true });
      c.on("error", () => {}); c.stdin.on("error", () => {});
      c.stdin.end(JSON.stringify(payload)); c.unref();
    } catch (_) {}
    return;
  }
  const r = spawnSync("bash", [HOOK, ...args, "--harness=opencode"], { input: JSON.stringify(payload), encoding: "utf8", timeout: 20000 });
  if (canBlock && (r.error || r.status === 2)) throw new Error(((r.stderr || (r.error && r.error.message)) || "Blocked by crux").trim());
}
export default Plugin.define({
  id: "crux",
  async setup(ctx) {
    const cwd = (ctx.location && ctx.location.directory) || ctx.directory || process.cwd();
    const started = new Set();
    const controller = new AbortController();
    const ensureStart = (sid) => {
      if (started.has(sid)) return;
      started.add(sid);
      runCrux(["SessionStart"], { hook_event_name: "SessionStart", session_id: sid, cwd }, false, true);
    };
    if (ctx.tool && ctx.tool.hook) {
      await ctx.tool.hook("execute.before", async (ev) => {
        const sid = (ev && ev.sessionID) || FALLBACK_SID;
        ensureStart(sid);
        runCrux(["PreToolUse"], { hook_event_name: "PreToolUse", tool_name: ev.tool, tool_input: ev.input || {}, session_id: sid, cwd }, true, false);
      });
      await ctx.tool.hook("execute.after", async (ev) => {
        const sid = (ev && ev.sessionID) || FALLBACK_SID;
        runCrux(["PostToolUse"], { hook_event_name: "PostToolUse", tool_name: ev.tool, session_id: sid, cwd }, false, false);
      });
    }
    if (ctx.shell && ctx.shell.hook) {
      await ctx.shell.hook("create.before", async (ev) => {
        const sid = (ev && ev.sessionID) || FALLBACK_SID;
        ensureStart(sid);
        runCrux(["PreToolUse"], { hook_event_name: "PreToolUse", tool_name: "bash", tool_input: { command: ev.command || "", workdir: ev.cwd || cwd }, session_id: sid, cwd }, true, false);
      });
    }
    if (ctx.event && ctx.event.subscribe) {
      void (async () => {
        try {
          for await (const ev of ctx.event.subscribe({ signal: controller.signal })) {
            if (!ev || ev.type !== "session.idle") continue;
            const sid = (ev.properties && ev.properties.sessionID) || ev.sessionID || FALLBACK_SID;
            runCrux(["Stop", "--observer"], { hook_event_name: "Stop", session_id: sid, cwd }, false, false);
          }
        } catch (_) {}
      })();
    }
    return () => controller.abort();
  }
});
OC2_EOF
            note "==> [$NAME] Installed OpenCode v2 bridge plugin at $base_dir/plugins/crux/index.js"
            ;;
        *)
            [ -f "$base_dir/plugins/crux/index.js" ] && grep -q 'CRUX-OPENCODE-BRIDGE' "$base_dir/plugins/crux/index.js" 2>/dev/null && rm -rf "$base_dir/plugins/crux"
            cat <<OC1_EOF > "$base_dir/plugins/crux.js"
// CRUX-OPENCODE-BRIDGE v1
import { spawnSync, spawn } from "node:child_process";
const HOOK = ${hook_js};
const FALLBACK_SID = "opencode-" + process.pid + "-" + Date.now().toString(36);
function runCrux(args, payload, canBlock, syncStart) {
  if (!canBlock && !syncStart) {
    try {
      const c = spawn("bash", [HOOK, ...args, "--harness=opencode"], { stdio: ["pipe", "ignore", "ignore"], detached: true });
      c.on("error", () => {}); c.stdin.on("error", () => {});
      c.stdin.end(JSON.stringify(payload)); c.unref();
    } catch (_) {}
    return;
  }
  const r = spawnSync("bash", [HOOK, ...args, "--harness=opencode"], { input: JSON.stringify(payload), encoding: "utf8", timeout: 20000 });
  if (canBlock && (r.error || r.status === 2)) throw new Error(((r.stderr || (r.error && r.error.message)) || "Blocked by crux").trim());
}
export const CruxPlugin = async ({ directory }) => {
  const cwd = directory || process.cwd();
  const started = new Set();
  const ensureStart = (sid) => {
    if (started.has(sid)) return;
    started.add(sid);
    runCrux(["SessionStart"], { hook_event_name: "SessionStart", session_id: sid, cwd }, false, true);
  };
  return {
    "tool.execute.before": async (input, output) => {
      const sid = (input && input.sessionID) || FALLBACK_SID;
      ensureStart(sid);
      runCrux(["PreToolUse"], { hook_event_name: "PreToolUse", tool_name: input.tool, tool_input: (output && output.args) || input.args || {}, session_id: sid, cwd }, true, false);
    },
    "tool.execute.after": async (input) => {
      const sid = (input && input.sessionID) || FALLBACK_SID;
      runCrux(["PostToolUse"], { hook_event_name: "PostToolUse", tool_name: input.tool, session_id: sid, cwd }, false, false);
    },
    event: async ({ event }) => {
      if (event && event.type === "session.idle") {
        const sid = (event.properties && event.properties.sessionID) || event.sessionID || FALLBACK_SID;
        runCrux(["Stop", "--observer"], { hook_event_name: "Stop", session_id: sid, cwd }, false, false);
      }
    }
  };
};
OC1_EOF
            note "==> [$NAME] Installed OpenCode v1 bridge plugin at $base_dir/plugins/crux.js"
            ;;
    esac
}

install_verify_runner() {
    cat <<'VER_EOF' > "$SDIR/hooks/verify.sh"
#!/usr/bin/env bash
unset BASH_ENV
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 125
cd "$ROOT" || exit 125
CMD_FILE="$ROOT/.crux/verify.command"
if [ ! -s "$CMD_FILE" ]; then
    echo "No verification command configured. Run: crux gate '<cmd>'" >&2
    exit 78
fi
HUB_DIR=@@HUB@@
sha() {
    local h
    if command -v sha256sum >/dev/null 2>&1; then h="$(sha256sum)" || return 1
    elif command -v shasum >/dev/null 2>&1; then h="$(shasum -a 256)" || return 1
    else h="$(git hash-object --stdin)" || return 1; fi
    printf '%s\n' "${h%% *}"
}
G="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
KEY="$(printf '%s' "${G:-$ROOT}" | sha | cut -c1-16)"
BASE="$(cat "$HUB_DIR/trust/$KEY" 2>/dev/null || true)"
CUR="$(sha < "$CMD_FILE")"
if [ -z "$BASE" ] || [ "$CUR" != "$BASE" ]; then
    echo "ERROR: .crux/verify.command is not trusted on this machine. Review it, then run: crux gate --accept" >&2
    exit 97
fi
exec bash --noprofile --norc "$CMD_FILE"
VER_EOF
    chmod +x "$SDIR/hooks/verify.sh"
}

case "$CMD" in
    init)
        SILENT=0; WS=0
        for a in "$@"; do
            case "$a" in --silent) SILENT=1; QUIET=1 ;; --workspace) WS=1 ;; esac
        done
        case "$CWD" in "$HOME"|/|"$HOME/Downloads"|"$HOME/Desktop") die "Refusing to initialize '$CWD'." ;; esac
        if [ "$WS" = 1 ]; then
            DEST="$CWD"
        elif [ -n "$(git_top)" ]; then
            DEST="$(git_top)"
        else
            git init -q "$CWD"
            DEST="$CWD"
            note "==> [$NAME] Initialized Git repository in $DEST"
        fi
        cd "$DEST" || exit 1
        OWNER_FILE="$DEST/$SDIR/local/bridge-owner"
        if [ -f "$OWNER_FILE" ]; then
            OWN="$(cat "$OWNER_FILE" 2>/dev/null || true)"
            [ -n "$OWN" ] && [ "$OWN" != "$HUB_DIR" ] && die "Repo is owned by another crux install ($OWN). Use that CLI or remove .crux/local/bridge-owner first."
        fi
        mkdir -p "$SDIR/hooks" "$SDIR/local/slots" "$SDIR/archive" "$SDIR/wiki-baselines"
        cp "${HUB_DIR}/hooks/on_event.sh" "$SDIR/hooks/on_event.sh"
        chmod +x "$SDIR/hooks/on_event.sh"
        install_verify_runner

        if [ "$WS" = 1 ] && [ ! -f "$SDIR/WORKSPACE" ]; then
            { echo "# Workspace member folders (one per line)"
              for d in */; do [ -e "${d}.git" ] && echo "${d%/}"; done; } > "$SDIR/WORKSPACE"
        fi

        if [ ! -s "$SDIR/verify.command" ]; then
            # Human-run init seeds & trusts (imports v4 Makefile recipe if present); silent auto-init never auto-trusts
            if [ "$SILENT" = 0 ] && TEST_CMD="$(legacy_gate_cmd || detect_test_cmd . 2>/dev/null)" && [ -n "$TEST_CMD" ]; then
                printf '%s\n' "$TEST_CMD" > "$SDIR/verify.command"
                trust_gate
            fi
        elif [ "$SILENT" = 0 ] && ! trusted_gate; then
            note "==> [$NAME] .crux/verify.command exists but is NOT trusted on this machine. Review it, then run: $NAME gate --accept"
        fi

        MKF="$(pick_makefile)"
        if [ ! -f "$MKF" ]; then
            printf '# crux:managed-agent-verify\n.PHONY: agent-verify\n\nagent-verify:\n\t@bash .crux/hooks/verify.sh\n' > "$MKF"
        elif ! grep -q '^agent-verify[[:space:]]*:' "$MKF"; then
            printf '\n# crux:managed-agent-verify\n.PHONY: agent-verify\nagent-verify:\n\t@bash .crux/hooks/verify.sh\n' >> "$MKF"
        elif [ "$SILENT" = 0 ] && ! grep -qF '# crux:managed-agent-verify' "$MKF"; then
            # Upgrade legacy v4 agent-verify recipe to the sealed v5 runner
            awk '
                /^agent-verify[[:space:]]*:/ && !done {
                    print "# crux:managed-agent-verify"
                    print ".PHONY: agent-verify"
                    print "agent-verify:"
                    print "\t@bash .crux/hooks/verify.sh"
                    done=1; skip=1; next
                }
                skip && /^\t/ { next }
                skip { skip=0 }
                { print }
            ' "$MKF" > "$MKF.tmp.$$" && mv -f "$MKF.tmp.$$" "$MKF"
        fi

        if [ ! -f "$SDIR/PLAN.md" ]; then
            cat <<'P_EOF' > "$SDIR/PLAN.md"
# Active Engineering Plan (.crux/PLAN.md)
# (Editable anytime in your human editor or via 'crux plan'; protected against AI overwrites)

## 1. NORTH STAR & IMMUTABLE CONSTRAINTS
- Objective: Production-grade implementation verified by `make agent-verify`.

## 2. SCOPE FENCE
- IN-SCOPE: Files listed in the active task below.
- OUT-OF-SCOPE: Unrelated modules and unapproved dependencies.

## 3. ATOMIC EXECUTION TASKS
- [ ] T1: Define initial feature spec and tests | files: src/ | accept: tests exit 0 | verify: make agent-verify
P_EOF
        fi
        chmod 644 "$SDIR/PLAN.md" 2>/dev/null || true
        [ -f "$SDIR/local/plan.base" ] || cp "$SDIR/PLAN.md" "$SDIR/local/plan.base"

        if [ ! -f "$SDIR/PROGRESS.md" ]; then
            cat <<'PR_EOF' > "$SDIR/PROGRESS.md"
# Completed Task Ledger (.crux/PROGRESS.md)
# Append-only, NEVER rotated. Check here before starting any task in .crux/PLAN.md.
# Format: - [x] <TaskID> | <short-sha> | <harness> | <YYYY-MM-DD> | <1-line summary>
PR_EOF
        fi
        [ -f "$SDIR/local/progress.base" ] || cp "$SDIR/PROGRESS.md" "$SDIR/local/progress.base"
        touch "$SDIR/PROPOSALS.md" "$SDIR/DECISIONS.md"
        index_sync

        GCOMM="$(git rev-parse --git-common-dir 2>/dev/null || true)"
        if [ -n "$GCOMM" ]; then
            mkdir -p "$GCOMM/info"
            grep -qxF '.crux/PROGRESS.md merge=union' "$GCOMM/info/attributes" 2>/dev/null || printf '\n.crux/PROGRESS.md merge=union\n' >> "$GCOMM/info/attributes"
        fi

        NOW="$(date '+%Y-%m-%d %H:%M')"
        if [ ! -f "$SDIR/PROJECT_STATE.md" ]; then
            cat <<S_EOF > "$SDIR/PROJECT_STATE.md"
# Chronological Project State & Receipts (.crux/PROJECT_STATE.md)

## [$NOW] | Session #0 | $NAME init | Task T0
- Verified Receipt: Initialized $NAME v@@VERSION@@
- Touched Files: .crux/ created
- Next Deterministic Action: Paste plan into .crux/PLAN.md (or run '$NAME plan') and configure '$NAME gate <cmd>'
S_EOF
        fi
        [ -f "$SDIR/local/checkpoint.txt" ] || echo "[In-Flight Checkpoint]: $NOW READY | Initialized" > "$SDIR/local/checkpoint.txt"

        [ -f .gitignore ] || : > .gitignore
        for ig in ".crux/local/" ".crux/.exempt" "*.crux-orig.bak"; do
            grep -qxF "$ig" .gitignore 2>/dev/null || printf '\n%s\n' "$ig" >> .gitignore
        done

        note "==> [$NAME] Ready in $DEST (state inside .crux/)."
        ;;

    done)
        need_root
        TASK_ID="${1:-}"
        [ -n "$TASK_ID" ] || die "Usage: $NAME done <TaskID> [summary]"
        case "$TASK_ID" in *[!A-Za-z0-9._-]*) die "Invalid TaskID: $TASK_ID" ;; esac
        shift || true
        NOTE_TXT="${*:-completed}"
        case "$NOTE_TXT" in *$'\n'*|*$'\r'*|*"|"*) die "Summary must be a single line without '|'." ;; esac
        [ -f "$SDIR/PROGRESS.md" ] || printf '# Completed Task Ledger (.crux/PROGRESS.md)\n' > "$SDIR/PROGRESS.md"
        if awk -v id="$TASK_ID" '$1=="-" && $2=="[x]" && $3==id {f=1} END{exit !f}' "$SDIR/PROGRESS.md"; then
            die "Task '$TASK_ID' is already logged in .crux/PROGRESS.md."
        fi
        SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'no-commit')"
        DT="$(date '+%Y-%m-%d')"
        printf -- '- [x] %s | %s | human | %s | %s\n' "$TASK_ID" "$SHA" "$DT" "$NOTE_TXT" >> "$SDIR/PROGRESS.md"
        cp "$SDIR/PROGRESS.md" "$LOCAL/progress.base"
        echo "==> [$NAME] Logged $TASK_ID in .crux/PROGRESS.md ($SHA)"
        ;;

    plan)
        SOURCE="${1:-}"
        if [ -n "$SOURCE" ]; then
            case "$SOURCE" in /*) ;; *) SOURCE="$CWD/$SOURCE" ;; esac
        fi
        need_root
        tmp="$(mktemp "$SDIR/PLAN.md.XXXXXX")" || die "Cannot stage plan."
        RC=0
        if [ -n "$SOURCE" ]; then
            cp "$SOURCE" "$tmp" || RC=$?
        elif [ ! -t 0 ]; then
            cat > "$tmp" || RC=$?
        elif have wl-paste; then wl-paste > "$tmp" || RC=$?
        elif have xclip; then xclip -o -selection clipboard > "$tmp" || RC=$?
        elif have pbpaste; then pbpaste > "$tmp" || RC=$?
        elif have powershell.exe; then powershell.exe -NoProfile -Command Get-Clipboard | tr -d '\r' > "$tmp" || RC=$?
        else RC=1; fi
        if [ "$RC" -ne 0 ] || [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            die "Plan import failed or empty; existing .crux/PLAN.md preserved."
        fi
        chmod 644 "$tmp"
        mv -f "$tmp" "$SDIR/PLAN.md"
        cp "$SDIR/PLAN.md" "$LOCAL/plan.base"
        echo "==> [$NAME] Updated & locked .crux/PLAN.md ($(wc -l < "$SDIR/PLAN.md" | tr -d ' ') lines)."
        ;;

    gate)
        need_root
        if [ "${1:-}" = "--accept" ]; then
            [ -s "$SDIR/verify.command" ] || die "No .crux/verify.command to accept."
            bash -n "$SDIR/verify.command" || die "Invalid Bash syntax in .crux/verify.command; refusing to trust."
            trust_gate
            echo "==> [$NAME] Trusted & sealed .crux/verify.command on this machine."
            exit 0
        fi
        NEW_CMD="$*"
        [ -n "$NEW_CMD" ] || NEW_CMD="$(detect_test_cmd . 2>/dev/null || true)"
        [ -n "$NEW_CMD" ] || die "Usage: $NAME gate '<command>'"
        tmp="$(mktemp "$SDIR/verify.command.XXXXXX")" || die "Cannot stage gate command."
        printf '%s\n' "$NEW_CMD" > "$tmp"
        bash -n "$tmp" || { rm -f "$tmp"; die "Invalid Bash syntax in verification command."; }
        mv -f "$tmp" "$SDIR/verify.command"
        trust_gate
        echo "==> [$NAME] Sealed & trusted verification gate (.crux/verify.command) -> $NEW_CMD"
        ;;

    wiki-mark)
        need_root
        MEMBER="${1:-.}"
        WIKI="${2:-.qoder/repowiki}"
        SRC_COMMIT="${3:-HEAD}"
        [ -d "$ROOT/$MEMBER/$WIKI" ] || die "Wiki directory not found: $MEMBER/$WIKI"
        BASE="$(git -C "$ROOT/$MEMBER" rev-parse --verify "${SRC_COMMIT}^{commit}" 2>/dev/null || true)"
        [ -n "$BASE" ] || die "Invalid commit: $SRC_COMMIT"
        mkdir -p "$SDIR/wiki-baselines"
        KEY="$(wiki_key "$MEMBER" "$WIKI")"
        printf '%s\n' "$BASE" > "$SDIR/wiki-baselines/$KEY"
        index_sync
        echo "==> [$NAME] Baselined $MEMBER/$WIKI at ${BASE:0:8}"
        ;;

    verify)
        need_root
        jq -nc --arg cwd "$ROOT" '{hook_event_name:"Stop", session_id:"manual-verify", cwd:$cwd}' \
            | bash "$HUB_DIR/hooks/on_event.sh" Stop --manual-verify
        exit $?
        ;;

    exempt|clear)
        CLEAR=0; [ "$CMD" = "clear" ] && CLEAR=1
        for a in "$@"; do [ "$a" = "--clear" ] || [ "$a" = "--purge" ] && CLEAR=1; done
        TARGET="${ROOT:-$(git_top)}"; TARGET="${TARGET:-$CWD}"
        if [ "$CLEAR" = 1 ] && [ -d "$TARGET/$SDIR" ]; then
            BAK_DIR="$HUB_DIR/purge-backups"
            # Never store a purge backup inside the directory about to be deleted (--local mode)
            case "$BAK_DIR/" in "$TARGET/$SDIR/"*) BAK_DIR="${TMPDIR:-/tmp}/crux-purge-backups" ;; esac
            mkdir -p "$BAK_DIR"
            bak="$BAK_DIR/$(basename "$TARGET")-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
            ( cd "$TARGET" && tar -czf "$bak" "$SDIR" ) || die "Backup failed; $TARGET/$SDIR preserved."
            tar -tzf "$bak" >/dev/null || die "Backup verification failed; $TARGET/$SDIR preserved."
            rm -rf "$TARGET/$SDIR"
            echo "==> [$NAME] Cleared $TARGET/.crux/ (verified backup at $bak)."
        fi
        if [ "$CMD" = "exempt" ]; then
            if [ "$CLEAR" = 0 ]; then
                mkdir -p "$TARGET/$SDIR"
                touch "$TARGET/$SDIR/.exempt"
            fi
            grep -Fxq "$TARGET" "$HUB_DIR/exempt.list" 2>/dev/null || echo "$TARGET" >> "$HUB_DIR/exempt.list"
            echo "==> [$NAME] Exempted $TARGET (and all subfolders)."
        fi
        ;;

    unexempt)
        TARGET="${ROOT:-$(git_top)}"; TARGET="${TARGET:-$CWD}"
        rm -f "$TARGET/$SDIR/.exempt" "$TARGET/.crux-ignore"
        tmp="$(mktemp "$HUB_DIR/exempt.list.XXXXXX")"
        grep -Fxv "$TARGET" "$HUB_DIR/exempt.list" > "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$HUB_DIR/exempt.list"
        echo "==> [$NAME] Un-exempted $TARGET."
        ;;

    mode)
        case "${1:-}" in
            auto)   echo "true" > "$HUB_DIR/auto_init.conf"; echo "==> [$NAME] Mode: AUTO-INIT" ;;
            manual) echo "false" > "$HUB_DIR/auto_init.conf"; echo "==> [$NAME] Mode: MANUAL" ;;
            *)      echo "Current mode: $(cat "$HUB_DIR/auto_init.conf" 2>/dev/null || echo false)" ;;
        esac
        ;;

    hooks)
        ACT="add"; SCOPE="global"; FAILED=0
        for a in "$@"; do
            case "$a" in
                --remove) ACT="remove" ;;
                --local)  SCOPE="local" ;;
                *) die "Unknown hooks flag: $a" ;;
            esac
        done
        if [ "$SCOPE" = "local" ]; then
            need_root
            if [ -d "$ROOT/.claude" ] || have claude; then merge_json_hooks "$ROOT/.claude/settings.local.json" "$ACT" claude || FAILED=1; fi
            if [ -d "$ROOT/.qoder" ] || [ -d "${HOME}/.qoder" ] || have qoder; then merge_json_hooks "$ROOT/.qoder/settings.json" "$ACT" qoder || FAILED=1; fi
            if [ -d "$ROOT/.opencode" ] || [ -d "${HOME}/.config/opencode" ] || have opencode; then install_opencode_plugin "$ROOT/.opencode" "$ACT" || FAILED=1; fi
            if [ -d "$ROOT/.agents" ] || [ -d "${HOME}/.gemini" ] || have antigravity || have agy; then merge_agy_hooks "$ROOT/.agents/hooks.json" "$ACT" || FAILED=1; fi
            if [ "$ACT" = "add" ] && [ "$FAILED" = 0 ]; then
                printf '%s\n' "$HUB_DIR" > "$ROOT/$SDIR/local/bridge-owner"
            elif [ "$ACT" = "remove" ]; then
                rm -f "$ROOT/$SDIR/local/bridge-owner"
            fi
            if [ -d "${HOME}/.zcode" ] || have zcode; then
                note "==> [$NAME] NOTE: ZCode workspace hooks require manual Trust in Settings; use global install for zero-prompt ZCode hooks."
            fi
        else
            if [ -d "${HOME}/.claude" ] || have claude; then merge_json_hooks "${HOME}/.claude/settings.json" "$ACT" claude || FAILED=1; fi
            if [ -d "${HOME}/.qoder" ] || have qoder; then merge_json_hooks "${HOME}/.qoder/settings.json" "$ACT" qoder || FAILED=1; fi
            if [ -d "${HOME}/.zcode" ] || have zcode; then merge_zcode_hooks "${HOME}/.zcode/cli/config.json" "$ACT" || FAILED=1; fi
            if [ -d "${HOME}/.config/opencode" ] || have opencode; then install_opencode_plugin "${HOME}/.config/opencode" "$ACT" || FAILED=1; fi
            if [ -d "${HOME}/.gemini" ] || have antigravity || have agy; then merge_agy_hooks "${HOME}/.gemini/config/hooks.json" "$ACT" || FAILED=1; fi
        fi
        exit "$FAILED"
        ;;

    update)
        LOCAL_UPD=0; [ "${1:-}" = "--local" ] && LOCAL_UPD=1
        if [ "$LOCAL_UPD" = 0 ] && [ -d "$HUB_DIR/.git" ]; then
            echo "==> [$NAME] Pulling latest from GitHub ($HUB_DIR)..."
            git -C "$HUB_DIR" pull --ff-only || echo "WARN: git pull skipped (local edits or offline)."
        fi
        INST=""
        [ -f "$HUB_DIR/install.sh" ] && INST="$HUB_DIR/install.sh"
        if [ -n "$INST" ]; then
            if [ "$LOCAL_UPD" = 1 ]; then
                bash "$INST" --local --name "$NAME" || exit 1
            else
                MODE_FLAG="--manual"
                [ "$(cat "$HUB_DIR/auto_init.conf" 2>/dev/null || echo false)" = "true" ] && MODE_FLAG="--auto"
                bash "$INST" "$MODE_FLAG" --name "$NAME" || exit 1
            fi
        fi
        if [ -n "$ROOT" ] && [ -d "$ROOT/$SDIR" ]; then
            WSF=""; [ -f "$ROOT/$SDIR/WORKSPACE" ] && WSF="--workspace"
            ( cd "$ROOT" && "$BIN_DIR/$NAME" init $WSF ) || echo "WARN: repo refresh failed" >&2
        fi
        ;;

    uninstall)
        SCOPE="$(cat "$HUB_DIR/install_scope" 2>/dev/null || echo false)"
        if [ "$SCOPE" = "true" ]; then
            "$BIN_DIR/$NAME" hooks --local --remove || echo "WARN: some local bridges could not be removed." >&2
            [ -n "$ROOT" ] && rm -f "$ROOT/$SDIR/local/bridge-owner"
        else
            "$BIN_DIR/$NAME" hooks --remove || echo "WARN: some global bridges could not be removed." >&2
        fi
        rm -f "$BIN_DIR/$NAME"
        echo "==> [$NAME] Removed CLI binary and hook/plugin entries. (Repo .crux/ folders left intact.)"
        ;;

    index-sync)
        QUIET=1; need_root; index_sync
        ;;

    canary)
        need_root
        HOOK_LIVE="${HUB_DIR}/hooks/on_event.sh"
        [ -x "$HOOK_LIVE" ] || die "hub hook missing at $HOOK_LIVE; re-run install.sh"
        echo "==> [$NAME] Running live 8-check Canary Self-Test ($HOOK_LIVE)..."
        jq -nc --arg cwd "$ROOT" '{hook_event_name:"SessionStart", session_id:"canary", cwd:$cwd}' | bash "$HOOK_LIVE" SessionStart >/dev/null || die "SessionStart failed"
        echo "  [1/8] SessionStart: OK"
        RC=0
        jq -nc --arg cwd "$ROOT" '{hook_event_name:"PreToolUse", tool_name:"Read", tool_input:{file_path:".env.production"}, cwd:$cwd}' | bash "$HOOK_LIVE" PreToolUse 2>/dev/null || RC=$?
        [ "$RC" -eq 2 ] && echo "  [2/8] PreToolUse (.env shield): OK (exit 2)" || die "PreToolUse failed to block .env.production"
        RC=0
        jq -nc --arg cwd "$ROOT" '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:"src/../.crux/PLAN.md"}, cwd:$cwd}' | bash "$HOOK_LIVE" PreToolUse 2>/dev/null || RC=$?
        [ "$RC" -eq 2 ] && echo "  [3/8] PreToolUse (PLAN.md ../ bypass blocked): OK (exit 2)" || die "Failed to block src/../.crux/PLAN.md"
        RC=0
        jq -nc --arg cwd "$ROOT" '{hook_event_name:"PreToolUse", tool_name:"search_replace", tool_input:{file_path:".crux/hooks/on_event.sh"}, cwd:$cwd}' | bash "$HOOK_LIVE" PreToolUse 2>/dev/null || RC=$?
        [ "$RC" -eq 2 ] && echo "  [4/8] PreToolUse (search_replace write fence): OK (exit 2)" || die "search_replace bypassed write fence"
        RC=0
        jq -nc --arg cwd "$ROOT" '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:".crux/PROGRESS.md"}, cwd:$cwd}' | bash "$HOOK_LIVE" PreToolUse 2>/dev/null || RC=$?
        [ "$RC" -eq 0 ] && echo "  [5/8] PreToolUse (PROGRESS.md writable): OK" || die "Unexpectedly blocked .crux/PROGRESS.md"
        AGY_OUT="$(jq -nc --arg cwd "$ROOT" --arg p "$ROOT/.env" '{conversationId:"canary-agy", workspacePaths:[$cwd], toolCall:{name:"view_file", args:{AbsolutePath:$p}}}' | bash "$HOOK_LIVE" PreToolUse --agy 2>/dev/null || true)"
        echo "$AGY_OUT" | jq -e '.decision == "deny"' >/dev/null 2>&1 && echo "  [6/8] Antigravity (--agy JSON deny): OK" || die "Antigravity JSON deny failed ($AGY_OUT)"
        AGY_UNK="$(printf '{}' | bash "$HOOK_LIVE" UnknownEvent --agy 2>/dev/null || true)"
        echo "$AGY_UNK" | jq -e 'type == "object"' >/dev/null 2>&1 && echo "  [7/8] Antigravity (unknown event safe allow): OK" || die "Antigravity unknown event failed ($AGY_UNK)"
        RC=0
        jq -nc --arg cwd "$ROOT" '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:"rm -rf .crux"}, cwd:$cwd}' | bash "$HOOK_LIVE" PreToolUse 2>/dev/null || RC=$?
        [ "$RC" -eq 2 ] && echo "  [8/8] PreToolUse (rm -rf .crux blocked): OK (exit 2)" || die "Failed to block rm -rf .crux"
        echo "==> [$NAME] All 8 Canary Checks PASSED."
        ;;

    status)
        chk_file() { [ -f "$1" ] && grep -q "$2" "$1" 2>/dev/null && echo "REGISTERED ($1)" || echo "missing"; }
        echo "=============================================================================="
        echo " $NAME v$(cat "$HUB_DIR/VERSION" 2>/dev/null || echo '@@VERSION@@') — Status"
        echo "   Hub:      $HUB_DIR | Auto-Init: $(cat "$HUB_DIR/auto_init.conf" 2>/dev/null || echo false)"
        echo "   RAM:      0 MB background (event-driven Bash 3.2+ hook)"
        if [ -n "$ROOT" ]; then
            DONE_CNT="$(awk '/^- \[x\]/ {n++} END {print n+0}' "$ROOT/$SDIR/PROGRESS.md" 2>/dev/null)"
            echo "   Project:  $ROOT ($SDIR/)"
            echo "   State:    $(cat "$ROOT/$SDIR/local/checkpoint.txt" 2>/dev/null || echo 'READY')"
            echo "   Progress: $DONE_CNT completed task(s) in .crux/PROGRESS.md"
            if [ -s "$ROOT/$SDIR/verify.command" ]; then
                ( cd "$ROOT" && trusted_gate ) && echo "   Gate:     TRUSTED (.crux/verify.command)" || echo "   Gate:     UNTRUSTED (review .crux/verify.command, then '$NAME gate --accept')"
            else
                echo "   Gate:     NOT CONFIGURED (run '$NAME gate <cmd>')"
            fi
        else
            echo "   Project:  Not initialized here (run '$NAME init')"
        fi
        echo "   Enforced Bridges (Global):"
        echo "     - Claude:      $(chk_file "${HOME}/.claude/settings.json" "on_event.sh")"
        echo "     - Qoder:       $(chk_file "${HOME}/.qoder/settings.json" "on_event.sh")"
        echo "     - ZCode:       $(chk_file "${HOME}/.zcode/cli/config.json" "on_event.sh")"
        echo "     - Antigravity: $(chk_file "${HOME}/.gemini/config/hooks.json" "on_event.sh")"
        OC_ST="missing"
        { [ -f "${HOME}/.config/opencode/plugins/crux.js" ] || [ -f "${HOME}/.config/opencode/plugins/crux/index.js" ]; } && OC_ST="REGISTERED (${HOME}/.config/opencode/plugins/)"
        echo "     - OpenCode:    $OC_ST"
        if [ -n "$ROOT" ]; then
            echo "   Local Repo Bridges (opt-in via '$NAME hooks --local'):"
            echo "     - Claude:      $(chk_file "$ROOT/.claude/settings.local.json" "on_event.sh")"
            echo "     - Qoder:       $(chk_file "$ROOT/.qoder/settings.json" "on_event.sh")"
            echo "     - Antigravity: $(chk_file "$ROOT/.agents/hooks.json" "on_event.sh")"
            LOC_OC="missing"
            { [ -f "$ROOT/.opencode/plugins/crux.js" ] || [ -f "$ROOT/.opencode/plugins/crux/index.js" ]; } && LOC_OC="REGISTERED ($ROOT/.opencode/plugins/)"
            echo "     - OpenCode:    $LOC_OC"
        fi
        echo "   Rules-Only Harnesses (No Native Hook Bridge):"
        echo "     - DeepSeek:    $(chk_file "${HOME}/.dsh/AGENTS.md" "crux:soul:begin")"
        echo "     - MiniMax:     $(chk_file "${HOME}/.minimax/AGENTS.md" "crux:soul:begin")"
        echo "     - Codex:       $(chk_file "${HOME}/.codex/AGENTS.md" "crux:soul:begin")"
        echo "------------------------------------------------------------------------------"
        echo "   Commands: $NAME init | $NAME plan | $NAME done <ID> | $NAME gate '<cmd>' | $NAME wiki-mark | $NAME verify | $NAME canary"
        echo "=============================================================================="
        ;;

    *)
        die "Unknown command '$CMD'. Valid: init | plan | done | gate | wiki-mark | verify | hooks | status | canary | mode | exempt | unexempt | clear | update | uninstall"
        ;;
esac
CLI_EOF

CLI_OUT="$(mktemp "${BIN_DIR}/${CLI_NAME}.out.XXXXXX")"
sed -e "s|@@HUB@@|${HUB_ESC}|g" -e "s|@@BIN@@|${BIN_ESC}|g" -e "s|@@VERSION@@|${VER_ESC}|g" -e "s|@@NAME@@|${NAME_ESC}|g" \
    "${CLI_TMPL}" > "${CLI_OUT}"
rm -f "${CLI_TMPL}"
bash -n "${CLI_OUT}" || { rm -f "${CLI_OUT}"; echo "ERROR: generated ${CLI_NAME} CLI failed syntax check."; exit 1; }
chmod +x "${CLI_OUT}"
mv -f "${CLI_OUT}" "${DEST_BIN}"

if [ "${LOCAL_ONLY}" = "true" ]; then
    "${DEST_BIN}" init
    echo "=============================================================================="
    echo " ${CLI_NAME} v${CRUX_VERSION} Installed in ISOLATED LOCAL MODE (Zero Global Changes)"
    echo "   Hub & CLI:      ${REPO_TOP}/.crux/local/{hub,bin/${CLI_NAME}}"
    echo "   Root Clutter:   Zero harness config files written automatically."
    echo "   Activate Hooks: Run '${DEST_BIN} hooks --local' to opt into repo-local bridge files"
    echo "                   (.claude/, .qoder/, .opencode/, .agents/hooks.json)."
    echo "   Test Command:   ${DEST_BIN} canary"
    echo "=============================================================================="
else
    if ! "${DEST_BIN}" hooks; then
        echo "WARN: One or more harness bridges failed to register. Run '${CLI_NAME} status' to inspect." >&2
    fi
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [ -f "$rc" ] && ! grep -qF "${BIN_DIR}" "$rc" 2>/dev/null; then
            printf '\nexport PATH="%s:${PATH}"\n' "${BIN_DIR}" >> "$rc"
        fi
    done
    echo "=============================================================================="
    echo " ${CLI_NAME} v${CRUX_VERSION} Installed (Linux / WSL2 / macOS Bash 3.2+)"
    echo "   Enforced Bridges: Claude Code, Qoder, ZCode (hooks.events), OpenCode (v1/v2), Antigravity (hooks.json)"
    echo "   Rules-Only:       DeepSeek Harness (dsh), MiniMax Code (mcode), Codex"
    echo "   Verify Setup:     ${CLI_NAME} status && ${CLI_NAME} canary"
    echo "=============================================================================="
fi
