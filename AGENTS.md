# AGENTS.md — `crux` Engineering Contract & Context

Read this file first before modifying `install.sh` or `README.md` in `ArcFoundry/crux`.

## 1. Problem Statement & Core Goal

Developers who switch across multiple AI coding harnesses (**Claude Code**, **Qoder**, **ZCode**, **OpenCode**, **Google Antigravity**, **DeepSeek Harness**, **MiniMax Code**, **Codex**) on the same Git repository hit four recurring failures:

1. **Context amnesia across harnesses & long sessions:** Each harness keeps isolated memory/rules; rotating state files erase completed tasks if no durable ledger exists.
2. **Wiki duplication & silent staleness:** Closed generators (e.g., Qoder's `.qoder/repowiki/`) write to hardcoded paths and drift behind `HEAD` when other harnesses edit code.
3. **Unverified / broken stops:** Agents claim completion without running the repo's build/test gate, or modify the gate target itself.
4. **Heavyweight wrappers:** Multiplexers/ADEs (`Orca`, `T3 Code`, `Herdr`, `PandaCode`) manage worktrees/UI panes—they do not provide a repo-native, IDE-agnostic continuity and verification layer.

**`crux` solves this from underneath every harness** using plain Git-tracked Markdown files inside `.crux/` and pure event-driven POSIX/Bash 3.2+ hooks.

## 2. Non-Negotiables (Never Regress)

1. **Zero daemons, zero background RAM (`0 MB`), zero independent LLM API calls.**
2. **macOS (Bash 3.2+ / BSD `stat`/`sed`/`awk`) + Linux / WSL2 compatibility.** No Bash 4+ features (`declare -A`, `readarray`), no GNU-only `find -maxdepth`/`-mindepth`, no unescaped `awk -v`, no unguarded empty-array expansions under `set -u`.
3. **State contained inside `.crux/`.** Only root touches allowed are a 1-line `agent-verify:` alias in `Makefile` (respecting `GNUmakefile` > `makefile` > `Makefile`) and 3 `.gitignore` entries (`.crux/local/`, `.crux/.exempt`, `*.crux-orig.bak`).
4. **Zero duplication of native harness wikis.** Index native wikis in `.crux/INDEX.md` with Git-commit provenance (`[FRESH]` / `[STALE: +N commits behind HEAD]` / `crux wiki-mark`).
5. **Agents keep normal Bash/shell access.** Never ban shell tools wholesale; use hardened pre-checks + post-hoc integrity guards (`plan_guard`, `progress_guard`, `gate_guard`).
6. **Hard dependencies are explicit:** `bash`, `git`, `jq`, `make`, `awk`, `grep`, `sed`, `find`, `cksum`, `tar`, `mktemp`. Never silently swallow missing `jq` or failed bridge registration.

## 3. Single-File Architecture (`install.sh`)

`install.sh` generates and syntax-checks (`bash -n`) all runtime components:

* **`<HUB_DIR>/hooks/on_event.sh`** — Event engine (`SessionStart`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `SessionEnd`) supporting Claude/Qoder/ZCode (`exit 2`), OpenCode (`--observer`), and Antigravity (`--agy` JSON stdout).
* **`<BIN_DIR>/crux`** — CLI (`init`, `plan`, `done`, `gate`, `wiki-mark`, `verify`, `hooks`, `status`, `canary`, `mode`, `exempt`, `unexempt`, `clear`, `update`, `uninstall`).
* **`.crux/hooks/verify.sh`** — Sealed wrapper executed by `make agent-verify`, verifying the machine-local SHA-256 trust seal before running `.crux/verify.command`.
* **OpenCode bridge plugins** — Auto-detects v1 (`plugins/crux.js`) vs v2 (`plugins/crux/index.js`).

## 4. Verified Harness Bridge Contracts (Nov 2026)

| Harness | Config Path (Global) | Exact Schema / Protocol Notes |
| :--- | :--- | :--- |
| **Claude Code** | `~/.claude/settings.json` | `.hooks.<Event>[]` with `{ hooks: [{ type: "command", command, timeout }] }`. Omit matcher for match-all (never `"*"`). Blocks on stderr + `exit 2`. |
| **Qoder** | `~/.qoder/settings.json` | Same `.hooks.<Event>[]` schema and `exit 2` blocking. Native wiki at `.qoder/repowiki/`. |
| **ZCode** | `~/.zcode/cli/config.json` | `.hooks.enabled = true` + `.hooks.events.<Event>[]` with `type: "process"`, `command: "bash"`, `args: [...]`, `timeoutMs`. `SessionStart` injects JSON `{ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext } }`. Workspace hooks require Settings → Trust. |
| **Google Antigravity (`agy`)** | `~/.gemini/config/hooks.json` (local: `.agents/hooks.json`) | Top-level named key `"crux"`. `SessionStart` and `Stop` are **flat handler arrays**; `PreToolUse`/`PostToolUse` use `{ matcher: ".*", hooks: [...] }`. Stdin uses `conversationId`, `workspacePaths[0]`, `toolCall.{name,args}` (`AbsolutePath`, `TargetFile`, `CommandLine`, `Pattern`, `Includes`). Stdout returns JSON (`{"decision":"deny"/"allow"/"continue","reason":...}`). `Stop` checks `.fullyIdle == true`. |
| **OpenCode (v1 & v2)** | `~/.config/opencode/plugins/` | No JSON shell hooks. V1 exports `export const CruxPlugin`. V2 uses `Plugin.define({ id: "crux", async setup(ctx) })` with `ctx.tool.hook("execute.before"/"execute.after")`, **`ctx.shell.hook("create.before")`** (v2 routes shell commands separately), and `ctx.event.subscribe(...)`. `session.idle` is observer-only (`--observer`). |
| **DeepSeek (`dsh`), MiniMax (`mcode`), Codex** | `~/.dsh/AGENTS.md`, `~/.minimax/AGENTS.md`, `~/.codex/AGENTS.md` | Rules-only (`BUILDER_SOUL` continuity sync); no native hook bridge wired. |

## 5. Critical Invariants (Do Not Break)

* **Machine-local SHA-256 gate trust (`$HUB_DIR/trust/<repo-key>`):** Cloned repos and silent auto-init must NEVER auto-trust `.crux/verify.command`. Only human `init`, `gate <cmd>`, or `gate --accept` seals it.
* **`state_hash()` includes `HEAD` + `--binary` diffs:** Prevents false-green skips after committing broken code. `Stop` compares `state_hash tracked` before/after execution so untracked test reports (`junit.xml`, `coverage/`) don't cause false-red `RC=98`, while tracked-file mutations (e.g., lockfile rewrites) are caught immediately.
* **Repo-safe Git calls:** Always pass `export GIT_OPTIONAL_LOCKS=0` and `-c core.fsmonitor=false --no-textconv --no-ext-diff` in hooks.
* **Write-first `is_read_tool()`:** Mutating substrings (`*replace*`, `*edit*`, `*write*`, `*patch*`, `*apply*`) must return `1` before read substrings (`*search*`, `*find*`) are checked.
* **Symlink-first `canon_path()`:** Resolve symlinks via `cd -P` before collapsing `..`; check both raw and canonical paths against `is_secret_path()`.
* **Git-aware `plan_guard()` & `progress_guard()`:** Restore deleted files, adopt `git checkout`/`git pull` changes (`git_driven()`), and revert in-session agent tampering.
* **Transactional `write_receipt()` + `render_index()` `return 0`:** Never duplicate archived receipts on crash; never let `[ "$found_wiki" = 0 ]` return exit `1` from `render_index()`.
* **Reaped macOS watchdog:** Always `kill` + `wait` the fallback watchdog PID on early exit.

## 6. Known Architectural Ceilings & Live Verification Status

* **Cooperative guardrail, not an OS sandbox:** Same-UID shell hooks raise the cost of accidental secret reads and plan/config mutations; kernel isolation requires OS-level sandboxing.
* **Observer-only harnesses:** OpenCode's `session.idle` logs failures to `.crux/PROPOSALS.md` and `.crux/PROJECT_STATE.md` rather than forcing an LLM retry loop.
* **Live-verified on `ArcFoundry/studio` (v5.1.0):** Qoder `OBSERVED PASS` receipts, OpenCode v2 `Plugin.define` live hook execution (`opencode-bae5cf608122` + `AUTO-RECOVERED INTERRUPTED SESSION`), transactional receipt rotation, `PROGRESS.md` cross-session continuity, `INDEX.md` commit-drift tracking, and `RC=98` mid-verify tracked-mutation catch.

## 7. Pre-Push Verification Checklist

Before pushing any change to `install.sh`:

1. `bash -n install.sh` passes.
2. Extract and `bash -n` all three inner scripts (`on_event.sh`, `crux`, `verify.sh`).
3. Extract and `node --check` both OpenCode JS plugins (`OC1_EOF`, `OC2_EOF`).
4. Run `crux status && crux canary` (all 8 checks passing) in a real repo.
