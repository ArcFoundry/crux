#!/usr/bin/env bash
# ==============================================================================
# crux v4.2.0 — Zero-Friction, Zero-Daemon Multi-Harness Agentic Layer
# 100% Contained Inside `.crux/` (Zero Root File Clutter)
# Compatible with: macOS (bash 3.2+), Linux (WSL2, Ubuntu, Debian, Arch, Fedora, Alpine), Git-Bash
# Harnesses: Qoder, ZCode, OpenCode (v1 & v2), Claude Code, Antigravity/Gemini, MiniMax Code (mcode), DeepSeek (dsh), Codex
# Hard deps: bash (3.2+), git, awk, grep, sed, find, cksum, tar
# Optional deps (auto-detected): jq (exact JSON parsing & hook merge), timeout/gtimeout
# Footprint: 0 MB background RAM | ~40 KB disk | ~5-12 ms per hook invocation
# ==============================================================================
unset BASH_ENV
set -euo pipefail

CRUX_VERSION="4.2.0"
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
        --name)   shift; CLI_NAME="${1:-crux}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown flag: $1"; usage; exit 1 ;;
    esac
    shift
done

for c in git awk grep sed find cksum tar; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: required tool '$c' not found."; exit 1; }
done

# Collision guard: never overwrite an unrelated system binary
EXISTING="$(command -v "${CLI_NAME}" 2>/dev/null || true)"
if [ -n "${EXISTING}" ] && [ "${EXISTING}" != "${BIN_DIR}/${CLI_NAME}" ]; then
    if ! grep -q 'CRUX-CLI-MARKER' "${EXISTING}" 2>/dev/null; then
        echo "ERROR: '${CLI_NAME}' already exists on PATH at ${EXISTING} and is not ours."
        echo "       Re-run with: bash install.sh --name <other>"
        exit 1
    fi
fi

mkdir -p "${HUB_DIR}/hooks" "${HUB_DIR}/backups" "${HUB_DIR}/purge-backups" "${BIN_DIR}"
touch "${HUB_DIR}/exempt.list" "${HUB_DIR}/auto_roots.list"
echo "${CRUX_VERSION}" > "${HUB_DIR}/VERSION"

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

# ------------------------------------------------------------------------------
# 2. Global Home Layer Sync (~/.zcode/AGENTS.md, ~/.qoder/AGENTS.md, etc.)
#    Points every detected harness directly to ./.crux/ (zero root clutter),
#    while preserving 100% of each harness's native subagents & RepoWiki powers.
# ------------------------------------------------------------------------------
BUILDER_SOUL='<!-- crux:soul:begin -->
## Project Continuity & Contract (.crux/)
When `.crux/PLAN.md` exists in the current repository or workspace:
1. Read `.crux/INDEX.md`, `.crux/PLAN.md`, and `.crux/PROJECT_STATE.md` at the start of the session so you know the architecture, native wiki locations (`.qoder/repowiki/`, `.zcode/`, `.minimax/`, `docs/wiki/`), and what previous sessions completed.
2. Use all of your native capabilities (subagents, internal planning, RepoWiki, and tools) at full strength to implement the active task in `.crux/PLAN.md`, touching only the files relevant to that task.
3. `.crux/PLAN.md` is read-only to agents (after onboarding); if code reality contradicts `.crux/PLAN.md`, log the conflict in `.crux/PROPOSALS.md` and stop rather than altering `.crux/PLAN.md`.
4. Run `make agent-verify` (if present in `Makefile`) before claiming task completion.
<!-- crux:soul:end -->'

sync_global_soul() {
    local target="$1" dir tmp
    dir="$(dirname "$target")"
    mkdir -p "$dir"
    if [ -f "$target" ]; then
        cp "$target" "${HUB_DIR}/backups/$(basename "$dir")-$(basename "$target").bak" 2>/dev/null || true
        if grep -q "crux:soul:begin" "$target" 2>/dev/null; then
            tmp="${target}.tmp.$$"
            SOUL="$BUILDER_SOUL" awk '
                /crux:soul:begin/ { print ENVIRON["SOUL"]; skip=1; next }
                /crux:soul:end/   { skip=0; next }
                !skip { print }
            ' "$target" > "$tmp" && mv "$tmp" "$target"
        else
            printf '\n%s\n' "$BUILDER_SOUL" >> "$target"
        fi
    else
        printf '%s\n' "$BUILDER_SOUL" > "$target"
    fi
}

if [ "${LOCAL_ONLY}" = "false" ]; then
    { [ -d "${HOME}/.zcode" ]    || command -v zcode >/dev/null 2>&1; }    && sync_global_soul "${HOME}/.zcode/AGENTS.md"
    { [ -d "${HOME}/.qoder" ]    || command -v qoder >/dev/null 2>&1; }    && sync_global_soul "${HOME}/.qoder/AGENTS.md"
    { [ -d "${HOME}/.claude" ]   || command -v claude >/dev/null 2>&1; }   && sync_global_soul "${HOME}/.claude/CLAUDE.md"
    { [ -d "${HOME}/.gemini" ]   || command -v antigravity >/dev/null 2>&1 || command -v agy >/dev/null 2>&1 || command -v gemini >/dev/null 2>&1; } && sync_global_soul "${HOME}/.gemini/GEMINI.md"
    { [ -d "${HOME}/.config/opencode" ] || command -v opencode >/dev/null 2>&1; } && sync_global_soul "${HOME}/.config/opencode/AGENTS.md"
    { [ -d "${HOME}/.codex" ]    || command -v codex >/dev/null 2>&1; }    && sync_global_soul "${HOME}/.codex/AGENTS.md"
    { [ -d "${HOME}/.dsh" ]      || command -v dsh >/dev/null 2>&1; }      && sync_global_soul "${HOME}/.dsh/AGENTS.md"
    { [ -d "${HOME}/.minimax" ]  || [ -d "${HOME}/.minimax-code" ] || command -v mcode >/dev/null 2>&1; } && sync_global_soul "${HOME}/.minimax/AGENTS.md"
fi

# ------------------------------------------------------------------------------
# 3. Concurrency-Safe Hook Engine (`~/.crux-hub/hooks/on_event.sh`)
# ------------------------------------------------------------------------------
cat <<'HOOK_EOF' > "${HUB_DIR}/hooks/on_event.sh"
#!/usr/bin/env bash
# @@NAME@@ Hook Engine v@@VERSION@@ — Zero-Daemon Event Handler (Linux + macOS POSIX)
unset BASH_ENV
set -u
set -f

HUB_DIR="${CRUX_HOME:-@@HUB@@}"
BIN_DIR="${CRUX_BIN:-@@BIN@@}"
NAME="@@NAME@@"
SDIR=".crux"
[ "${CRUX_DISABLE:-0}" = "1" ] && exit 0

have() { command -v "$1" >/dev/null 2>&1; }
TIMEOUT_BIN=""
if have timeout; then TIMEOUT_BIN="timeout"; elif have gtimeout; then TIMEOUT_BIN="gtimeout"; fi
HAVE_JQ=0; have jq && HAVE_JQ=1

run_timeout() {
    local secs="$1"; shift
    if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi
}
block() { printf '%s\n' "$*" >&2; exit 2; }

PAYLOAD=""
if [ ! -t 0 ]; then
    if [ -n "$TIMEOUT_BIN" ]; then
        PAYLOAD="$("$TIMEOUT_BIN" 2 cat 2>/dev/null || true)"
    else
        PAYLOAD="$(cat 2>/dev/null || true)"
    fi
fi

jget() {
    if [ "$HAVE_JQ" = 1 ]; then
        printf '%s' "$PAYLOAD" | jq -r --arg k "$1" '(.[$k] // empty) | strings' 2>/dev/null | head -n1
    else
        printf '%s' "$PAYLOAD" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
    fi
}

EVENT="${1:-${CLAUDE_HOOK_EVENT:-${HOOK_EVENT_NAME:-}}}"
[ -z "$EVENT" ] && EVENT="$(jget hook_event_name)"
[ -z "$EVENT" ] && EVENT="$(jget hookEventName)"

case "$EVENT" in
    SessionStart|pre_llm_call) KIND="start" ;;
    PreToolUse|pre_tool_call)  KIND="pre" ;;
    PostToolUse|post_tool_call) KIND="post" ;;
    Stop|pre_verify)           KIND="stop" ;;
    SessionEnd)                KIND="end" ;;
    *) exit 0 ;;
esac

HCWD="$(jget cwd)"
if [ -n "$HCWD" ] && [ -d "$HCWD" ]; then cd "$HCWD" 2>/dev/null || true; fi
CWD0="$(pwd -P 2>/dev/null || pwd)"

# ---- Walk up to nearest initialized .crux/ root or nearest exemption ----
ROOT=""; EXD=""; d="$CWD0"; i=0
while [ -n "$d" ] && [ "$i" -lt 40 ]; do
    [ -z "$ROOT" ] && [ -f "$d/$SDIR/PROJECT_STATE.md" ] && ROOT="$d"
    if [ -z "$EXD" ]; then
        if [ -f "$d/$SDIR/.exempt" ] || [ -f "$d/.crux-ignore" ]; then EXD="$d"; fi
    fi
    [ "$d" = "/" ] && break
    d="${d%/*}"; [ -z "$d" ] && d="/"; i=$((i + 1))
done
if [ -s "$HUB_DIR/exempt.list" ]; then
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        case "$CWD0/" in "${e%/}"/*) if [ -z "$EXD" ] || [ "${#e}" -gt "${#EXD}" ]; then EXD="$e"; fi ;; esac
    done < "$HUB_DIR/exempt.list"
fi
if [ -n "$EXD" ]; then
    if [ -z "$ROOT" ] || [ "${#ROOT}" -le "${#EXD}" ]; then exit 0; fi
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
    case "$KIND" in start|pre) ;; *) exit 0 ;; esac
    GIT_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -z "$GIT_TOP" ] && exit 0
    GIT_TOP="$(cd "$GIT_TOP" && pwd -P)"
    auto_allowed "$GIT_TOP" || exit 0
    [ -x "$CLI" ] && ( cd "$GIT_TOP" && "$CLI" init --silent ) >/dev/null 2>&1
    [ -f "$GIT_TOP/$SDIR/PROJECT_STATE.md" ] && ROOT="$GIT_TOP"
    [ -z "$ROOT" ] && exit 0
fi

cd "$ROOT" || exit 0
STATE_FILE="$ROOT/$SDIR/PROJECT_STATE.md"
ARCHIVE_FILE="$ROOT/$SDIR/archive/PROJECT_STATE_ARCHIVE.md"
LOCAL_DIR="$ROOT/$SDIR/local"
SLOTS_DIR="$LOCAL_DIR/slots"
CKPT_FILE="$LOCAL_DIR/checkpoint.txt"
NOW="$(date '+%Y-%m-%d %H:%M')"
mkdir -p "$SLOTS_DIR" "$ROOT/$SDIR/archive" 2>/dev/null || exit 0

SID="$(jget session_id)"; [ -z "$SID" ] && SID="$(jget sessionId)"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"
AGENT_ID="${SID:-${CRUX_AGENT_ID:-shared}}"
AGENT_SLOT="$(printf '%s-%s' "$AGENT_ID" "$BRANCH" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)"
LOOP_FILE="$LOCAL_DIR/loop-$AGENT_SLOT.txt"
SLOT_FILE="$SLOTS_DIR/$AGENT_SLOT.status"
FAIL_FILE="$LOCAL_DIR/fail-$AGENT_SLOT"
STATE_LOCK="$LOCAL_DIR/state.lock"
VERIFY_LOCK="$LOCAL_DIR/verify.lock"
SLOT_TTL="${CRUX_SLOT_TTL_MIN:-10}"

# ---- PID-Verified Locks (only steals locks from dead PIDs) ----
HELD_LOCKS=""
nap() { sleep "$1" 2>/dev/null || sleep 1; }
acquire_lock() {
    local dir="$1" tries="${2:-150}" nz="${3:-0.02}" owner
    while ! mkdir "$dir" 2>/dev/null; do
        owner="$(cat "$dir/pid" 2>/dev/null || true)"
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$dir" 2>/dev/null; continue; fi
        if [ -z "$owner" ] && [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$dir" 2>/dev/null; continue; fi
        tries=$((tries - 1)); [ "$tries" -le 0 ] && return 1
        nap "$nz"
    done
    echo "$$" > "$dir/pid" 2>/dev/null
    HELD_LOCKS="$HELD_LOCKS $dir"; return 0
}
release_lock() { if [ "$(cat "$1/pid" 2>/dev/null || true)" = "$$" ]; then rm -rf "$1" 2>/dev/null; fi; }
release_all() { local x; for x in $HELD_LOCKS; do release_lock "$x"; done; }
trap release_all EXIT

members() {
    if [ -f "$ROOT/$SDIR/WORKSPACE" ]; then grep -vE '^[[:space:]]*(#.*)?$' "$ROOT/$SDIR/WORKSPACE"; else echo "."; fi
}
is_git() { git -C "$ROOT/$1" rev-parse --git-dir >/dev/null 2>&1; }
active_agents() { find "$SLOTS_DIR" -type f -mmin -"$SLOT_TTL" 2>/dev/null | wc -l | tr -d ' '; }
set_ckpt() {
    printf '[In-Flight Checkpoint]: %s %s\n' "$NOW" "$1" > "$CKPT_FILE.tmp.$$" 2>/dev/null && mv -f "$CKPT_FILE.tmp.$$" "$CKPT_FILE" 2>/dev/null
}
touched_list() {
    local m pre
    while IFS= read -r m; do
        [ -z "$m" ] && continue; is_git "$m" || continue
        pre=""; [ "$m" != "." ] && pre="$m/"
        git -C "$ROOT/$m" status --porcelain -- . ":(exclude)$SDIR" 2>/dev/null | sed "s#^...#${pre}#"
    done < <(members) | head -n "${1:-12}" | tr '\n' ' ' | sed 's/ *$//'
}
diff_stat() {
    local m out="" s
    while IFS= read -r m; do
        [ -z "$m" ] && continue; is_git "$m" || continue
        s="$(git -C "$ROOT/$m" diff HEAD --stat -- . ":(exclude)$SDIR" 2>/dev/null | tail -n1 | tr -s ' ' | sed 's/^ //')"
        [ -n "$s" ] && out="${out:+$out; }${m}: $s"
    done < <(members)
    printf '%s' "$out"
}
state_hash() {
    local m f n
    {
        while IFS= read -r m; do
            [ -z "$m" ] && continue; is_git "$m" || continue
            echo "== $m"
            git -C "$ROOT/$m" status --porcelain -- . ":(exclude)$SDIR" 2>/dev/null
            if git -C "$ROOT/$m" rev-parse --verify -q HEAD >/dev/null 2>&1; then
                git -C "$ROOT/$m" diff HEAD -- . ":(exclude)$SDIR" 2>/dev/null
            else
                git -C "$ROOT/$m" diff -- . ":(exclude)$SDIR" 2>/dev/null
                git -C "$ROOT/$m" diff --cached -- . ":(exclude)$SDIR" 2>/dev/null
            fi
            n=0
            while IFS= read -r -d '' f; do
                cksum "$ROOT/$m/$f" 2>/dev/null; n=$((n + 1)); [ "$n" -ge 500 ] && break
            done < <(git -C "$ROOT/$m" ls-files -o --exclude-standard -z -- . ":(exclude)$SDIR" 2>/dev/null)
        done < <(members)
    } | cksum | awk '{print $1 "-" $2}'
}
rotate_state() {
    local total keep drop
    keep="${CRUX_KEEP_BLOCKS:-8}"
    total="$(grep -c '^## \[' "$STATE_FILE" 2>/dev/null || true)"; total="${total:-0}"
    [ "$total" -gt "$keep" ] || return 0
    drop=$((total - keep))
    ARCH="$ARCHIVE_FILE" DROP="$drop" awk '
        /^## \[/ { b++ }
        { if (b > 0 && b <= ENVIRON["DROP"] + 0) print >> (ENVIRON["ARCH"]); else print }
    ' "$STATE_FILE" > "$STATE_FILE.tmp.$$" && mv -f "$STATE_FILE.tmp.$$" "$STATE_FILE"
}
write_receipt() {
    acquire_lock "$STATE_LOCK" 150 0.02 || return 0
    printf '\n## [%s] | Agent: %s | %s\n- Verified Receipt: %s\n- Touched Files: %s (%s)\n- Next Deterministic Action: %s\n' \
        "$NOW" "$AGENT_SLOT" "$1" "$2" "${TOUCHED:-clean tree}" "${DSTAT:-0 changes}" "$3" >> "$STATE_FILE"
    rotate_state
    release_lock "$STATE_LOCK"
}

# ---- Payload Extraction (Recursive jq for MultiEdit + camelCase/snake_case support) ----
TOOL="$(jget tool_name)"; [ -z "$TOOL" ] && TOOL="$(jget toolName)"; [ -z "$TOOL" ] && TOOL="$(jget name)"
TOOL_LC="$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')"

extract_paths() {
    if [ "$HAVE_JQ" = 1 ]; then
        printf '%s' "$PAYLOAD" | jq -r '(.tool_input // .toolInput // .input // .arguments // {}) | .. | objects | (.file_path, .path, .notebook_path, .filePath, .target_file, .file) | strings' 2>/dev/null
    else
        printf '%s' "$PAYLOAD" | grep -oE '"(file_path|path|notebook_path|filePath|target_file|file)"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
    fi
}
extract_command() {
    if [ "$HAVE_JQ" = 1 ]; then
        printf '%s' "$PAYLOAD" | jq -r '(.tool_input // .toolInput // .input // .arguments // {}) | if type=="object" then ((.command // .cmd // .script // empty) | if type=="array" then join(" ") else tostring end) elif type=="string" then . else empty end' 2>/dev/null
    else
        printf '%s' "$PAYLOAD" | grep -oE '"(command|cmd|script)"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n1 \
            | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//; s/\\"/"/g'
    fi
}
norm_rel() { local p="$1"; p="${p#"$ROOT"/}"; p="${p#./}"; printf '%s' "$p"; }

is_secret_path() {
    local p="$1" mode="${2:-path}" b
    b="${p##*/}"
    case "$b" in
        .env.example|.env.sample|.env.template|.env.dist|.env.defaults|*.pub) return 1 ;;
        .env|.env.*|*.pem|*.jks|*.keystore|*.p12|*.pfx|id_rsa|id_ed25519|id_ecdsa|.netrc) return 0 ;;
        *.key) if [ "$mode" = "path" ]; then return 0; fi; case "$p" in */*|"~"*) return 0 ;; esac; return 1 ;;
    esac
    return 1
}

SQ="'"; DQ='"'
QC="[${SQ}${DQ}]"
NQ="[^[:space:]${SQ}${DQ}]"
bash_mutates() {
    local cmd="$1" P="$2" END re
    END="(${QC}|[[:space:]]|[;&|)]|\$)"
    for re in \
        ">[[:space:]]*${QC}?${NQ}*(${P})${END}" \
        "(^|[^[:alnum:]_])tee[[:space:]][^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])(sed|perl|ruby)[[:space:]][^|;&]*(-[a-zA-Z]*i|--in-place)[^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])(mv|rm|truncate|ln|install|dd|shred|touch|chmod)[[:space:]][^|;&]*(${P})${END}" \
        "(^|[^[:alnum:]_])cp[[:space:]][^|;&]*(${P})${QC}?[[:space:]]*(\$|[;&|])" \
        "(^|[^[:alnum:]_])(python3?|node|perl|ruby)[[:space:]]+-[ce][^|;&]*(${P})"
    do
        if [[ "$cmd" =~ $re ]]; then return 0; fi
    done
    return 1
}
SOFT_RE='\.crux/PLAN\.md|\.crux/AGENTS\.md'
HARD_RE="\\.crux/hooks/${NQ}*|\\.crux/local/${NQ}*|\\.crux/\\.exempt|\\.crux-ignore|\\.crux-hub/${NQ}*|\\.crux/WORKSPACE"
is_write_tool() {
    case "$TOOL_LC" in *write*|*edit*|*patch*|*str_replace*|*create*|*replace*|*insert*|*update*|*append*|*delete*|*move*|*rename*) return 0 ;; esac
    return 1
}

# ===================================== Event Handlers ====================================
case "$KIND" in

start)
    MARK="$LOCAL_DIR/started-$AGENT_SLOT"
    if [ ! -f "$MARK" ] || [ -z "$(find "$MARK" -mmin -30 2>/dev/null)" ]; then
        touch "$MARK" 2>/dev/null
        [ -x "$CLI" ] && ( cd "$ROOT" && "$CLI" index-sync --quiet ) >/dev/null 2>&1 || true
    fi
    if grep -q 'IN-PROGRESS' "$CKPT_FILE" 2>/dev/null && [ "$(active_agents)" -eq 0 ]; then
        TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
        write_receipt "AUTO-RECOVERED INTERRUPTED SESSION" "Prior agent stopped mid-turn before verification" "Run git diff on touched files (${TOUCHED:-none}) and resume active task in .crux/PLAN.md"
        find "$SLOTS_DIR" -type f -exec rm -f {} + 2>/dev/null
        set_ckpt "RECOVERED ($BRANCH)"
        echo "[$NAME] Auto-recovered interrupted session. Uncommitted touched files: ${TOUCHED:-none}. Inspect git diff and check .crux/PROJECT_STATE.md."
    fi
    exit 0
    ;;

pre)
    PATHS="$(extract_paths)"; CMD="$(extract_command)"

    if [ -n "$PATHS" ]; then
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            is_secret_path "$p" path && block "SECURITY BLOCK [$NAME]: access to sensitive credential file '$p' is forbidden."
        done <<EOF_P
$PATHS
EOF_P
    fi
    if [ -n "$CMD" ]; then
        while IFS= read -r tok; do
            [ -z "$tok" ] && continue
            is_secret_path "$tok" cmd && block "SECURITY BLOCK [$NAME]: command references sensitive credential file '$tok'."
        done <<EOF_T
$(printf '%s\n' "$CMD" | tr -s '[:space:];|&<>()="'"'"'`' '\n')
EOF_T
        HUM='(^|[\;\&\|/[:space:]])(crux|cairn|verge|fortress)[[:space:]]+(exempt|unexempt|clear|purge|gate|mode|hooks|uninstall|plan)'
        if [[ "$CMD" =~ $HUM ]]; then
            block "CONTRACT BLOCK [$NAME]: '${BASH_REMATCH[2]} ${BASH_REMATCH[3]}' is human-only."
        fi
    fi

    if is_write_tool && [ -n "$PATHS" ]; then
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            rel="$(norm_rel "$p")"
            case "$rel" in
                .crux/hooks/*|.crux/local/*|.crux/.exempt|.crux/WORKSPACE)
                    block "CONTRACT BLOCK [$NAME]: '$rel' is internal state and never writable by agents." ;;
                .crux/PLAN.md|.crux/AGENTS.md)
                    if [ "$rel" = ".crux/PLAN.md" ] && grep -q 'crux:template' "$ROOT/$SDIR/PLAN.md" 2>/dev/null; then
                        : # Starter template: allow first-time onboarding write, then auto-locks once marker is replaced
                    else
                        block "CONTRACT BLOCK [$NAME]: '$rel' is READ-ONLY to agents (edit it directly in your human editor or run '$NAME plan'). Log blockers to .crux/PROPOSALS.md."
                    fi ;;
            esac
        done <<EOF_W
$PATHS
EOF_W
    fi
    if [ -n "$CMD" ]; then
        bash_mutates "$CMD" "$HARD_RE" && block "CONTRACT BLOCK [$NAME]: command modifies protected .crux internal files."
        if bash_mutates "$CMD" "$SOFT_RE"; then
            if ! grep -q 'crux:template' "$ROOT/$SDIR/PLAN.md" 2>/dev/null; then
                block "CONTRACT BLOCK [$NAME]: .crux/PLAN.md is READ-ONLY to agents. Log blockers in .crux/PROPOSALS.md."
            fi
        fi
    fi

    # 5x Identical Tool-Call Anti-Loop Breaker
    LOOP_MAX="${CRUX_LOOP_MAX:-5}"
    if [ -n "$PAYLOAD" ] && [ "$LOOP_MAX" -gt 0 ]; then
        SIG=""
        if [ "$HAVE_JQ" = 1 ]; then
            SIG="$(printf '%s' "$PAYLOAD" | jq -S -c '[(.tool_name // .toolName // .name), (.tool_input // .toolInput // .input // .arguments)]' 2>/dev/null | cksum | awk '{print $1}')"
        fi
        [ -z "$SIG" ] && SIG="$(printf '%s' "$PAYLOAD" | sed -E 's/"(tool_use_id|session_id|sessionId|transcript_path|timestamp|id|request_id)"[[:space:]]*:[[:space:]]*"[^"]*",?//g' | cksum | awk '{print $1}')"
        TS="$(date +%s)"; PH=""; PC=0; PT=0
        if [ -f "$LOOP_FILE" ]; then read -r PH PC PT < "$LOOP_FILE" 2>/dev/null || true; fi
        if [ "$SIG" = "$PH" ] && [ $((TS - ${PT:-0})) -le 120 ]; then PC=$((${PC:-0} + 1)); else PC=1; fi
        echo "$SIG $PC $TS" > "$LOOP_FILE"
        if [ "$PC" -ge "$LOOP_MAX" ]; then
            echo "$SIG 0 $TS" > "$LOOP_FILE"
            block "ANTI-LOOP FENCE [$NAME]: identical tool call repeated $PC times consecutively by $AGENT_SLOT. Change strategy or log blocker to .crux/PROPOSALS.md."
        fi
    fi
    exit 0
    ;;

post)
    find "$SLOTS_DIR" -type f -mmin +1440 -exec rm -f {} + 2>/dev/null
    TOUCHED="$(touched_list 4 | tr ' ' ',')"
    echo "[$NOW] Agent=$AGENT_SLOT | Touched=${TOUCHED:-none} | $(diff_stat)" > "$SLOT_FILE"
    set_ckpt "IN-PROGRESS (Active Agents: $(active_agents), Latest: $AGENT_SLOT) | Touched: ${TOUCHED:-none}"
    exit 0
    ;;

end)
    rm -f "$SLOT_FILE" "$LOOP_FILE" "$FAIL_FILE" "$LOCAL_DIR/started-$AGENT_SLOT"
    exit 0
    ;;

stop)
    [ -f "$LOCAL_DIR/gate.off" ] && { rm -f "$SLOT_FILE" "$LOOP_FILE"; set_ckpt "READY (gate off)"; exit 0; }
    MK=""
    for f in GNUmakefile makefile Makefile; do [ -f "$ROOT/$f" ] && { MK="$f"; break; }; done
    if [ -z "$MK" ] || ! grep -q '^agent-verify:' "$ROOT/$MK"; then
        rm -f "$SLOT_FILE" "$LOOP_FILE"; set_ckpt "READY (no agent-verify target)"; exit 0
    fi
    HASH_BEFORE="$(state_hash)"
    if [ "$HASH_BEFORE" = "$(cat "$LOCAL_DIR/last_verified" 2>/dev/null || true)" ]; then
        rm -f "$SLOT_FILE" "$LOOP_FILE"; set_ckpt "READY (tree unchanged since last green verify)"; exit 0
    fi
    VLOG="$LOCAL_DIR/verify-$AGENT_SLOT-$$.log"
    VTIMEOUT="${CRUX_VERIFY_TIMEOUT:-300}"; GOT_VLOCK=0
    acquire_lock "$VERIFY_LOCK" 200 0.5 && GOT_VLOCK=1
    run_timeout "$VTIMEOUT" make agent-verify >"$VLOG" 2>&1
    RC=$?
    [ "$GOT_VLOCK" = 1 ] && release_lock "$VERIFY_LOCK"

    if [ "$RC" -ne 0 ]; then
        N="$(cat "$FAIL_FILE" 2>/dev/null || echo 0)"; N=$((N + 1)); echo "$N" > "$FAIL_FILE"
        REASON="exit $RC"; [ "$RC" -eq 124 ] && REASON="TIMEOUT after ${VTIMEOUT}s"
        if [ "$N" -ge 3 ]; then
            TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
            printf '\n- [%s] Gate failed %s times for %s (%s); released so session can yield:\n' "$NOW" "$N" "$AGENT_SLOT" "$REASON" >> "$ROOT/$SDIR/PROPOSALS.md"
            tail -n 15 "$VLOG" | sed 's/^/    /' >> "$ROOT/$SDIR/PROPOSALS.md"
            write_receipt "GATE FAILED x$N (RELEASED)" "make agent-verify $REASON" "Human review: see .crux/PROPOSALS.md"
            rm -f "$FAIL_FILE" "$VLOG" "$SLOT_FILE" "$LOOP_FILE"
            set_ckpt "READY (gate released after $N failures)"
            exit 0
        fi
        echo "PRODUCTION GATE BLOCKED [$NAME] (Attempt $N/3): 'make agent-verify' failed ($REASON). Fix failing tests before stopping:" >&2
        tail -n 25 "$VLOG" >&2; rm -f "$VLOG"; exit 2
    fi

    rm -f "$FAIL_FILE" "$SLOT_FILE" "$LOOP_FILE"
    NOTESTS=0; grep -q 'CRUX_NO_TESTS' "$VLOG" 2>/dev/null && NOTESTS=1
    rm -f "$VLOG"
    HASH_AFTER="$(state_hash)"
    [ "$NOTESTS" = 0 ] && echo "$HASH_AFTER" > "$LOCAL_DIR/last_verified"
    if [ "$HASH_AFTER" != "$(cat "$LOCAL_DIR/last_receipt" 2>/dev/null || true)" ]; then
        TOUCHED="$(touched_list 12)"; DSTAT="$(diff_stat)"
        if [ "$NOTESTS" = 1 ]; then
            write_receipt "NO TESTS CONFIGURED" "make agent-verify ran placeholder target" "Configure test command via '$NAME gate <cmd>'"
        else
            write_receipt "VERIFIED PASS" "make agent-verify exited 0" "Proceed to next unchecked task in .crux/PLAN.md"
        fi
        echo "$HASH_AFTER" > "$LOCAL_DIR/last_receipt"
    fi
    set_ckpt "READY (Last verified: $AGENT_SLOT) | All tests green"
    exit 0
    ;;
esac
exit 0
HOOK_EOF

sed "s|@@HUB@@|${HUB_DIR}|g; s|@@BIN@@|${BIN_DIR}|g; s|@@VERSION@@|${CRUX_VERSION}|g; s|@@NAME@@|${CLI_NAME}|g" \
    "${HUB_DIR}/hooks/on_event.sh" > "${HUB_DIR}/hooks/on_event.sh.tmp" \
    && mv "${HUB_DIR}/hooks/on_event.sh.tmp" "${HUB_DIR}/hooks/on_event.sh"
chmod +x "${HUB_DIR}/hooks/on_event.sh"

# ------------------------------------------------------------------------------
# 4. Zero-Friction `crux` CLI (100% Inside `.crux/`, Zero Root Clutter)
# ------------------------------------------------------------------------------
cat <<'CLI_EOF' > "${BIN_DIR}/@@NAME@@"
#!/usr/bin/env bash
# CRUX-CLI-MARKER @@NAME@@ @@VERSION@@
unset BASH_ENV
set -uo pipefail

NAME="@@NAME@@"
SDIR=".crux"
HUB_DIR="${CRUX_HOME:-@@HUB@@}"
BIN_DIR="${CRUX_BIN:-@@BIN@@}"
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }
note() { [ "${QUIET:-0}" = 1 ] || echo "$*"; }

CMD="${1:-status}"; [ $# -gt 0 ] && shift
CWD="$(pwd -P 2>/dev/null || pwd)"

find_root() {
    local d="$CWD" i=0
    while [ -n "$d" ] && [ "$i" -lt 40 ]; do
        [ -f "$d/$SDIR/PROJECT_STATE.md" ] && { printf '%s' "$d"; return 0; }
        [ "$d" = "/" ] && break
        d="${d%/*}"; [ -z "$d" ] && d="/"; i=$((i + 1))
    done
    return 1
}
git_top() { local t; t="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [ -n "$t" ] && (cd "$t" && pwd -P); }
ROOT="$(find_root || true)"
need_root() { [ -n "$ROOT" ] || die "no initialized $NAME project here (run '$NAME init')."; cd "$ROOT" || exit 1; LOCAL="$ROOT/$SDIR/local"; }
members() { if [ -f "$SDIR/WORKSPACE" ]; then grep -vE '^[[:space:]]*(#.*)?$' "$SDIR/WORKSPACE"; else echo "."; fi; }

detect_test_cmd() {
    local d="${1:-.}" c
    ( cd "$d" || exit 0
      mk=""; for f in GNUmakefile makefile Makefile; do [ -f "$f" ] && { mk="$f"; break; }; done
      if [ -n "$mk" ] && grep -q '^test:' "$mk"; then echo '$(MAKE) test'
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
      else echo "echo CRUX_NO_TESTS: no test runner configured yet. Set with: $NAME gate '<cmd>'"; fi )
}

index_sync() {
    mkdir -p "$SDIR/local"
    local repo_base
    repo_base="$(basename "$(pwd -P)")"
    {
        echo "# Workspace Lookup Table (.crux/INDEX.md)"
        echo ""
        echo "## 1. Sovereign State & Contract Files (100% Inside .crux/)"
        echo "- Active Engineering Plan (Read-Only to AI, Editable by Human): \`.crux/PLAN.md\`"
        echo "- Chronological Session Receipts & Diffs: \`.crux/PROJECT_STATE.md\`"
        echo "- Agent Escalations & Blockers: \`.crux/PROPOSALS.md\`"
        echo "- Architectural Decisions Ledger: \`.crux/DECISIONS.md\`"
        echo ""
        echo "## 2. Intertwined Harness Wikis & Knowledge (Read On Demand — Zero Duplication)"
        found_wiki=0
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            for w in .qoder/repowiki .zcode .minimax .mcode .opencode/docs docs/wiki .crux/docs; do
                p="$( [ "$m" = "." ] && echo "$w" || echo "$m/$w" )"
                if [ -d "$p" ]; then
                    cnt="$(find "$p" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
                    if [ "${cnt:-0}" -gt 0 ]; then
                        found_wiki=1
                        echo "- \`$p/\` ($cnt markdown chapters)"
                        find "$p" -name '*.md' 2>/dev/null | sort | head -n 12 | while IFS= read -r ch; do echo "  - \`$ch\`"; done
                    fi
                fi
            done
        done < <(members)
        if [ -d "${HOME}/.zcode/cli/memories/projects" ]; then
            zmem="$(find "${HOME}/.zcode/cli/memories/projects" -maxdepth 2 -type d -name "*${repo_base}*" 2>/dev/null | head -n1 || true)"
            if [ -n "$zmem" ] && [ -f "$zmem/memory/MEMORY.md" ]; then
                found_wiki=1
                echo "- ZCode Project Memory: \`$zmem/memory/MEMORY.md\`"
            fi
        fi
        [ "$found_wiki" = 0 ] && echo "- (No native harness wikis detected yet; .qoder/repowiki, .zcode, .minimax, and docs/wiki are auto-linked here when present)"
    } > "$SDIR/INDEX.md"
}

merge_json_hooks() {
    local f="$1" act="${2:-add}" dir tmp hubhook
    dir="$(dirname "$f")"
    hubhook="${HUB_DIR}/hooks/on_event.sh"
    have jq || { echo "WARN: jq not installed; skipped $f"; return 1; }
    mkdir -p "$dir"; [ -f "$f" ] || echo '{}' > "$f"
    jq -e . "$f" >/dev/null 2>&1 || { echo "WARN: $f is invalid JSON; skipped."; return 1; }
    cp "$f" "${f}.crux-bak"
    tmp="$(mktemp "${f}.XXXXXX")"
    jq --arg hub "$hubhook" --arg act "$act" '
      def strip: map(select(((.hooks // []) | map(.command // "") | any(contains($hub) or contains("on_event.sh"))) | not));
      def put(ev; matcher; t):
        .hooks[ev] = (((.hooks[ev] // []) | strip) +
          (if $act == "add"
           then [ ({hooks:[{type:"command", command:("bash \"" + $hub + "\" " + ev), timeout:t}]}
                   + (if matcher == "" then {} else {matcher:matcher} end)) ]
           else [] end));
      .hooks = (.hooks // {})
      | put("SessionStart"; ""; 30) | put("PreToolUse"; "*"; 15) | put("PostToolUse"; "*"; 15)
      | put("Stop"; ""; 900) | put("SessionEnd"; ""; 15)
      | .hooks |= with_entries(select(.value != []))
    ' "$f" > "$tmp" && mv "$tmp" "$f"
    note "==> [$NAME] Hooks ${act}ed in $f (backup: ${f}.crux-bak)"
}

install_opencode_plugin() {
    local base_dir="$1" act="${2:-add}" hubhook oc_ver
    hubhook="${HUB_DIR}/hooks/on_event.sh"
    if [ "$act" = "remove" ]; then
        rm -rf "$base_dir/plugins/crux.js" "$base_dir/plugins/crux" 2>/dev/null || true
        note "==> [$NAME] Removed OpenCode bridge plugin from $base_dir/plugins/"
        return 0
    fi
    oc_ver="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo '1.0')"
    mkdir -p "$base_dir/plugins"
    case "$oc_ver" in
        2.*)
            rm -f "$base_dir/plugins/crux.js" 2>/dev/null || true
            mkdir -p "$base_dir/plugins/crux"
            cat <<OC2_EOF > "$base_dir/plugins/crux/index.js"
import { spawnSync } from "node:child_process";
const HOOK = "${hubhook}";
function runCrux(ev, payload) {
  const r = spawnSync("bash", [HOOK, ev], { input: JSON.stringify(payload), encoding: "utf8" });
  if (r.status === 2) throw new Error((r.stderr || "Blocked by crux").trim());
}
export default {
  id: "crux",
  async setup(ctx) {
    const cwd = ctx.directory || process.cwd();
    runCrux("SessionStart", { hook_event_name: "SessionStart", session_id: "opencode", cwd });
    if (ctx.hook) {
      await ctx.hook("tool.execute.before", async (input, output) => {
        runCrux("PreToolUse", { hook_event_name: "PreToolUse", tool_name: input.tool, tool_input: (output && output.args) || input.args || {}, session_id: input.sessionID || "opencode", cwd });
      });
      await ctx.hook("tool.execute.after", async (input) => {
        runCrux("PostToolUse", { hook_event_name: "PostToolUse", tool_name: input.tool, session_id: input.sessionID || "opencode", cwd });
      });
      await ctx.hook("event", async ({ event }) => {
        if (event && event.type === "session.idle") {
          runCrux("Stop", { hook_event_name: "Stop", session_id: "opencode", cwd });
        }
      });
    }
  }
};
OC2_EOF
            note "==> [$NAME] Installed OpenCode v2 bridge plugin at $base_dir/plugins/crux/index.js"
            ;;
        *)
            rm -rf "$base_dir/plugins/crux" 2>/dev/null || true
            cat <<OC1_EOF > "$base_dir/plugins/crux.js"
import { spawnSync } from "node:child_process";
const HOOK = "${hubhook}";
function runCrux(ev, payload) {
  const r = spawnSync("bash", [HOOK, ev], { input: JSON.stringify(payload), encoding: "utf8" });
  if (r.status === 2) throw new Error((r.stderr || "Blocked by crux").trim());
}
export const CruxPlugin = async ({ directory }) => {
  const cwd = directory || process.cwd();
  runCrux("SessionStart", { hook_event_name: "SessionStart", session_id: "opencode", cwd });
  return {
    "tool.execute.before": async (input, output) => {
      runCrux("PreToolUse", { hook_event_name: "PreToolUse", tool_name: input.tool, tool_input: (output && output.args) || input.args || {}, session_id: input.sessionID || "opencode", cwd });
    },
    "tool.execute.after": async (input) => {
      runCrux("PostToolUse", { hook_event_name: "PostToolUse", tool_name: input.tool, session_id: input.sessionID || "opencode", cwd });
    },
    event: async ({ event }) => {
      if (event && event.type === "session.idle") {
        runCrux("Stop", { hook_event_name: "Stop", session_id: "opencode", cwd });
      }
    }
  };
};
export default CruxPlugin;
OC1_EOF
            note "==> [$NAME] Installed OpenCode v1 bridge plugin at $base_dir/plugins/crux.js"
            ;;
    esac
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
        mkdir -p "$SDIR/hooks" "$SDIR/local/slots" "$SDIR/archive"
        cp "${HUB_DIR}/hooks/on_event.sh" "$SDIR/hooks/on_event.sh"
        chmod +x "$SDIR/hooks/on_event.sh"

        if [ "$WS" = 1 ] && [ ! -f "$SDIR/WORKSPACE" ]; then
            { echo "# Workspace member folders (one per line)"
              for d in */; do [ -d "${d}.git" ] && echo "${d%/}"; done; } > "$SDIR/WORKSPACE"
        fi

        TEST_CMD="$(detect_test_cmd .)"
        if [ ! -f Makefile ]; then
            printf '.PHONY: agent-verify\n\nagent-verify:\n\t@echo "==> [%s] Running verification gate..."\n\t@%s\n' "$NAME" "$TEST_CMD" > Makefile
        elif ! grep -q '^agent-verify:' Makefile; then
            printf '\n.PHONY: agent-verify\nagent-verify:\n\t@echo "==> [%s] Running verification gate..."\n\t@%s\n' "$NAME" "$TEST_CMD" >> Makefile
        fi

        if [ ! -f "$SDIR/PLAN.md" ]; then
            cat <<'P_EOF' > "$SDIR/PLAN.md"
<!-- crux:template (auto-locks once replaced with your real plan) -->
# Active Engineering Plan (.crux/PLAN.md)
# (Editable anytime in your human editor; protected by hook against AI overwrites)

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
        touch "$SDIR/PROPOSALS.md" "$SDIR/DECISIONS.md"
        index_sync

        NOW="$(date '+%Y-%m-%d %H:%M')"
        if [ ! -f "$SDIR/PROJECT_STATE.md" ]; then
            cat <<S_EOF > "$SDIR/PROJECT_STATE.md"
# Chronological Project State & Receipts (.crux/PROJECT_STATE.md)

## [$NOW] | Session #0 | $NAME init | Task T0
- Verified Receipt: Initialized $NAME v@@VERSION@@ (100% inside .crux/, zero root clutter)
- Touched Files: .crux/ created
- Next Deterministic Action: Paste plan into .crux/PLAN.md (or run '$NAME plan') and start T1
S_EOF
        fi
        echo "[In-Flight Checkpoint]: $NOW READY | Initialized" > "$SDIR/local/checkpoint.txt"

        [ -f .gitignore ] || : > .gitignore
        for ig in ".crux/local/" ".crux/.exempt" "*.crux-bak"; do
            grep -qxF "$ig" .gitignore 2>/dev/null || printf '%s\n' "$ig" >> .gitignore
        done

        rm -f "$SDIR/.exempt" .crux-ignore
        grep -Fxv "$DEST" "$HUB_DIR/exempt.list" > "$HUB_DIR/exempt.list.tmp" 2>/dev/null || true
        mv -f "$HUB_DIR/exempt.list.tmp" "$HUB_DIR/exempt.list" 2>/dev/null || true
        note "==> [$NAME] Ready in $DEST (100% inside .crux/ — zero root clutter)."
        ;;

    plan)
        need_root
        if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
            cp "$1" "$SDIR/PLAN.md"
        elif [ ! -t 0 ]; then
            cat > "$SDIR/PLAN.md"
        elif have powershell.exe; then
            powershell.exe -NoProfile -Command Get-Clipboard | tr -d '\r' > "$SDIR/PLAN.md"
        elif have wl-paste; then
            wl-paste > "$SDIR/PLAN.md"
        elif have xclip; then
            xclip -o -selection clipboard > "$SDIR/PLAN.md"
        elif have pbpaste; then
            pbpaste > "$SDIR/PLAN.md"
        else
            die "Pipe plan on stdin, pass a file ('$NAME plan file.md'), or edit .crux/PLAN.md directly in your editor."
        fi
        chmod 644 "$SDIR/PLAN.md" 2>/dev/null || true
        echo "==> [$NAME] Updated .crux/PLAN.md ($(wc -l < "$SDIR/PLAN.md" | tr -d ' ') lines)."
        ;;

    gate)
        need_root
        NEW_CMD="$*"
        [ -z "$NEW_CMD" ] && NEW_CMD="$(detect_test_cmd .)"
        awk -v cmd="$NEW_CMD" -v nm="$NAME" '
            /^agent-verify:/ {
                print "agent-verify:"
                print "\t@echo \"==> [" nm "] Running verification gate...\""
                print "\t@" cmd
                skip=1; next
            }
            skip && /^\t/ { next }
            skip { skip=0 }
            { print }
        ' Makefile > Makefile.tmp.$$ && mv Makefile.tmp.$$ Makefile
        rm -f "$LOCAL/last_verified"
        echo "==> [$NAME] Updated 'make agent-verify' -> $NEW_CMD"
        ;;

    verify)
        need_root
        printf '{"hook_event_name":"Stop","session_id":"manual-verify","cwd":"%s"}' "$ROOT" | bash "$SDIR/hooks/on_event.sh" Stop
        ;;

    exempt|clear)
        CLEAR=0; [ "$CMD" = "clear" ] && CLEAR=1
        for a in "$@"; do [ "$a" = "--clear" ] || [ "$a" = "--purge" ] && CLEAR=1; done
        TARGET="${ROOT:-$(git_top)}"; TARGET="${TARGET:-$CWD}"
        if [ "$CLEAR" = 1 ] && [ -d "$TARGET/$SDIR" ]; then
            bak="$HUB_DIR/purge-backups/$(basename "$TARGET")-$(date +%Y%m%d-%H%M%S).tar.gz"
            ( cd "$TARGET" && tar -czf "$bak" "$SDIR" 2>/dev/null ) || true
            rm -rf "$TARGET/$SDIR"
            echo "==> [$NAME] Cleared $TARGET/.crux/ (backup saved at $bak)."
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
        grep -Fxv "$TARGET" "$HUB_DIR/exempt.list" > "$HUB_DIR/exempt.list.tmp" 2>/dev/null || true
        mv -f "$HUB_DIR/exempt.list.tmp" "$HUB_DIR/exempt.list" 2>/dev/null || true
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
        ACT="add"; [ "${1:-}" = "--remove" ] && ACT="remove"
        if [ "${1:-}" = "--local" ]; then
            need_root
            if [ -d "$ROOT/.claude" ] || have claude; then
                merge_json_hooks "$ROOT/.claude/settings.local.json" "add" || true
            fi
            if [ -d "$ROOT/.qoder" ] || [ -d "${HOME}/.qoder" ] || have qoder; then
                merge_json_hooks "$ROOT/.qoder/settings.json" "add" || true
            fi
            if [ -d "$ROOT/.zcode" ] || [ -d "${HOME}/.zcode" ] || have zcode; then
                merge_json_hooks "$ROOT/.zcode/config.json" "add" || true
            fi
            if [ -d "$ROOT/.opencode" ] || [ -d "${HOME}/.config/opencode" ] || have opencode; then
                install_opencode_plugin "$ROOT/.opencode" "add" || true
            fi
        else
            { [ -d "${HOME}/.claude" ] || have claude; } && merge_json_hooks "${HOME}/.claude/settings.json" "$ACT" || true
            { [ -d "${HOME}/.qoder" ]  || have qoder; }  && merge_json_hooks "${HOME}/.qoder/settings.json" "$ACT" || true
            { [ -d "${HOME}/.zcode" ]  || have zcode; }  && merge_json_hooks "${HOME}/.zcode/cli/config.json" "$ACT" || true
            { [ -d "${HOME}/.gemini" ] || have antigravity || have agy; } && merge_json_hooks "${HOME}/.gemini/config/hooks.json" "$ACT" || true
            { [ -d "${HOME}/.config/opencode" ] || have opencode; } && install_opencode_plugin "${HOME}/.config/opencode" "$ACT" || true
        fi
        ;;

    update)
        LOCAL_UPD=0; [ "${1:-}" = "--local" ] && LOCAL_UPD=1
        if [ -d "$HUB_DIR/.git" ]; then
            echo "==> [$NAME] Pulling latest from GitHub ($HUB_DIR)..."
            git -C "$HUB_DIR" pull --ff-only || echo "WARN: git pull skipped (local edits or offline)."
        fi
        INST=""
        [ -f "$HUB_DIR/install.sh" ] && INST="$HUB_DIR/install.sh"
        [ -z "$INST" ] && [ -f "$HUB_DIR/install.bash" ] && INST="$HUB_DIR/install.bash"
        if [ -n "$INST" ]; then
            if [ "$LOCAL_UPD" = 1 ]; then
                bash "$INST" --local >/dev/null
                echo "==> [$NAME] Updated CLI & local repo hooks/plugins."
            else
                MODE_FLAG="--manual"
                [ "$(cat "$HUB_DIR/auto_init.conf" 2>/dev/null || echo false)" = "true" ] && MODE_FLAG="--auto"
                bash "$INST" "$MODE_FLAG" >/dev/null
                echo "==> [$NAME] Updated global CLI & hook engine."
            fi
        fi
        if [ -n "$ROOT" ] && [ -d "$ROOT/$SDIR/hooks" ]; then
            cp "$HUB_DIR/hooks/on_event.sh" "$ROOT/$SDIR/hooks/on_event.sh"
            chmod +x "$ROOT/$SDIR/hooks/on_event.sh"
            echo "==> [$NAME] Refreshed repo hook: $ROOT/$SDIR/hooks/on_event.sh"
        fi
        ;;

    uninstall)
        merge_json_hooks "${HOME}/.claude/settings.json" "remove" 2>/dev/null || true
        merge_json_hooks "${HOME}/.qoder/settings.json" "remove" 2>/dev/null || true
        merge_json_hooks "${HOME}/.zcode/cli/config.json" "remove" 2>/dev/null || true
        merge_json_hooks "${HOME}/.gemini/config/hooks.json" "remove" 2>/dev/null || true
        install_opencode_plugin "${HOME}/.config/opencode" "remove" 2>/dev/null || true
        rm -f "$BIN_DIR/$NAME"
        echo "==> [$NAME] Removed CLI binary and global hook/plugin entries. (Repo .crux/ folders and $HUB_DIR left intact.)"
        ;;

    index-sync)
        QUIET=1; need_root; index_sync
        ;;

    canary)
        need_root
        echo "==> [$NAME] Running live Canary Self-Test on $ROOT..."
        printf '{"hook_event_name":"SessionStart","session_id":"canary","cwd":"%s"}' "$ROOT" | bash "$SDIR/hooks/on_event.sh" SessionStart
        echo "  [1/3] SessionStart: OK"
        RC=0
        printf '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":".env.production"},"cwd":"%s"}' "$ROOT" | bash "$SDIR/hooks/on_event.sh" PreToolUse 2>/dev/null || RC=$?
        [ "$RC" -eq 2 ] && echo "  [2/3] PreToolUse (.env shield): OK (Blocked with exit 2)" || die "PreToolUse failed to block .env.production"
        RC=0
        printf '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".crux/hooks/on_event.sh"},"cwd":"%s"}' "$ROOT" | bash "$SDIR/hooks/on_event.sh" PreToolUse 2>/dev/null || RC=$?
        [ "$RC" -eq 2 ] || die "PreToolUse failed to block protected .crux/hooks/ write"
        RC=0
        printf '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".crux/PLAN.md"},"cwd":"%s"}' "$ROOT" | bash "$SDIR/hooks/on_event.sh" PreToolUse 2>/dev/null || RC=$?
        if grep -q 'crux:template' "$ROOT/$SDIR/PLAN.md" 2>/dev/null; then
            [ "$RC" -eq 0 ] && echo "  [3/3] PreToolUse (Contract Lock): OK (PLAN.md open for 1st-time onboarding; .crux/hooks/ locked exit 2)" || die "PreToolUse unexpectedly blocked starter PLAN.md template"
        else
            [ "$RC" -eq 2 ] && echo "  [3/3] PreToolUse (.crux/PLAN.md lock): OK (Blocked with exit 2)" || die "PreToolUse failed to block .crux/PLAN.md write"
        fi
        echo "==> [$NAME] All Canary Checks PASSED."
        ;;

    status|*)
        echo "=============================================================================="
        echo " $NAME v$(cat "$HUB_DIR/VERSION" 2>/dev/null || echo '@@VERSION@@') — Zero-Friction Status"
        echo "   Hub:      $HUB_DIR | Auto-Init: $(cat "$HUB_DIR/auto_init.conf" 2>/dev/null || echo false)"
        echo "   RAM:      0 MB background (event-driven POSIX hook)"
        if [ -n "$ROOT" ]; then
            echo "   Project:  $ROOT ($SDIR/)"
            echo "   State:    $(cat "$ROOT/$SDIR/local/checkpoint.txt" 2>/dev/null || echo 'READY')"
        else
            echo "   Project:  Not initialized here (run '$NAME init')"
        fi
        echo "------------------------------------------------------------------------------"
        echo "   Commands: $NAME init | $NAME plan | $NAME gate '<cmd>' | $NAME verify | $NAME update | $NAME canary"
        echo "=============================================================================="
        ;;
esac
CLI_EOF

sed "s|@@HUB@@|${HUB_DIR}|g; s|@@BIN@@|${BIN_DIR}|g; s|@@VERSION@@|${CRUX_VERSION}|g; s|@@NAME@@|${CLI_NAME}|g" \
    "${BIN_DIR}/@@NAME@@" > "${BIN_DIR}/${CLI_NAME}.tmp" \
    && mv "${BIN_DIR}/${CLI_NAME}.tmp" "${BIN_DIR}/${CLI_NAME}"
rm -f "${BIN_DIR}/@@NAME@@"
chmod +x "${BIN_DIR}/${CLI_NAME}"

if [ "${LOCAL_ONLY}" = "true" ]; then
    "${BIN_DIR}/${CLI_NAME}" init
    "${BIN_DIR}/${CLI_NAME}" hooks --local >/dev/null 2>&1 || true
    echo "=============================================================================="
    echo " ${CLI_NAME} v${CRUX_VERSION} Installed in LOCAL TEST MODE (Zero Global Changes!)"
    echo "   Repo:           $(pwd -P)/.crux/"
    echo "   Local Bridges:  Auto-wired ONLY for detected harnesses (Qoder, ZCode, OpenCode, Claude)"
    echo "   Test Command:   ${BIN_DIR}/${CLI_NAME} canary"
    echo "   Update Later:   ${BIN_DIR}/${CLI_NAME} update --local"
    echo "=============================================================================="
else
    "${BIN_DIR}/${CLI_NAME}" hooks >/dev/null 2>&1 || true
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        if [ -f "$rc" ] && ! grep -qF "${BIN_DIR}" "$rc" 2>/dev/null; then
            printf '\nexport PATH="%s:${PATH}"\n' "${BIN_DIR}" >> "$rc"
        fi
    done
    echo "=============================================================================="
    echo " ${CLI_NAME} v${CRUX_VERSION} Installed (Linux / WSL2 / macOS — 100% Inside .crux/)"
    echo "   Global Soul Synced: Detected harnesses (~/.zcode, ~/.qoder, ~/.config/opencode, ~/.dsh, ~/.minimax, ~/.claude, ~/.gemini)"
    echo "   Bridges Registered: Qoder, ZCode, OpenCode (v1/v2 auto-detected), Antigravity, Claude Code"
    echo "   Daily Commands:     ${CLI_NAME} init | ${CLI_NAME} plan | ${CLI_NAME} gate | ${CLI_NAME} update | ${CLI_NAME} canary"
    echo "=============================================================================="
fi
