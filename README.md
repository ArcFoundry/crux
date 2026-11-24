# crux — Zero-Daemon Multi-Harness Agentic Layer (`v4.2.0`)

A pure-Bash, `0 MB` background RAM continuity, guardrail, and test-verification engine for AI coding harnesses (**Qoder**, **ZCode**, **OpenCode v1/v2**, **Google Antigravity**, **DeepSeek Harness `dsh`**, **MiniMax Code `mcode`**, **Claude Code**, **Codex**, **omp**).

Works on **Linux, WSL2, and macOS (Bash 3.2+)** with 100% of project state inside `.crux/` and **zero root file clutter**.

## Prerequisites
Install `jq` once so `crux` can non-destructively merge hooks into your existing harness configs:
- **Linux / WSL2:** `sudo apt update && sudo apt install -y jq`
- **macOS:** `brew install jq coreutils`

## 1-Command Universal Install (Linux / WSL2 / macOS)

### Full Global Install (Recommended)
```bash
git clone https://github.com/ArcFoundry/crux.git ~/.crux-hub && bash ~/.crux-hub/install.sh --manual
source ~/.bashrc   # or: source ~/.zshrc on macOS / zsh
```
*(Pass `--auto` instead of `--manual` if you want auto-init on all Git repos.)*

### Single-Repo Local Test Mode (Zero Global Changes)
```bash
git clone https://github.com/ArcFoundry/crux.git ~/.crux-hub
cd /path/to/your-repo
bash ~/.crux-hub/install.sh --local
~/.local/bin/crux canary
```

## How It Works
1. **Auto-Wired Bridges (One Install, Always Working):** Automatically detects which harnesses exist on your machine and registers their native hook/plugin bridge (`Qoder`, `ZCode`, `OpenCode v1/v2` auto-detected, `Antigravity`, and `Claude Code`).
2. **Intertwined Knowledge (`.crux/INDEX.md` — Zero Redundancy):** Automatically links `.qoder/repowiki/`, `.zcode/`, `~/.zcode/cli/memories/`, `.minimax/`, `.mcode/`, `.opencode/docs/`, and `docs/wiki/` inside `.crux/INDEX.md` without copying or duplicating a single file.
3. **Zero-Friction Onboarding (`<!-- crux:template -->`):** Starter `.crux/PLAN.md` allows your AI harness to write the initial plan once, then automatically locks against future AI overwrites (while staying freely editable in your human editor).
4. **Event-Driven Hook (`on_event.sh`, ~10 ms, `0 MB` idle RAM):**
   - `SessionStart`: Auto-recovers interrupted sessions if a prior harness crashed mid-turn.
   - `PreToolUse`: Blocks `.env*` / keystore reads (including nested `MultiEdit` payloads) and blocks AI overwrites of `.crux/PLAN.md` and `.crux/hooks/`.
   - `PostToolUse`: Tracks touched files in gitignored `.crux/local/checkpoint.txt`.
   - `Stop`: Runs `make agent-verify` (up to 3 retries before escalating to `.crux/PROPOSALS.md`) and stamps a dated receipt into `.crux/PROJECT_STATE.md`.

## Daily Commands

| Command | Purpose |
| :--- | :--- |
| `crux init` | Scaffold `.crux/` (`PLAN.md`, `PROJECT_STATE.md`, `INDEX.md`, `DECISIONS.md`) and `make agent-verify` |
| `crux plan` | Paste clipboard (or stdin/file) directly into `.crux/PLAN.md` |
| `crux gate "<cmd>"` | Set the test verification command for `make agent-verify` |
| `crux verify` | Manually run the `Stop` gate and stamp `.crux/PROJECT_STATE.md` |
| `crux update [--local]` | Pull latest `ArcFoundry/crux` and refresh CLI + hooks/plugins |
| `crux exempt [--clear]` | Exempt current repo (`--clear` backs up `.crux/` as `.tar.gz` and removes it) |
| `crux unexempt` | Remove exemption from current repo |
| `crux mode [manual\|auto]` | Switch global default between Manual and Auto-Init mode |
| `crux canary` | Run 1-second self-test on `SessionStart`, `.env` shield, and contract lock |
| `crux status` | Show current project state and active checkpoint |
| `crux uninstall` | Remove CLI binary and global hook/plugin entries cleanly |
