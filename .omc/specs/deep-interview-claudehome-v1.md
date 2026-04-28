# Deep Interview Spec: claudehome v1 (Mac client)

## Metadata
- Interview ID: claudehome-001
- Rounds: 4
- Final Ambiguity Score: 12.5%
- Type: greenfield
- Generated: 2026-04-24
- Threshold: 20%
- Status: PASSED

## Clarity Breakdown
| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|----------|
| Goal Clarity | 0.95 | 0.40 | 0.380 |
| Constraint Clarity | 0.80 | 0.30 | 0.240 |
| Success Criteria | 0.85 | 0.30 | 0.255 |
| **Total Clarity** | | | **0.875** |
| **Ambiguity** | | | **0.125** |

## Goal

Build a terminal-only CLI named `claudehome` that lets the user connect from any client device to persistent Claude Code sessions hosted on an always-on Mac mini, with Tailscale as the transport.

Running `claudehome` on the client:
1. SSHes to the Mac mini over Tailscale
2. Lists all subdirectories under `~/projects/claudecode` on the Mac mini as a picker, annotated with session state (active/idle) and time-since-last-activity
3. On selection, attaches the client's terminal to a tmux session named `claudehome-<project>` running in the project's directory — creating it (and launching `claude` inside) if it does not already exist
4. On disconnect, the tmux session and any running `claude` process persist on the Mac mini indefinitely

The v1 scope is the **Mac client only**. PC (PowerShell) and iPhone (mosh/Blink/ttyd) clients are deliberate follow-ups.

## Constraints

### Transport & networking
- Connectivity is via **Tailscale**. No static IPs, port forwarding, or VPN config beyond standard Tailscale onboarding.
- Mac mini Tailscale hostname defaults to `macmini` (override via `CLAUDEHOME_HOST`).
- SSH user defaults to `$USER` of the client (override via `CLAUDEHOME_USER`).

### Persistence
- **tmux** is the persistence layer. No bespoke daemon, no custom session manager, no state file on the Mac mini.
- tmux sessions are **eternal**: they live until explicitly killed. Sessions also **outlive any single `claude` process** — if `claude` exits (user `/exit` or crash), the tmux session drops to a `$SHELL` prompt and remains attached-ready.
- Launch pattern:
  ```
  tmux new-session -A -s claudehome-<project> \
    -c ~/projects/claudecode/<project> \
    'claude; exec $SHELL'
  ```
  The `-A` flag means "attach if session exists, create otherwise" — this single command covers both cold-start and resume paths.

### Project discovery
- Projects folder: `~/projects/claudecode` on the Mac mini (override via `CLAUDEHOME_PROJECTS_DIR`).
- A "project" is any direct subdirectory of the projects folder. No metadata file, no registration step.
- Session state shown in the picker:
  - **active** = a tmux session named `claudehome-<project>` currently exists
  - **idle** = no tmux session exists for that project
  - Last-activity timestamp = tmux session's last-activity time (via `tmux list-sessions -F '#{session_activity}'`) for active sessions; directory mtime for idle projects (approximate; good enough for v1)

### CLI surface (v1)
- **`claudehome`** (no args) → always show the picker. No subcommands. No named-target shortcut.
- `--help` / `-h` → print usage.
- That is the entire v1 surface. `ls`, `attach`, `kill`, `new` are explicit non-goals for v1.

### Configuration
- **Env vars only**, no config file in v1:
  - `CLAUDEHOME_HOST` (default: `macmini`)
  - `CLAUDEHOME_USER` (default: current `$USER`)
  - `CLAUDEHOME_PROJECTS_DIR` (default: `~/projects/claudecode` — resolved on Mac mini, not client)
- Code must be structured so a future config-file layer is an additive change, not a rewrite.

### Distribution
- Ship as a single bash script at `bin/claudehome` in this repo, plus a minimal `install.sh` that symlinks it into `/usr/local/bin` or `~/.local/bin`.
- No npm/homebrew/cargo packaging for v1.

### Picker
- Use `fzf` if available (arrow keys, type-to-filter, standard CLI muscle memory).
- Fall back to bash `select` if `fzf` is missing — document that `brew install fzf` is recommended.

### Mac mini prerequisites (documented, not enforced by script)
- Tailscale installed and authenticated
- SSH enabled (System Settings → General → Sharing → Remote Login)
- SSH key from the client authorized in `~/.ssh/authorized_keys`
- `tmux` installed (`brew install tmux`)
- `claude` in `$PATH` for the SSH user's non-interactive environment

### Client prerequisites
- Tailscale installed and authenticated
- SSH client (built into macOS)
- Optional: `fzf` (`brew install fzf`)

## Non-Goals (v1)

- Web UI, native mobile app, or any non-terminal interface
- Windows/PC client
- iPhone client
- Project scaffolding *via subcommand* (`claudehome new <name>`); see AC13–AC17 for the in-picker `[new project]` flow
- Session management commands (`ls`, `kill`, `attach <name>`)
- Named-arg attach (`claudehome <project>`)
- Session TTL / auto-cleanup of ghost sessions
- Multi-user support (shared Mac mini, per-user project roots)
- Config file, YAML/TOML settings
- Integrations with Claude Code's official `/remote-control` feature (different mechanism)
- Any daemon, background agent, or persistent state on either side beyond tmux itself

## Acceptance Criteria

Each criterion is concrete enough to be a test. Call the client Mac "laptop" and the server "macmini" below.

- [ ] **AC1** — From laptop with Tailscale up and macmini reachable, `claudehome` prints a picker listing every direct subdirectory of `~/projects/claudecode` on macmini.
- [ ] **AC2** — Picker rows include project name, session state (`active`/`idle`), and a human-readable last-activity ("2h ago", "3d ago").
- [ ] **AC3** — Selecting a project with **no existing tmux session** creates `claudehome-<project>` in the project's dir, launches `claude` inside it, and attaches the laptop's terminal. User reaches an interactive claude prompt.
- [ ] **AC4** — Selecting a project **with an existing tmux session** attaches immediately; if `claude` is actively streaming tool output at the moment of attach, the laptop sees live output resume with no restart.
- [ ] **AC5** — Closing the laptop lid (or killing the terminal, or dropping Tailscale): tmux session and claude process continue running on macmini. No cleanup is triggered.
- [ ] **AC6** — After disconnect, re-running `claudehome` and picking the same project re-attaches to the same tmux session. Scroll history is intact; output that streamed while disconnected is visible in the scrollback.
- [ ] **AC7** — Inside an attached session, typing `/exit` (or claude crashing) drops the pane into a `$SHELL` prompt **without killing the tmux session**. Running `claude` at that prompt relaunches claude in the same session.
- [ ] **AC8** — Two projects can have concurrent live tmux sessions. Attaching to one, detaching, and attaching to the other does not disturb either session's state.
- [ ] **AC9** — Overriding `CLAUDEHOME_HOST=othermacmini claudehome` targets a different Tailscale host. Overriding `CLAUDEHOME_PROJECTS_DIR` points at a different root on macmini.
- [ ] **AC10** — macmini has no claudehome-side daemon, config file, or persistent state. Only artifacts on macmini are tmux sessions and any directories the user created under the projects root.
- [ ] **AC11** — Detach keybinding is standard tmux `Ctrl-b d`. No custom bindings, no wrapper rendering. The attached terminal behaves identically to an SSH'd-in `tmux attach` against the same session.
- [ ] **AC12** — When `fzf` is present, the picker uses it. When absent, the picker falls back to bash `select` and the tool still works.
- [ ] **AC13** — `[new project]` is always the **last** row of the picker, even when `CLAUDEHOME_PROJECTS_DIR` is empty or does not yet exist on the mini.
- [ ] **AC14** — Selecting `[new project]` prompts `New project name:`. Empty input (or EOF) cancels cleanly with exit code 0; control does **not** loop back to the picker.
- [ ] **AC15** — Names containing characters outside `^[a-zA-Z0-9._-]+$` are rejected with a retry message that names the offending input. The same allowlist applied to env vars governs new-project names.
- [ ] **AC16** — Names matching an existing project directory under `CLAUDEHOME_PROJECTS_DIR` are rejected with a retry message naming the duplicate; only a fresh name proceeds.
- [ ] **AC17** — A valid fresh name causes the directory to be created on the mini (`mkdir -p` folded into the attach payload, single SSH round-trip preserved) and the user lands at a `claude` prompt in the new directory. `mkdir -p` is idempotent: re-running with an existing name is a no-op for the directory and falls through to normal attach.
- [ ] **AC18** — Existing-project rows are ordered by recency: active sessions first, sorted by tmux `session_activity` descending (most-recently-used at top); idle projects (no tmux session) cluster below the active group, sorted alphabetically. The `[new project]` sentinel always follows the project list.

## Assumptions Exposed & Resolved

| Assumption | Challenge | Resolution |
|------------|-----------|------------|
| "Feel identical to local Claude Code" is self-evident | What does "identical" actually mean? | Resolved: real terminal + real tmux + real claude, zero render-layer on top — same TTY behavior as SSH'ing in and typing `tmux attach` manually |
| Cold-start of a new project must be a day-one feature | Is it actually in your top-priority flow? | Resolved: no. v1 prioritizes *resume mid-task* and *multi-project concurrent*. Cold start is handled as a trivial side-effect of `tmux new-session -A`, not as a designed flow |
| Picker is the best default entry | What if 90% of use is "resume last"? | Resolved (Contrarian round): picker stays as the always-default. Simplicity and predictability win over a smart-default layer that'd need tracking |
| tmux session should die with claude | What if claude crashes mid-task? | Resolved: tmux outlives claude. Session drops to shell on claude-exit, preserving scrollback and enabling in-place relaunch |
| Open-source-ready polish should be v1 | Will anyone other than me use it soon? | Resolved: personal now, env-var configurable, open-source later as an additive step. No config files, no homebrew formula, no CONTRIBUTING.md in v1 |
| Need a project-list daemon/state | Why not use tmux itself as the source of truth? | Resolved: no state. `ls ~/projects/claudecode` for candidates, `tmux list-sessions` for liveness. Stateless design |

## Technical Context (greenfield)

### Implementation sketch
- `bin/claudehome` — single bash script, ~60 lines:
  1. Resolve env vars (with defaults)
  2. `ssh $USER@$HOST "ls -1 $PROJECTS_DIR && tmux list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null"` — one round-trip to fetch both projects and live sessions
  3. Cross-reference in-memory to build picker rows with active/idle + last-activity
  4. Pipe into `fzf` (or `select` fallback)
  5. On selection: `ssh -t $USER@$HOST "tmux new-session -A -s claudehome-<project> -c $PROJECTS_DIR/<project> 'claude; exec \$SHELL'"`
- `install.sh` — symlinks `bin/claudehome` into the first writable bin dir in `$PATH` (prefers `~/.local/bin`, falls back to `/usr/local/bin` with `sudo` prompt only if needed)
- `README.md` — updated with Quick Start (client install + Mac mini prerequisites checklist)

### File tree after v1
```
bin/claudehome          # the CLI
install.sh              # symlink installer
README.md               # updated
CLAUDE.md               # unchanged
```

No package.json, no Dockerfile, no systemd units. This is intentionally boring.

## Ontology (Key Entities)

| Entity | Type | Fields | Relationships |
|--------|------|--------|---------------|
| Client | external | Tailscale hostname, local `$USER`, has `ssh` + optional `fzf` | Initiates SSH to MacMini |
| MacMini | external system | Tailscale hostname (default `macmini`), has `tmux` + `claude` in PATH, SSH enabled | Hosts Projects and TmuxSessions |
| Project | core | `name` (directory name), `path` (`~/projects/claudecode/<name>`) | Belongs to MacMini; has 0..1 TmuxSession at a time |
| TmuxSession | core | `name` (`claudehome-<project>`), `state` (active/idle), `last_activity` (unix ts) | Runs on MacMini; hosts exactly one running process (ClaudeCodeSession or Shell) |
| ClaudeCodeSession | core | `claude` process inside tmux | Replaceable inner child of TmuxSession; exits do not kill session |
| Shell | supporting | user's `$SHELL` (zsh/bash) | Takes over TmuxSession pane when ClaudeCodeSession exits; allows in-place relaunch |

## Ontology Convergence

| Round | Entities | New | Changed | Stable | Stability |
|-------|----------|-----|---------|--------|-----------|
| 1 | 5 | 5 | - | - | N/A |
| 2 | 5 | 0 | 0 | 5 | 100% |
| 3 | 6 | 1 (Shell) | 0 | 5 | 83% |
| 4 | 6 | 0 | 0 | 6 | 100% |

Domain model fully converged by round 4. The lifecycle question (round 3) was the only round to expand the ontology — introducing `Shell` as a distinct entity once we decided tmux outlives claude.

## Interview Transcript

<details>
<summary>Full Q&A (4 rounds)</summary>

### Round 1 — Success Criteria
**Q:** Which scenario best matches what has to work flawlessly before calling v1 shipped: cold start on fresh project / resume active session mid-task / multi-project concurrent / all three equally?
**A:** 2 and 3 (resume mid-task + multi-project concurrent)
**Ambiguity:** 34.5% (Goal: 0.85, Constraints: 0.50, Criteria: 0.55)

### Round 2 — Constraints
**Q:** Who is claudehome for, and how polished does the install experience need to be?
**A:** Personal now, open-source later (env-var configurable, clean enough to promote later)
**Ambiguity:** 28.5% (Goal: 0.85, Constraints: 0.70, Criteria: 0.55)

### Round 3 — Success Criteria
**Q:** You close your laptop lid mid-claude-task. 4h later, what MUST be true? (eternal / alive while claude alive / detach=goodbye / TTL'd)
**A:** Option 1 (eternal), asked for my recommendation. Locked: eternal, AND tmux outlives claude.
**Ambiguity:** 18.3% (Goal: 0.88, Constraints: 0.75, Criteria: 0.80)

### Round 4 — Goal (Contrarian Mode)
**Q:** Is the picker-first CLI surface actually right, or would smart-default / named-target / full subcommands fit daily use better?
**A:** Picker always (current plan). Preview showed project + active/idle + last-active timestamp.
**Ambiguity:** 12.5% (Goal: 0.95, Constraints: 0.80, Criteria: 0.85)

</details>
