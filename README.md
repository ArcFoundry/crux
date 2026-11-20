# crux — Zero-Daemon Multi-Harness Agentic Layer (`v4.1.0`)

A pure-Bash, `0 MB` background RAM continuity, guardrail, and test-verification engine for AI coding harnesses (`Qoder`, `ZCode`, `OpenCode`, `Google Antigravity`, `Claude Code`, `Codex`, `omp`).

100% of project state lives inside `.crux/` with **zero root file clutter**.

## Prerequisites
Install `jq` once so `crux` can non-destructively merge hooks into your existing harness configs:
```bash
sudo apt update && sudo apt install -y jq
```

## Quick Install

### Option A: Single-Repo Local Test Mode (Zero Global Changes)
Test `crux` inside one existing repository without touching `~/.bashrc` or any global `~/.qoder` / `~/.zcode` files:
```bash
git clone https://github.com/ArcFoundry/crux.git ~/.crux-hub
cd /path/to/your-repo
bash ~/.crux-hub/install.sh --local
~/.local/bin/crux canary
```

### Option B: Full Global Install (All Repos)
```bash
git clone https://github.com/ArcFoundry/crux.git ~/.crux-hub && bash ~/.crux-hub/install.sh
source ~/.bashrc
```
*(Non-interactive flags: `--manual` [default] or `--auto`)*

## How It Works
1. **Zero-Friction Onboarding (`<!-- crux:template -->`):** When you run `crux init`, `.crux/PLAN.md` starts with a template marker so your AI harness can write the initial plan directly on the first pass. Once replaced with your real plan, `.crux/PLAN.md` automatically locks against future AI overwrites (while remaining freely editable in your human editor).
2. **Event-Driven Hook (`on_event.sh`, ~10 ms, `0 MB` idle RAM):**
   - `SessionStart`: Auto-recovers interrupted sessions if a prior harness crashed mid-turn.
   - `PreToolUse`: Blocks `.env*` / keystore reads (including nested `MultiEdit` payloads) and blocks AI overwrites of `.crux/PLAN.md` and `.crux/hooks/`.
   - `PostToolUse`: Tracks touched files in gitignored `.crux/local/checkpoint.txt`.
   - `Stop`: Runs `make agent-verify` (up to 3 retries before escalating to `.crux/PROPOSALS.md`) and stamps a dated receipt into `.crux/PROJECT_STATE.md`.
3. **Zero-Redundancy Wiki Bridge:** Leaves `.qoder/repowiki/` and `.zcode/` untouched and lists their paths inside `.crux/INDEX.md` so every harness can read them on demand.

## Daily Commands

| Command | Purpose |
| :--- | :--- |
| `crux init` | Scaffold `.crux/` (`PLAN.md`, `PROJECT_STATE.md`, `INDEX.md`, `DECISIONS.md`) and `make agent-verify` |
| `crux plan` | Paste clipboard (or stdin/file) directly into `.crux/PLAN.md` |
| `crux gate "<cmd>"` | Set the test verification command for `make agent-verify` |
| `crux update [--local]` | Pull latest `ArcFoundry/crux` and refresh CLI + repo hook |
| `crux exempt [--clear]` | Exempt current repo (`--clear` backs up `.crux/` as `.tar.gz` and removes it) |
| `crux unexempt` | Remove exemption from current repo |
| `crux mode [manual\|auto]` | Switch global default between Manual and Auto-Init mode |
| `crux canary` | Run 1-second self-test on `SessionStart`, `.env` shield, and contract lock |
| `crux status` | Show current project state and active checkpoint |
| `crux uninstall` | Remove CLI binary and global hook entries cleanly |
