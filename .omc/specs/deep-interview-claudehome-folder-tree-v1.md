# Deep Interview Spec: claudehome folder-tree v1

## Metadata
- Interview ID: ch-foldertree-2026-05-08
- Rounds: 5
- Final Ambiguity Score: 14.0%
- Type: brownfield
- Generated: 2026-05-08
- Threshold: 20%
- Initial Context Summarized: no
- Status: PASSED
- Builds on: `deep-interview-claudehome-v1.md` (Mac AC1–AC18, AC-LOCAL1–4) and `deep-interview-claudehome-pc-v1.md` (PC AC-PC1–AC-PC9)

## Clarity Breakdown
| Dimension | Score | Weight | Weighted |
|-----------|-------|--------|----------|
| Goal Clarity | 0.95 | 0.35 | 0.333 |
| Constraint Clarity | 0.85 | 0.25 | 0.213 |
| Success Criteria | 0.75 | 0.25 | 0.188 |
| Context Clarity | 0.85 | 0.15 | 0.128 |
| **Total Clarity** | | | **0.860** |
| **Ambiguity** | | | **0.140** |

## Goal

Add hierarchical folder organization to the `claudehome` project picker so users can group projects under arbitrarily nested folders (e.g. `work/client-a/site`) without changing how individual projects, tmux sessions, or `claude` invocations work.

The picker becomes a **drill-down**:
1. Top-level shows folders + a synthetic `(root)` bucket containing any projects sitting flat at the root + `[new folder here]` + `[new project here]`.
2. Selecting a folder drills into it, revealing its contents (sub-folders, projects, both creation rows).
3. Selecting a project attaches to its tmux session exactly as today — `tmux new-session -A -s claudehome-<basename>`.

Folders are pure organization. They do **not** affect tmux session naming, identity, or the `claude` invocation. A project named `site` is `claudehome-site` regardless of where in the tree it lives.

## Constraints

### Discovery
- Project discovery walks the tree under `CLAUDEHOME_PROJECTS_DIR` recursively.
- A directory is a **project** if it directly contains no claudehome-specific marker — any leaf directory is a project; any directory containing other directories is a folder.
  - **Heuristic v1:** a directory is treated as a *folder* if every immediate child is itself a directory; otherwise it is a *project*. Empty directories are projects (so `[new project]` works).
  - This is a simple rule; revisit if it produces surprises.
- The synthetic `(root)` bucket appears at step 1 only when at least one project lives directly under `CLAUDEHOME_PROJECTS_DIR`. It never appears at deeper drill levels.

### Project naming & uniqueness
- **Project names are globally unique across the entire tree.** `[new project here]` rejects a name that exists anywhere in the tree, citing the conflicting path in the error.
- Allowed characters in project names: `[a-zA-Z0-9._-]` (unchanged from AC15 / AC-PC9).
- Tmux session naming convention is **unchanged**: `claudehome-<basename>`. No path encoding, no separator, no breaking change for the existing 14 flat projects.

### Folder naming & creation
- `[new folder here]` is shown at every drill level (including root).
- Allowed characters in folder names: `[a-zA-Z0-9._-]` (same allowlist as projects).
- Folder names must not collide with a sibling folder OR sibling project at the same drill level. Folders in different parents may share a name.
- Folder creation is `mkdir -p <current-drill-path>/<folder-name>`. After creation, the picker drills into the new folder, which is empty and shows only `[new folder here]` + `[new project here]`.
- **Folders are never automatically deleted.** An empty folder persists until the user removes it manually (mirrors the existing "no daemons, no background workers" guardrail).

### Project creation
- `[new project here]` is shown at every drill level (including root).
- Creates `mkdir -p <current-drill-path>/<project-name>` and immediately launches `tmux new-session -A -s claudehome-<project-name>` in that directory, exactly as AC18 / AC-PC9 do today.
- Duplicate name check walks the entire tree (globally unique constraint above).

### Picker UX
- `fzf` (Mac) and `fzf` if available on Windows (PC) remain the preferred picker. Fallback is bash `select` (Mac) / `Read-Host` numbered menu (PC), unchanged.
- Each drill screen is a single picker invocation. Selecting a folder re-invokes the picker for that folder. Selecting a project (or a creation row) terminates the drill.
- Picker rows are ordered:
  1. Folders first, alphabetical, with trailing `/` and child count: `work/  (5)`
  2. Then projects, ordered by tmux activity descending (active first, then idle alphabetical) — same rule as AC-PC9 today.
  3. Then `(root)` bucket if applicable (top-level only).
  4. Then `[new folder here]`.
  5. Then `[new project here]` (always last, mirrors AC13–AC18 / AC-PC9).
- A non-root drill screen shows a `[..  back]` row at the very top to navigate to the parent.

### Mac vs PC parity
- Both `bin/claudehome` (bash) and `bin/claudehome.ps1` (pwsh 7+) get drill-down support. Same UX, same rules, same picker rows.
- `bin/claudehome.cmd` shim is unchanged.

### Local mode
- `CLAUDEHOME_LOCAL=1` (or auto-detected local mode in `bin/claudehome`) walks the local tree. Same rules.
- The tmux-server LaunchAgent (`install_server.sh`, AC-LOCAL4) is unaffected — folders don't change tmux behavior.

### Migration
- **Zero migration.** The existing 14 flat projects under `~/projects/claudehome-projects` continue to work. They appear in the synthetic `(root)` bucket at step 1.
- No installer prompt, no one-shot move script, no first-run reorg.

### Configuration
- No new env vars. No additions to `~/.claudehomerc`. The drill-down is a pure code change.
- Folder layout is reflected on disk; there is no `.claudehome/folders.json` or any other state file (preserves the "no state files" guardrail in `CLAUDE.md`).

## Non-Goals

- **Tagging or virtual folders.** A project lives in exactly one place on disk. No multi-folder membership, no tags, no symlinks-as-membership.
- **Path-encoded session names.** Tmux session names stay `claudehome-<basename>`. The folder a project lives in is invisible at the tmux layer.
- **Per-folder uniqueness.** Names are globally unique; do not implement scoped uniqueness.
- **Configurable separator / config keys.** No `CLAUDEHOME_PATH_SEP`, no installer prompt for tree behavior.
- **`mv` / rename / delete from the picker.** Reorganization happens manually via shell `mv` / `mkdir` / `rmdir`. The picker is read-mostly + create-only (mirrors current AC13–AC18).
- **Tree picker with indentation in one screen** (e.g. fzf tree-preview). Drill-down is the chosen UX; do not also build a flat tree view.
- **Auto-cleanup of empty folders.** Empty folders persist; user removes them manually.
- **Subcommands like `claudehome new <path>` or `claudehome ls --tree`.** CLI surface stays at `claudehome` / `claudehome --help` per existing scope guardrails.

## Acceptance Criteria

These extend the existing AC numbering. Mac criteria are **AC-FT1–AC-FT12**, PC criteria are **AC-FT-PC1–AC-FT-PC10**, shared/local are **AC-FT-LOCAL1–AC-FT-LOCAL2**.

### Mac client (bash) — `bin/claudehome`

- [ ] **AC-FT1** — With existing 14 flat projects and zero folders, `claudehome` opens the picker and shows the same flat list as before. Step 1 has no folder rows; the synthetic `(root)` bucket does not appear (it only appears when both folders AND root projects coexist).
- [ ] **AC-FT2** — Selecting `[new folder here]` at root prompts for a folder name, validates `[a-zA-Z0-9._-]`, refuses sibling-name collisions (folder OR project at the same level), creates `mkdir -p ${PROJECTS_DIR}/<name>`, then drills into the empty new folder showing only `[..  back]`, `[new folder here]`, `[new project here]`.
- [ ] **AC-FT3** — From inside a folder (e.g. `work/`), selecting `[new project here]` creates `mkdir -p ${PROJECTS_DIR}/work/<name>`, then attaches `tmux new-session -A -s claudehome-<name>`. The session name encodes the basename only (not the path).
- [ ] **AC-FT4** — Creating `[new project here]` with a name that already exists *anywhere in the tree* fails with an error citing the conflicting path (e.g. `"site already exists at work/site"`), and re-prompts.
- [ ] **AC-FT5** — Selecting a folder drills into it. The new picker shows `[..  back]` at top, then sub-folders, then projects, then `[new folder here]`, then `[new project here]`. Selecting `[..  back]` returns to the parent picker.
- [ ] **AC-FT6** — Once both folders and root-level projects exist, step 1 shows folders + a synthetic `(root)` row labeled `(root)  (N)`. Drilling into `(root)` shows the flat root projects with the same active/idle annotations as today.
- [ ] **AC-FT7** — Picker row ordering at every drill level: `[..  back]` (non-root only) → folders alphabetical → projects sorted by tmux activity descending (active first, idle alphabetical below) → `(root)` bucket (root only) → `[new folder here]` → `[new project here]`.
- [ ] **AC-FT8** — Active/idle annotations on projects work identically regardless of folder depth (same `tmux list-sessions` lookup keyed on `claudehome-<basename>`).
- [ ] **AC-FT9** — Folder name validation rejects names containing characters outside `[a-zA-Z0-9._-]` with a clear error and re-prompt.
- [ ] **AC-FT10** — A folder with no children still shows in the parent picker (count `(0)`). Drilling into it shows only `[..  back]`, `[new folder here]`, `[new project here]`.
- [ ] **AC-FT11** — `claudehome --help` / `claudehome -h` continue to print the existing usage. No new flags are added; the CLI surface remains exactly `claudehome` and `claudehome --help`.
- [ ] **AC-FT12** — `shellcheck bin/claudehome install_client.sh install_server.sh` passes with no warnings.

### PC client (pwsh 7+) — `bin/claudehome.ps1`

- [ ] **AC-FT-PC1** — With existing flat projects and zero folders on the mini, `claudehome` from pwsh shows the same flat list as before (no folder rows, no `(root)` bucket). AC-PC1, AC-PC5 behavior unchanged.
- [ ] **AC-FT-PC2** — `[new folder here]` works at every drill level. Validation matches Mac (allowlist + sibling-collision rules).
- [ ] **AC-FT-PC3** — `[new project here]` works at every drill level and creates `tmux new-session -A -s claudehome-<basename>` on the mini. Session name encodes basename only.
- [ ] **AC-FT-PC4** — Globally-unique project name check runs against the entire remote tree; conflicts cite the path.
- [ ] **AC-FT-PC5** — Drill-down works with both `fzf` (when on PATH) and the `Read-Host` numbered menu fallback.
- [ ] **AC-FT-PC6** — `[..  back]` row appears at the top of every non-root drill screen.
- [ ] **AC-FT-PC7** — Active/idle annotations work at every drill depth.
- [ ] **AC-FT-PC8** — Picker row ordering matches Mac AC-FT7.
- [ ] **AC-FT-PC9** — Selecting an existing project (Mac → PC parity test) results in both clients attached to the same tmux session simultaneously, including projects nested under folders. AC-PC6 still holds.
- [ ] **AC-FT-PC10** — `Invoke-ScriptAnalyzer bin/claudehome.ps1 install_client.ps1` passes.

### Local mode

- [ ] **AC-FT-LOCAL1** — `CLAUDEHOME_LOCAL=1 claudehome` walks the local tree (no SSH) and produces the same drill-down. Performance: subsecond on trees up to ~1000 entries.
- [ ] **AC-FT-LOCAL2** — From an iPhone SSH session into the mini, drill-down works identically to the local terminal.

## Assumptions Exposed & Resolved

| Assumption | Challenge | Resolution |
|------------|-----------|------------|
| "Folder tree" = nested directories on disk | Could have meant visual grouping, two-step picker, or tree picker | User chose two-step / drill-down picker over real nested directories — interpreted as drill-down UX with arbitrary disk depth |
| Existing 14 flat projects need migration | Could be force-nested, manual move, or stay flat | User chose stay-flat with synthetic `(root)` bucket. Zero migration. |
| Depth is limited to 1 | Round-1 "two-step" suggested depth=1, but it really meant drill-down UX | User confirmed arbitrary depth in round 3 |
| Tmux session names need path encoding to avoid collisions | Per-folder name uniqueness would force encoding | User chose globally-unique names instead → simple `claudehome-<basename>` stays |
| Need a config key for path separator | Three options offered (`__`, `.`, configurable) | Globally-unique names eliminate the need for a separator entirely |
| Picker should let users create folders at every drill level | Could be root-only, or never (mkdir manually), or everywhere | User chose `[new folder here]` + `[new project here]` at every level |

## Technical Context

### Files that change
- `bin/claudehome` (~310 lines today; expect +120–180 lines for tree walk + drill-down + folder creation rows)
- `bin/claudehome.ps1` (~228 lines today; expect proportional growth)
- `CLAUDE.md` — update "Architecture (one paragraph)" to mention drill-down and globally-unique naming. Add the new ACs to the post-install verification section if PC-side, and to the spec links list.
- Tests / smoke tests — keep `bin/claudehome --help` and `bin/claudehome.ps1 --help` exit-0 smoke tests; add a tree-walk fixture if a test harness exists.

### Files that do NOT change
- `install_client.sh`, `install_client.ps1`, `install_server.sh` — no installer prompts, no new env vars.
- `~/.claudehomerc` format — no new keys.
- `LaunchAgents/com.<user>.tmux-server.plist` — irrelevant to picker.
- Tmux session naming convention — `claudehome-<basename>` everywhere.

### Code structure considerations (from existing CLAUDE.md ADR)
- The bash client must keep its **single SSH round-trip** for listing in remote mode. The remote-side `bash --norc --noprofile -c '…'` payload must therefore emit the **entire tree** in one shot (e.g. as a sentinel-delimited list of `path<TAB>session_state<TAB>last_activity` rows). The client parses that into a tree structure and runs the picker locally.
- `tmux new-session -A` semantics, `; exec $SHELL` tail, and lack of `-D` (multi-client attach) all stay.
- Local-mode short-circuit (`CLAUDEHOME_LOCAL=1`) walks the local FS — no remote payload needed.

### Brownfield code anchors
- Bash discovery to replace: `bin/claudehome:174` (local) and `bin/claudehome:182–184` (remote).
- PowerShell discovery to replace: `bin/claudehome.ps1:89`.
- Bash picker row build: `bin/claudehome:213–229`.
- PowerShell picker row build: `bin/claudehome.ps1:140–162`.
- Bash new-project flow to extend: `bin/claudehome:257–275, 303, 308`.
- PowerShell new-project flow to extend: `bin/claudehome.ps1:191–207, 227`.
- Session-name extraction: `bin/claudehome:277` and `bin/claudehome.ps1:207` — must keep `${SELECTED%%  *}` semantics; folder rows (`work/  (5)`) must be distinguishable from project rows so the parser routes them to drill-down rather than tmux-attach.

## Ontology (Key Entities)

| Entity | Type | Fields | Relationships |
|--------|------|--------|---------------|
| Folder | core domain | name, parent_path | contains 0..n Folders, contains 0..n Projects |
| Project | core domain | name (globally unique), parent_path, session_state, last_activity | belongs to exactly one of: a Folder OR root |
| Picker | supporting | current_drill_path, mode (drill-or-attach) | shows Folders/Projects at current path, offers `[new folder here]`/`[new project here]` and `[..  back]` (non-root only) |
| RootBucket | supporting | count | synthetic step-1 row representing root-level Projects when both root projects AND folders coexist |

## Ontology Convergence

| Round | Entity Count | New | Changed | Stable | Stability Ratio |
|-------|-------------|-----|---------|--------|-----------------|
| 1 | 3 | 3 (Folder, Project, Picker) | — | — | N/A |
| 2 | 4 | 1 (RootBucket) | 0 | 3 | 75% |
| 3 | 4 | 0 | 2 (Folder→self-referential, Project→added path) | 2 | 100% |
| 4 | 4 | 0 | 1 (Picker→per-level creation affordances) | 3 | 100% |
| 5 | 4 | 0 | 2 (Folder→organization-only, Project→session-name simplified back to basename) | 2 | 100% |

Domain model converged at round 3 and stayed at 4 entities with only refinements thereafter.

## Interview Transcript

<details>
<summary>Full Q&A (5 rounds)</summary>

### Round 1
**Targeting:** Goal Clarity (0.0)
**Q:** When you say "folder tree," which of these is closest to what you want? — Real nested directories / Visual grouping only / Two-step picker / Tree picker (fzf-tree)
**A:** Two-step picker (drill into a folder, then pick a project inside it)
**Ambiguity:** 61.5% (Goal: 0.6, Constraints: 0.2, Criteria: 0.2, Context: 0.5)

### Round 2
**Targeting:** Constraint Clarity (0.2)
**Q:** What should happen to the existing 14 flat projects? — Stay flat with `(root)` bucket / I'll move them manually / Force nesting / Both allowed forever
**A:** Stay flat, picker shows root
**Ambiguity:** 49.0% (Goal: 0.7, Constraints: 0.5, Criteria: 0.2, Context: 0.6)

### Round 3
**Targeting:** Constraint Clarity (0.5)
**Q:** How deep can the folder tree go? — Exactly 1 level / Arbitrary depth / 1 level with breadcrumb session name
**A:** Arbitrary depth (drill-down)
**Ambiguity:** 37.3% (Goal: 0.85, Constraints: 0.6, Criteria: 0.3, Context: 0.7) — note: "two-step" in round 1 reads as "drill-down" not literally 2 steps; reconciled here.

### Round 4 (Contrarian mode)
**Targeting:** Success Criteria (0.3) + Constraints
**Q:** Drilled into work/client-a/, what does the picker offer for creation? — Both at every level / [new project] anywhere, folders only at root / Folders by mkdir, picker only creates projects / [new project] only at root with slash-separated path
**A:** Both, at every level
**Ambiguity:** 24.8% (Goal: 0.9, Constraints: 0.7, Criteria: 0.6, Context: 0.75)

### Round 5 (Simplifier mode, applied early)
**Targeting:** Constraints (0.7) → Success Criteria (0.6)
**Q:** Inside personal/, creating 'site' when work/site exists — what happens? — Allowed with path-encoded session names / Forbidden, globally unique / Allowed with user-configurable separator
**A:** Forbidden; names globally unique
**Ambiguity:** 14.0% (Goal: 0.95, Constraints: 0.85, Criteria: 0.75, Context: 0.85) — **threshold met**

</details>
