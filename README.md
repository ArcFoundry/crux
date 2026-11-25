# crux `v5.1.0`

**Zero-daemon, zero-LLM-API-call multi-harness continuity, contract-enforcement, and build-verification layer.**

Works identically across **macOS (Bash 3.2+)** and **Linux / WSL2**, sitting cleanly underneath standalone CLIs, IDEs, and multiplexers (`Orca`, `T3 Code`, `Herdr`, `PandaCode`).

* **Footprint:** `0 MB` background RAM · pure event-driven Bash 3.2+ hooks · `0` independent LLM API calls
* **Containment:** All state lives inside `.crux/` (only a 1-line `agent-verify:` alias in your `Makefile` and 3 `.gitignore` entries at repo root)
* **Zero Wiki Duplication:** Indexes native harness wikis (`.qoder/repowiki/`, `.zcode/`, `.minimax/`, `docs/wiki/`) on demand in `.crux/INDEX.md` with Git-commit staleness tracking (`crux wiki-mark`)

## Supported Harnesses

| Harness | Integration Mode | What `crux` Wires |
| :--- | :--- | :--- |
| **Claude Code** | Enforced Bridge | `~/.claude/settings.json` + `~/.claude/CLAUDE.md` |
| **Qoder** | Enforced Bridge | `~/.qoder/settings.json` + `~/.qoder/AGENTS.md` |
| **ZCode** | Enforced Bridge | `~/.zcode/cli/config.json` (`.hooks.events.*`, `enabled: true`) + `~/.zcode/AGENTS.md` |
| **Google Antigravity (`agy`)** | Enforced Bridge | `~/.gemini/config/hooks.json` (native JSON decision contract) + `~/.gemini/GEMINI.md` |
| **OpenCode (v1 & v2)** | Enforced Bridge (`PreToolUse` blocks; `session.idle` observer) | `~/.config/opencode/plugins/crux.js` (v1) or `crux/index.js` (`Plugin.define` + `ctx.tool.hook` + `ctx.shell.hook`, v2) + `~/.config/opencode/AGENTS.md` |
| **DeepSeek Harness (`dsh`)** | Rules-Only | `~/.dsh/AGENTS.md` |
| **MiniMax Code (`mcode`)** | Rules-Only | `~/.minimax/AGENTS.md` |
| **Codex** | Rules-Only | `~/.codex/AGENTS.md` |

## Requirements

* `bash` (3.2+), `git`, `jq`, `make`, `awk`, `grep`, `sed`, `find`, `cksum`, `tar`, `mktemp`
* Optional: `timeout` / `gtimeout` (falls back to a reaped Bash watchdog when absent)

## Quick Start

### 1. One-Time Global Install (Recommended)

```bash
git clone https://github.com/ArcFoundry/crux.git ~/.crux-hub
bash ~/.crux-hub/install.sh --manual
```

### 2. Onboard Any Existing Repo (2 Commands)

```bash
cd /path/to/your-repo
crux init
crux gate "pnpm run build"   # or pytest -q / cargo test / go test ./...
```

### 3. Verify Everything Works

```bash
crux status
crux canary
```

### Isolated Local Mode (Zero Global Changes)

```bash
cd /path/to/your-repo
bash /path/to/crux/install.sh --local
# Optional opt-in if you accept repo-local bridge files (.claude/, .qoder/, .opencode/, .agents/hooks.json):
.crux/local/bin/crux hooks --local
```

## Core `.crux/` Files

| File | Purpose |
| :--- | :--- |
| `.crux/PLAN.md` | Active engineering plan. Read-only to agents (human edits directly or via `crux plan`); unauthorized edits are reverted by `plan_guard`. |
| `.crux/PROGRESS.md` | Append-only, never-rotated completed-task ledger (`- [x] <TaskID> \| <short-sha> \| <harness> \| <YYYY-MM-DD> \| <summary>`). |
| `.crux/PROJECT_STATE.md` | Chronological build receipts & diffs (keeps last 8 blocks; older archived transactionally to `.crux/archive/`). |
| `.crux/INDEX.md` | Auto-synced lookup table pointing to `.crux/*` and native harness wikis with Git-commit `[STALE]` warnings. |
| `.crux/PROPOSALS.md` | Agent escalations, plan conflicts, and verification failure pointers. |
| `.crux/DECISIONS.md` | Architectural decisions ledger. |
| `.crux/verify.command` | Verification script sealed with a machine-local SHA-256 trust hash in `~/.crux-hub/trust/` (cloned repos never execute untrusted code). |

## Daily Commands

| Command | Action |
| :--- | :--- |
| `crux init [--workspace]` | Initialize `.crux/` in the current Git repo (or multi-repo workspace) and import any legacy v4 Makefile gate. |
| `crux plan [file]` | Replace `.crux/PLAN.md` from a file, stdin, or clipboard and lock its baseline. |
| `crux gate "<cmd>"` | Set, syntax-check, and seal `.crux/verify.command` on this machine. |
| `crux gate --accept` | Trust an existing `.crux/verify.command` (e.g., after reviewing a cloned repo). |
| `crux done <ID> [note]` | Append a verified human completion line to `.crux/PROGRESS.md`. |
| `crux wiki-mark [dir] [wiki]` | Record the exact Git commit baseline for a native harness wiki (default: `. .qoder/repowiki`). |
| `crux verify` | Run the sealed verification gate manually. |
| `crux status` | Show repo state, gate trust status, and every global/local harness bridge. |
| `crux canary` | Run the live 8-check self-test against the active hook engine. |
| `crux update` | Pull latest `crux` and refresh CLI, hooks, and current repo. |
| `crux exempt` / `crux clear` | Exempt a repo from hooks, or purge `.crux/` after verifying a `.tar.gz` backup. |
| `crux uninstall` | Remove CLI binary and registered hook/plugin entries (leaves repo `.crux/` intact). |

## Honest Architectural Boundaries

`crux` is a **cooperative guardrail, continuity, and build-receipt layer**, not an OS sandbox:

* Same-UID shell hooks raise the cost of accidental secret reads and plan/config mutations, but cannot provide kernel-level privilege separation against a hostile same-user process.
* Verification receipts (`OBSERVED PASS`) certify that your trusted `verify.command` exited `0` with matching pre/post tracked-file hashes—not semantic proof that an agent implemented the right feature.
* Observer-only hooks (OpenCode `session.idle`) log failures to `.crux/PROPOSALS.md` and `.crux/PROJECT_STATE.md` rather than forcing an automatic LLM retry loop.
