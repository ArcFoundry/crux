# crux — Zero-Daemon Multi-Harness Agentic Layer

A pure-Bash, `0 MB` background RAM continuity, guardrail, and test-verification engine for AI coding harnesses (`Qoder`, `ZCode`, `Claude Code`, `OpenCode`, `Google Antigravity`, `Codex`, `omp`).

100% of project state lives inside `.crux/` with **zero root file clutter**.

## 1-Command Install (WSL2 / Linux / macOS)

> **Optional dependency:** Install `jq` first (`sudo apt install -y jq`) so `crux` can safely merge hooks into your existing `Claude Code`, `Qoder`, and `ZCode` settings.

```bash
git clone https://github.com/YOUR_USERNAME/crux.git ~/.crux-hub && bash ~/.crux-hub/install.sh
```

*(Non-interactive flags: `--manual` [default] or `--auto`)*

## What It Sets Up
1. **Global Home Pointers (`~/`):** Non-destructively adds a 4-line `.crux/` pointer to `~/.zcode/AGENTS.md`, `~/.qoder/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md`, `~/.config/opencode/AGENTS.md`, and `~/.codex/AGENTS.md` (backing up originals to `~/.crux-hub/backups/`).
2. **Event-Driven Hook (`on_event.sh`):**
   - `SessionStart`: Auto-recovers interrupted sessions if a prior harness crashed mid-turn.
   - `PreToolUse`: Blocks `.env*` / keystore reads and blocks AI overwrites of `.crux/PLAN.md`.
   - `PostToolUse`: Tracks touched files in gitignored `.crux/local/checkpoint.txt`.
   - `Stop`: Runs `make agent-verify` (up to 3 retries) and appends a dated receipt into `.crux/PROJECT_STATE.md`.

## Daily Commands

| Command | Purpose |
| :--- | :--- |
| `crux init` | Scaffold `.crux/` (`PLAN.md`, `PROJECT_STATE.md`, `INDEX.md`) and `make agent-verify` |
| `crux plan` | Paste clipboard (or stdin/file) directly into `.crux/PLAN.md` |
| `crux gate "<cmd>"` | Set the test verification command for `make agent-verify` |
| `crux exempt [--clear]` | Exempt current repo (`--clear` backs up `.crux/` as `.tar.gz` and removes it) |
| `crux unexempt` | Remove exemption from current repo |
| `crux mode [manual\|auto]` | Switch global default between Manual and Auto-Init mode |
| `crux canary` | Run 1-second self-test on `.env` shield and `.crux/PLAN.md` lock |
| `crux status` | Show current project state and active checkpoint |
