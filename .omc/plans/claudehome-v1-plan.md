# claudehome v1 Implementation Plan

**Spec:** `.omc/specs/deep-interview-claudehome-v1.md`
**Date:** 2026-04-24
**Mode:** RALPLAN-DR (SHORT) -- low-risk personal tool, greenfield

---

## 1. RALPLAN-DR Summary

### Principles (what this plan optimizes for)

1. **Single-command simplicity** -- `claudehome` with no args does the entire job. Zero cognitive load.
2. **Minimal SSH round-trips** -- one SSH call to discover state, one to attach. Never three.
3. **tmux is the only state** -- no daemon, no config files, no sidecar. tmux sessions ARE the persistence layer.
4. **Graceful degradation** -- fzf preferred, bash `select` always works. Missing Mac mini = clear error, not hang.
5. **Additive extensibility** -- env vars now, config file later. No structural rewrites needed.

### Decision Drivers (top 3)

1. **Latency** -- every extra SSH round-trip adds ~100-300ms over Tailscale. Users feel this.
2. **Reliability of resume** -- the #1 use case is "pick up where I left off." Attach must never accidentally create a second session or lose scrollback.
3. **Zero Mac-mini-side setup** -- no scripts, daemons, or state to install on the server. Only standard tools (tmux, ssh, claude).

### Choice Points and Viable Options

#### CP1: SSH data-fetch strategy (projects + session state)

| Option | Pros | Cons |
|--------|------|------|
| **A: Single SSH, compound command** (`ssh host "ls ... && tmux list-sessions ... 2>/dev/null"`) | One round-trip (~150ms). Simple to parse. | Slightly complex quoting. `ls` and `tmux` output must be disambiguated. |
| B: Two separate SSH calls (one for `ls`, one for `tmux list-sessions`) | Trivial parsing per call. | Two round-trips (~300ms+). Noticeable latency hit. |

**Chosen: A.** Latency is Decision Driver #1. The quoting complexity is a one-time authoring cost; the latency saving is felt every invocation. Disambiguation is trivial: use a separator marker (`---`) between `ls` output and `tmux` output.

#### CP2: Picker implementation

| Option | Pros | Cons |
|--------|------|------|
| **A: fzf with bash `select` fallback** | fzf gives type-to-filter, arrow keys, instant UX. `select` is built into bash, zero deps. | Two code paths to maintain (~10 extra lines). |
| B: fzf only, error if missing | Simpler code. | Breaks on machines without fzf. Violates graceful-degradation principle. |
| C: bash `select` only | Zero external deps. | Unusable for >5 projects. No type-to-filter. |

**Chosen: A.** The spec mandates this (AC12). Both code paths are under 10 lines each.

#### CP3: install.sh symlink target

| Option | Pros | Cons |
|--------|------|------|
| **A: Prefer `~/.local/bin`, fall back to `/usr/local/bin`** | No sudo needed in the common case. XDG-friendly. | `~/.local/bin` might not be in PATH on stock macOS. |
| B: Always `/usr/local/bin` | Universally in PATH on macOS. | Always needs sudo. |

**Chosen: A.** Personal tool -- the user controls their PATH. install.sh will warn if `~/.local/bin` is not in PATH and suggest adding it. Falls back to `/usr/local/bin` with sudo prompt only if `~/.local/bin` doesn't exist or isn't in PATH.

---

## 2. Implementation Plan

### Deliverable 1: `bin/claudehome` (~80 lines)

#### Section 1: Preamble and help (lines ~1-15)

```
#!/usr/bin/env bash
set -euo pipefail

# --help / -h
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  cat <<'USAGE'
Usage: claudehome

  Connect to a persistent Claude Code session on your Mac mini.
  Lists projects, shows session state, and attaches via tmux over SSH.

Environment variables:
  CLAUDEHOME_HOST          Tailscale hostname (default: macmini)
  CLAUDEHOME_USER          SSH user (default: $USER)
  CLAUDEHOME_PROJECTS_DIR  Projects root on host (default: ~/projects/claudecode)
USAGE
  exit 0
fi
```

**Satisfies:** Part of AC1 (tool exists and is invocable), AC9 (env vars documented).

#### Section 2: Env-var resolution (lines ~16-20)

```
HOST="${CLAUDEHOME_HOST:-macmini}"
REMOTE_USER="${CLAUDEHOME_USER:-$USER}"
PROJECTS_DIR="${CLAUDEHOME_PROJECTS_DIR:-~/projects/claudecode}"
```

**Satisfies:** AC9 (overrides work).

#### Section 3: SSH data fetch -- single round-trip (lines ~21-38)

```
# One SSH call: list project dirs, then tmux sessions
RAW=$(ssh "${REMOTE_USER}@${HOST}" "
  ls -1 ${PROJECTS_DIR} 2>/dev/null
  echo '---TMUX---'
  tmux list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null || true
") || { echo "Error: cannot reach ${HOST} via SSH." >&2; exit 1; }

# Split on marker
PROJECTS_BLOCK="${RAW%%---TMUX---*}"
TMUX_BLOCK="${RAW#*---TMUX---}"

# Parse tmux sessions into associative array: session_name -> last_activity_ts
declare -A SESSIONS
while IFS=' ' read -r name ts; do
  [[ -n "$name" ]] && SESSIONS["$name"]="$ts"
done <<< "$TMUX_BLOCK"
```

**Satisfies:** AC1 (lists projects), AC2 (session state data available).

#### Section 4: Build picker rows (lines ~39-55)

```
# Build display lines: "project_name  [active 2h ago] / [idle]"
PICKER_LINES=()
PICKER_NAMES=()
NOW=$(date +%s)

while IFS= read -r project; do
  [[ -z "$project" ]] && continue
  session_name="claudehome-${project}"
  if [[ -n "${SESSIONS[$session_name]+x}" ]]; then
    ts="${SESSIONS[$session_name]}"
    age=$(( NOW - ts ))
    # Convert seconds to human-readable
    if (( age < 60 )); then label="${age}s ago"
    elif (( age < 3600 )); then label="$(( age / 60 ))m ago"
    elif (( age < 86400 )); then label="$(( age / 3600 ))h ago"
    else label="$(( age / 86400 ))d ago"; fi
    PICKER_LINES+=("${project}  [active ${label}]")
  else
    PICKER_LINES+=("${project}  [idle]")
  fi
  PICKER_NAMES+=("$project")
done <<< "$PROJECTS_BLOCK"

if [[ ${#PICKER_NAMES[@]} -eq 0 ]]; then
  echo "No projects found in ${PROJECTS_DIR} on ${HOST}." >&2
  exit 1
fi
```

**Satisfies:** AC1 (picker listing), AC2 (name + state + time annotation).

#### Section 5: Picker -- fzf or select (lines ~56-72)

```
# Picker
if command -v fzf &>/dev/null; then
  SELECTED=$(printf '%s\n' "${PICKER_LINES[@]}" | fzf --prompt="claudehome> " --height=~50%) || exit 0
else
  echo "Select a project:"
  select SELECTED in "${PICKER_LINES[@]}"; do
    [[ -n "$SELECTED" ]] && break
  done
fi

# Extract project name (first field before double-space)
PROJECT="${SELECTED%%  *}"
```

**Satisfies:** AC12 (fzf when present, select fallback).

#### Section 6: Attach via tmux (lines ~73-80)

```
# Attach or create tmux session on Mac mini
exec ssh -t "${REMOTE_USER}@${HOST}" \
  "tmux new-session -A -s claudehome-${PROJECT} -c ${PROJECTS_DIR}/${PROJECT} 'claude; exec \$SHELL'"
```

**Satisfies:** AC3 (creates session + launches claude), AC4 (attaches to existing), AC5 (persistence on disconnect -- inherent to tmux), AC6 (re-attach preserves scrollback), AC7 (claude exit drops to shell), AC8 (concurrent sessions -- each project gets its own tmux session name), AC10 (no daemon/state on Mac mini), AC11 (standard tmux keybindings, no wrapper).

### Deliverable 2: `install.sh` (~30 lines)

**Step-by-step logic:**

1. Resolve `SCRIPT_DIR` to the absolute path of the repo's `bin/claudehome`.
2. Check that `bin/claudehome` exists and is executable; error if not.
3. Check if `~/.local/bin` exists and is in `$PATH`:
   - Yes: symlink to `~/.local/bin/claudehome`. Done.
   - No, but `~/.local/bin` exists (just not in PATH): symlink there, warn user to add it to PATH.
   - `~/.local/bin` doesn't exist: create it, symlink, warn about PATH.
   - If user passes `--system`: symlink to `/usr/local/bin/claudehome` with `sudo`.
4. Verify symlink works: run `claudehome --help` and check exit code.
5. Print success message with next-steps hint.

**Failure handling:**
- If symlink target already exists and is not our symlink, warn and abort (don't overwrite).
- If `sudo` fails, print clear message and exit 1.

**Satisfies:** Distribution constraint from spec. Supports both personal (`~/.local/bin`) and system-wide (`/usr/local/bin`) installs.

### Deliverable 3: `README.md` -- Content Outline

1. **Title + one-liner** -- "claudehome: persistent Claude Code sessions on your Mac mini"
2. **How it works** -- 3-sentence description + simple diagram (ASCII: laptop -> Tailscale -> Mac mini -> tmux -> claude)
3. **Quick Start**
   - Prerequisites (Client): Tailscale, SSH, optional fzf
   - Prerequisites (Mac mini): Tailscale, SSH enabled, tmux, claude in PATH, SSH key authorized
   - Install: `git clone ... && ./install.sh`
   - Run: `claudehome`
4. **Configuration** -- env var table (CLAUDEHOME_HOST, CLAUDEHOME_USER, CLAUDEHOME_PROJECTS_DIR) with defaults
5. **Usage** -- what happens on run (picker -> select -> attach). What detach/disconnect/exit each do.
6. **Troubleshooting** -- 3-4 common issues (can't reach host, tmux not installed, claude not in PATH, fzf missing)
7. **Non-goals (v1)** -- brief list pointing to spec for rationale
8. **License** -- MIT or similar (user's choice)

### Deliverable 4: `CLAUDE.md` additions

Add the following lines to the existing CLAUDE.md:

- `## Development` section with:
  - "Main script: `bin/claudehome` (bash). Run `shellcheck bin/claudehome` to lint."
  - "Install locally: `./install.sh` or `ln -sf $(pwd)/bin/claudehome ~/.local/bin/claudehome`"
  - "Test: `bin/claudehome --help` should print usage. Full integration requires a Tailscale-reachable Mac mini with tmux."

---

## 3. Acceptance Criteria Map

| AC | Description | Plan Section | Verification Type |
|----|-------------|-------------|-------------------|
| AC1 | Picker lists every project subdir | Sections 3-5 of bin/claudehome | requires-mac-mini |
| AC2 | Rows show name + state + last-activity | Section 4 (build picker rows) | requires-mac-mini |
| AC3 | No-session select creates tmux + launches claude + attaches | Section 6 (tmux new-session -A) | requires-mac-mini |
| AC4 | Existing-session select attaches; live output resumes | Section 6 (tmux -A attach) | requires-mac-mini |
| AC5 | Close lid: tmux + claude persist | Section 6 (inherent tmux behavior) | requires-mac-mini |
| AC6 | Re-attach after disconnect: scrollback intact | Section 6 (inherent tmux behavior) | requires-mac-mini |
| AC7 | `/exit` drops to shell, not session kill | Section 6 (`claude; exec $SHELL`) | requires-mac-mini |
| AC8 | Two concurrent sessions don't interfere | Section 6 (unique session names) | requires-mac-mini |
| AC9 | Env var overrides work | Section 2 (env-var resolution) | local-runnable |
| AC10 | No daemon/config/state on Mac mini | Architecture (no server-side component) | static |
| AC11 | Standard tmux keybindings, no wrapper | Section 6 (`exec ssh -t` with raw tmux) | static |
| AC12 | fzf picker + select fallback | Section 5 (command -v fzf check) | local-runnable |

**Flags:** All ACs are clearly satisfied by the plan. No gaps identified. AC5 and AC6 are inherent tmux properties rather than explicit code -- they pass by virtue of using tmux correctly. This is documented, not a risk.

---

## 4. Explicit Tradeoff Calls

| Decision | Chosen | Alternative | Why |
|----------|--------|-------------|-----|
| SSH data-fetch strategy | Single compound SSH call (CP1-A) | Two separate calls (CP1-B) | Latency is Driver #1. ~150ms vs ~300ms+ per invocation. Quoting complexity is a one-time cost. |
| Picker implementation | fzf + select fallback (CP2-A) | fzf-only (CP2-B) | Spec mandates fallback (AC12). Graceful degradation is a core principle. |
| Symlink target | ~/.local/bin first (CP3-A) | /usr/local/bin always (CP3-B) | Personal tool, no sudo needed in happy path. Warning message covers the PATH-not-set edge case. |
| Marker-based output splitting | `---TMUX---` sentinel | Separate SSH calls | Keeps single-round-trip design. Sentinel is unlikely to collide with a project directory name. |
| Time formatting | Inline bash arithmetic | External `date` or `gdate` calls | Zero deps, portable across macOS/Linux bash. Slightly less precise (no "2h 15m", just "2h") but good enough for v1. |

---

## 5. Test / Verification Plan

### Phase 1: Static verification (no Mac mini needed)

1. **shellcheck** -- Run `shellcheck bin/claudehome` and `shellcheck install.sh`. Fix all warnings.
2. **--help output** -- Run `bin/claudehome --help`, verify it prints usage with all three env vars documented.
3. **Code review AC10** -- Read the script and confirm: no files written to Mac mini, no daemon, no sidecar.
4. **Code review AC11** -- Confirm the attach command is bare `ssh -t ... tmux new-session -A`, no wrapper.

### Phase 2: Local-runnable verification (mock environment)

5. **AC9 (env var overrides)** -- Set `CLAUDEHOME_HOST=fakemini` and run; confirm the SSH target in the error message is `fakemini`. Repeat for `CLAUDEHOME_USER` and `CLAUDEHOME_PROJECTS_DIR`.
6. **AC12 (picker fallback)** -- Create a mock script that simulates SSH output (projects + tmux sessions). Test with `fzf` in PATH (verify fzf picker renders). Rename fzf temporarily; verify `select` fallback activates.
7. **install.sh** -- Run in a temp dir, verify symlink is created correctly, verify `--system` path, verify existing-symlink guard.

### Phase 3: Mac mini integration (requires real Tailscale + Mac mini)

8. **AC1** -- Run `claudehome`. Verify picker shows all subdirs of `~/projects/claudecode` on macmini.
9. **AC2** -- Verify at least one active and one idle project display correctly with time labels.
10. **AC3** -- Pick a project with no session. Verify tmux session created, claude launches, interactive prompt appears.
11. **AC4** -- With a session running, detach (`Ctrl-b d`), re-run `claudehome`, pick same project. Verify instant re-attach with live output.
12. **AC7** -- Inside session, type `/exit`. Verify shell prompt appears, tmux session still alive. Type `claude` to relaunch.
13. **AC5 + AC6** -- Close laptop lid. Wait 30s. Open lid. Run `claudehome`, pick same project. Verify scrollback intact, session resumed.
14. **AC8** -- Open two terminal tabs. Attach to two different projects simultaneously. Verify both sessions independent.

### Recommended verification order

Static (5 min) -> Local-runnable (10 min) -> Mac mini integration (15 min). Total: ~30 minutes for full verification.

---

## 6. ADR: Single SSH Round-Trip for Data Fetch

### Decision

Use a single SSH command with a sentinel-delimited compound payload (`ls` output + `---TMUX---` + `tmux list-sessions` output) to fetch all picker data in one round-trip.

### Drivers

1. Every SSH handshake over Tailscale adds ~100-300ms of latency. The tool runs every time the user wants to resume work -- this latency is felt directly.
2. The data needed (project list + session state) is small and independent, making it natural to batch.
3. The tool's value proposition is "faster than manually SSH'ing in and running tmux attach" -- if the picker itself is slow, the tool fails its purpose.

### Alternatives Considered

1. **Two SSH calls** (one for `ls`, one for `tmux list-sessions`): Simpler parsing, but doubles round-trip latency. Rejected because latency is the top driver.
2. **Persistent SSH connection (ControlMaster)**: Would amortize handshake cost across both calls. Rejected because it adds complexity (socket management, cleanup) disproportionate to the v1 scope. Could be a v2 optimization.
3. **SSH multiplexing via ControlPersist in user's SSH config**: Would solve latency transparently. Not rejected -- but also not something the tool should require or configure. It's an orthogonal user optimization. The tool should be fast even without it.

### Why Chosen

The compound-command approach gives near-optimal latency (~150ms) with minimal code complexity (~5 lines of parsing). The sentinel `---TMUX---` is safe because it would never appear as a directory name. The approach requires no configuration, no persistent state, and no assumptions about the user's SSH config.

### Consequences

**Positive:**
- Fastest possible picker load time (single TCP round-trip)
- No persistent SSH connections to manage
- Stateless -- every invocation is self-contained

**Negative:**
- Quoting is slightly tricky (nested quoting in the SSH command string)
- If the sentinel ever collides with a directory name, parsing breaks (vanishingly unlikely)
- Error handling is coarser -- if `ls` succeeds but `tmux` fails, we still get a usable result (tmux block is empty, all projects show as idle). This is actually a graceful degradation, not a bug.

### Follow-ups (deferred to later)

- SSH ControlMaster/ControlPersist optimization: document it in README as a "power user tip," implement nothing
- If project count exceeds ~50, the single SSH payload might benefit from streaming. Not a v1 concern.
- The `date +%s` call for time comparison happens on the client. If client and Mac mini clocks are significantly out of sync (>minutes), the "2h ago" labels will be inaccurate. Tailscale machines typically use NTP, so this is a non-issue in practice.

---

## Scope Guardrails Confirmation

- No subcommands: confirmed (only `--help` flag)
- No config files: confirmed (env vars only)
- No daemon/state on Mac mini: confirmed (tmux only)
- No Windows/iPhone code: confirmed (Mac client bash only)
- No package.json/Dockerfile/systemd/brew: confirmed
- LoC target: bin/claudehome ~80 lines, install.sh ~30 lines: within budget

---

## Consensus Addendum (ralplan)

**Consensus status:** APPROVED by Critic (2026-04-24). Plan is ready for autopilot execution.

**Architect verdict:** SOUND_WITH_REVISIONS — two mandatory revisions listed below.
**Critic verdict:** APPROVE — revisions are implementation-level, not plan-level; apply during autopilot execution.

### Mandatory revisions (must be incorporated by the executor)

**Revision 1 — Isolate remote SSH command from user shell profile (HIGH impact)**

The SSH data-fetch command in Section 3 of this plan (the `ls ... && echo ---TMUX--- && tmux list-sessions ...` compound) runs in a login shell on the Mac mini. If the remote `~/.bashrc`, `~/.zshrc`, `~/.profile`, or shell plugins (conda, nvm, pyenv, Tailscale banners) print to stdout, that text prepends to the sentinel-parsed output and gets treated as phantom project names.

**Required change:** wrap the remote command in a shell invoked with profile isolation. Preferred form:

```bash
ssh "${CLAUDEHOME_USER}@${CLAUDEHOME_HOST}" "bash --norc --noprofile -c '
  ls -1 ${PROJECTS_DIR} 2>/dev/null || true
  echo ---TMUX---
  tmux list-sessions -F ... 2>/dev/null || true
'"
```

Apply to the data-fetch SSH call (Section 3). The attach SSH call (Section 6) is less affected because the user's shell runs inside tmux anyway, but apply the same wrapping for consistency.

**Revision 2 — README troubleshooting bullet for orphaned sessions (LOW impact, docs-only)**

With eternal tmux sessions and no in-tool cleanup (explicit Non-Goal), deleting a project directory leaves a ghost `claudehome-<project>` tmux session that keeps showing as "active" in the picker. No code fix; add a single troubleshooting bullet to README:

> **Cleaning up orphaned sessions.** If you delete a project directory from `~/projects/claudecode`, its tmux session lingers. Remove it with:
> ```
> ssh macmini 'tmux kill-session -t claudehome-<project-name>'
> ```

### Handoff notes for autopilot

- Execute this plan as-is, with the two revisions above applied during implementation.
- All 12 acceptance criteria (AC1–AC12) from the spec at `.omc/specs/deep-interview-claudehome-v1.md` must pass.
- Verification follows the three-phase plan in Section 4 (static / local-runnable / requires-mac-mini). Only static + local-runnable can be executed headlessly by autopilot; the requires-mac-mini ACs must be deferred to the user with a clear checklist.
- The user (Gene) has a real Mac mini reachable via Tailscale, but **autopilot should NOT assume it's accessible from the current working environment** — produce a "please run these on your Mac mini" checklist for Phase 3 verification instead.
- Scope is locked: do not add subcommands, config files, daemons, Windows/iPhone code, or any other expansions.
