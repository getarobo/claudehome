# Deep Interview Spec: claudehome 5-type structure v1

## Metadata
- Interview ID: ch-5type-2026-05-08
- Rounds: 3
- Final Ambiguity Score: 13.3%
- Type: brownfield
- Generated: 2026-05-08
- Threshold: 20%
- Status: PASSED
- Builds on: `deep-interview-claudehome-folder-tree-v1.md` (shipped, 1.2.0.0) and `deep-interview-claudehome-hub-aware-v1.md` (proposed; this spec subsumes/refactors it).

## Clarity Breakdown

| Dimension | Score | Weight | Weighted |
|---|---|---|---|
| Goal Clarity | 0.95 | 0.35 | 0.333 |
| Constraint Clarity | 0.88 | 0.25 | 0.220 |
| Success Criteria | 0.78 | 0.25 | 0.195 |
| Context Clarity | 0.80 | 0.15 | 0.120 |
| **Total Clarity** | | | **0.868** |
| **Ambiguity** | | | **0.132** |

## Goal

Replace the folder-tree-v1 binary classification (Folder vs Project, by "all-immediate-children-are-dirs" heuristic) with a **5-type structural classification** based on three signals:

1. Presence of `CLAUDE.md` regular file in the directory's immediate children.
2. Directory's basename suffix (`_suite`, `_hub`).
3. Directory's ancestor chain (whether any ancestor is a Suite).

The 5 types are **Folder**, **Suite**, **Project**, **Hub**, and **Member**. Each directory is exactly one type. Classification is purely structural — no CLAUDE.md content parsing, no marker files beyond the conventionally-named `CLAUDE.md` itself.

This unifies and supersedes the folder-tree-v1 heuristic AND the hub-aware-v1 spec's scaffolding rules into a single structural model.

## Type Definitions

```
type(dir):
  has_claude_md     = isfile(dir + "/CLAUDE.md")
  parent            = parent_dir(dir)
  parent_is_suite   = basename(parent) ends_with "_suite"
  has_suite_ancestor = any ancestor's basename ends_with "_suite"

  if has_claude_md:
    if parent_is_suite and basename(dir) ends_with "_hub":
      return HUB
    elif has_suite_ancestor:
      return MEMBER
    else:
      return PROJECT
  else:
    if basename(dir) ends_with "_suite":
      return SUITE
    else:
      return FOLDER
```

| Type | Has CLAUDE.md | Basename suffix | Ancestor constraints | Pick action |
|---|---|---|---|---|
| **Folder** | no | not `_suite` | any | drill |
| **Suite** | no | `_suite` | NOT inside another Suite (no nested Suites) | drill |
| **Project** | yes | not `_hub` | NO Suite ancestor | attach |
| **Hub** | yes | `_hub` | parent IS a Suite (top-level child only) | attach |
| **Member** | yes | not `_hub` (Hub-named at non-top-level is also Member) | has Suite ancestor (transitive) | attach |

## Constraints

### Suite contents (round 1)
- A Suite contains: at most one Hub (top-level child only) + any number of Members (any depth) + any number of sub-Folders (organizational, no CLAUDE.md).
- **No nested Suites.** A Suite cannot contain another Suite. Detection: walk up the tree from any directory; if more than one Suite ancestor is encountered, the inner one is malformed (handled per "Edge cases" below).
- **Membership is transitive through Folders.** A Project at any depth inside a Suite (`gene-mini_suite/apps/site/`) is a Member. A Folder inside a Suite (`gene-mini_suite/apps/`) is still a Folder, not a Member.

### Hub location (round 2)
- The Hub MUST be a direct child of the Suite directory (i.e., parent of the Hub IS the Suite).
- A `*_hub`-named directory at non-top-level inside a Suite (e.g., `gene-mini_suite/apps/weird_hub/`) is **NOT** a Hub — it's a Member with that basename.
- Hub-aware scaffolding lookup is therefore unambiguous: `<suite-root>/*_hub`. Single glob, single shell call.

### Multi-Hub case
- A Suite with two or more `*_hub` direct children: classification still treats both as Hubs (each satisfies the Hub rule). Hub-aware scaffolding warns `claudehome: multiple *_hub siblings found in <suite-root>; skipping hub-aware writes` and falls back to writing a plain Member CLAUDE.md (no `@`-import). Carry-over from hub-aware-v1 spec.

### Picker behavior
- Drill rules unchanged from folder-tree-v1: Folders/Suites drill, Projects/Hubs/Members attach.
- Suite drilling shows all immediate children (Hub + Members + Folders + sub-Folders containing Members).
- Sub-folder inside a Suite drills normally; its children are filtered as Members (any with CLAUDE.md) + Folders (any without).
- **No synthetic `(root)` bucket.** Top-level picker shows Folders, Suites, and root-level Projects flat in one screen. (Removes the folder-tree-v1 behavior where root projects were grouped into a synthetic bucket when folders coexisted.)
- `[..  back]` row at row 1 of every non-root drill (unchanged).
- Row ordering at every drill level: `[..  back]` (non-root only) → Folders + Suites alphabetical (interleaved by basename) → Projects/Hubs/Members active-first then idle alphabetical → `[new...]`.

### Picker rendering — type labels
- **Folder:** `<name>/  (N)`
- **Suite:** `<name>_suite/  (N)`
- **Project:** `<name>  [active 5m]` or `<name>  [idle]`
- **Hub:** `<name>_hub  HUB  [active 5m]`
- **Member:** `<name>  member  [idle]`

The `_suite` and `_hub` suffix is part of the basename — no separate badge needed for Suite (the suffix self-labels). `HUB` and `member` badges added before the activity column for Hub and Member only.

### Creation flow — single `[new...]` row (round 3)
- **One creation row at every drill level**, always last in the picker: `[new...]`.
- Selecting it triggers a context-aware type prompt: `Create what? [folder/suite/project]` (or whatever subset applies).
- The valid type list depends on the current drill directory's type:

| Current drill type | Valid creation types |
|---|---|
| (root, treated as Folder) | folder, suite, project |
| Folder (outside any Suite) | folder, project |
| Suite without Hub | folder, member, hub |
| Suite with Hub | folder, member |
| Sub-folder inside Suite | folder, member |

- After type selection, the user is prompted for the new entity's name. Allowlist `[a-zA-Z0-9._-]+`, reject `.`/`..`/leading-dot, reject sibling collisions, globally-unique check for project/member/hub names (basename uniqueness across the entire tree).

### Creation actions (what each type creates)
- **folder** → `mkdir <name>/`. Empty. → Folder.
- **suite** → `mkdir <name>_suite/` (the `_suite` suffix is auto-appended to whatever name the user types — or rejected if user types name already ending in `_suite`? See "Open questions" OQ-2). Empty. → Suite.
- **project** → `mkdir <name>/` + `printf '# %s\n' <name> > <name>/CLAUDE.md`. → Project.
- **hub** → `mkdir <name>_hub/` (auto-suffix decision per OQ-2) + 1-line CLAUDE.md (`# <name>_hub\n`) + template `README.md` + template `projects.md` (header row only). → Hub.
- **member** in Suite-with-Hub → `mkdir <name>/` + `git init` + Member-style CLAUDE.md (`# <name>\n\n@<hub-abs-path>/README.md\n\n<description>`) + row in `<hub>/projects.md`. → Member.
- **member** in Suite-without-Hub → `mkdir <name>/` + plain `# <name>\n` CLAUDE.md (no `@`-import, no projects.md row). → Member.
- **member** in sub-folder inside Suite-with-Hub → same as Suite-with-Hub member, but the `mkdir` happens in the sub-folder (parent path of new Member) and the projects.md row still goes to the Suite-root Hub.

### Description prompt
- Only fires when creation type is `member` AND a Hub exists at the Suite root.
- Prompt text: `One-line description (optional): `.
- Empty input → placeholder `<one-line description goes here>`.
- Single-line only; embedded newlines rejected with retry.
- Pipe character `|` escaped as `\|` in the `projects.md` row only; literal in the `CLAUDE.md` body.

### Single SSH round-trip preserved
- Folder-tree-v1 invariant carries over: one SSH for tree listing, one SSH for create+scaffold+attach.
- The 5-type classification needs only `[ -f <dir>/CLAUDE.md ]` per directory in the tree-walk, plus the existing `find` invocation. The `n_all/n_dirs` glob counting from folder-tree-v1 is REPLACED by the CLAUDE.md probe.

### Mac+PC parity
- Both `bin/claudehome` (bash) and `bin/claudehome.ps1` (pwsh 7+) implement the same 5-type classification, picker rendering, and creation flow. Same wire format with the type field expanded.
- Wire-format change: `path<TAB>type<TAB>child_count` becomes `path<TAB>type<TAB>child_count` where `type ∈ {R, FOL, SUITE, P, HUB, MEM}` (R = synthetic root). Keep single-letter codes for backward compatibility where possible: `R`, `F` → re-use as `Folder`; `P` → re-use as Project. New codes: `S` (Suite), `H` (Hub), `M` (Member).

### Existing 14 flat projects
- All currently classify as Project (have CLAUDE.md, no Suite ancestor) OR Folder (no CLAUDE.md). Quick scan needed before deploy:
  - Projects with CLAUDE.md → Project (unchanged behavior, picker shows `<name>  [active/idle]`)
  - Projects without CLAUDE.md → Folder (drillable). User can `touch CLAUDE.md` to flip back. List of affected projects to be produced as part of implementation.

### Allowlist hygiene
- Carry over from folder-tree-v1: project/folder/member/hub/suite names use `^[a-zA-Z0-9._-]+$` allowlist; reject `.`, `..`, leading-dot. Suffix `_suite` and `_hub` are appended automatically by the creation action (or required to already be present, per OQ-2).
- Description content (Member only): goes through quoted-heredoc on bash, single-quoted with `'` doubled on pwsh. Never positional shell arg.

## Non-Goals

- **Content-based classification.** No parsing of `CLAUDE.md` for `@`-imports or other markers. Classification is purely structural (file presence + suffix + ancestor chain).
- **Nested Suites.** A Suite cannot contain another Suite. Out of scope for v1.
- **Multi-hub support.** A Suite has at most one Hub. Multi-hub scenarios warn and skip scaffolding.
- **Auto-migration of existing projects.** Existing 14 flat projects keep their current state; user manually adjusts (touch/move) if classification changes don't suit them.
- **Picker mv/rename/delete.** Carry-over non-goal from folder-tree-v1.
- **Marker files** (`.hub`, `.suite`, `.claudehome-folder`, etc.). The only "marker" recognized is `CLAUDE.md`, which is Claude's existing convention.
- **Tagging or virtual folders.** Each directory has exactly one type, defined by structure.
- **Hub validation.** No check that `<hub>/README.md` exists, or that `projects.md` has the right header. Hub-author concern, not picker concern.
- **Custom suffixes / configuration.** `_suite` and `_hub` are hardcoded. No `~/.claudehomerc` key for renaming.
- **Subcommands beyond `--help`.** CLI surface stays at `claudehome` / `claudehome --help`.
- **Backward compatibility with the legacy `_pjt` suffix.** The hub-aware-v1 spec used `_pjt`; this spec uses `_suite`. Users with existing `_pjt` directories must rename. (User has none yet, per conversation context.)

## Acceptance Criteria

These extend folder-tree-v1's AC. Mac criteria: **AC-5T1–AC-5T18**. PC criteria: **AC-5T-PC1–AC-5T-PC14**. Local: **AC-5T-LOCAL1–LOCAL2**.

### Mac client (bash) — `bin/claudehome`

- [ ] **AC-5T1** — A directory with no CLAUDE.md and no `_suite` suffix classifies as Folder. Picker shows `<name>/  (N)`. Pick → drill.
- [ ] **AC-5T2** — A directory with no CLAUDE.md and `_suite` suffix classifies as Suite. Picker shows `<name>_suite/  (N)`. Pick → drill.
- [ ] **AC-5T3** — A directory with CLAUDE.md and no Suite ancestor classifies as Project. Picker shows `<name>  [active/idle]`. Pick → tmux attach `claudehome-<basename>`.
- [ ] **AC-5T4** — A directory with CLAUDE.md, parent IS a Suite, basename ends `_hub` classifies as Hub. Picker shows `<name>_hub  HUB  [active/idle]`. Pick → attach.
- [ ] **AC-5T5** — A directory with CLAUDE.md, has a Suite ancestor (transitive), NOT named `_hub` (or named `_hub` but not top-level child of Suite) classifies as Member. Picker shows `<name>  member  [active/idle]`. Pick → attach.
- [ ] **AC-5T6** — A directory at `gene-mini_suite/apps/weird_hub/` with CLAUDE.md classifies as **Member** (not Hub) because parent is `apps/`, not the Suite root. Picker shows `weird_hub  member  [...]`.
- [ ] **AC-5T7** — A nested Suite (`gene-mini_suite/sub_suite/`) is malformed; picker classifies the inner one as Folder (no CLAUDE.md) but emits stderr warning `claudehome: nested Suites not supported; treating <path> as Folder`.
- [ ] **AC-5T8** — `[new...]` row appears as the last picker row at every drill level. Selecting it prompts `Create what?` with a context-aware type list (per the table above).
- [ ] **AC-5T9** — At root, `[new...] → folder` creates `<name>/` empty. Reclassifies as Folder.
- [ ] **AC-5T10** — At root, `[new...] → suite` creates `<name>_suite/` empty (auto-appends `_suite` if user's input didn't end with it). Drilling in shows just `[..  back]` and `[new...]`. The `[new...] → hub` and `[new...] → member` options become available at the suite-root drill level.
- [ ] **AC-5T11** — At root, `[new...] → project` creates `<name>/` + 1-line `CLAUDE.md` (`# <name>\n`). Reclassifies as Project. Tmux attach follows.
- [ ] **AC-5T12** — Inside a Suite without Hub, `[new...] → hub` creates `<name>_hub/` + 1-line CLAUDE.md + template `README.md` + template `projects.md` (header row only). Reclassifies as Hub.
- [ ] **AC-5T13** — Inside a Suite with Hub, `[new...] → member` prompts for description, creates `<name>/` + `git init` + Member CLAUDE.md (with `@`-import to absolute Hub README path) + row appended to `<hub>/projects.md`. Tmux attach follows.
- [ ] **AC-5T14** — Inside a Suite without Hub, `[new...] → member` creates `<name>/` + plain `# <name>\n` CLAUDE.md, no `@`-import, no projects.md row, no `git init`. Tmux attach follows.
- [ ] **AC-5T15** — Inside a sub-folder inside a Suite-with-Hub, `[new...] → member` walks up to find the Suite root's Hub, scaffolds the Member CLAUDE.md with the Hub's absolute path, appends to that Hub's projects.md.
- [ ] **AC-5T16** — Multi-Hub Suite: when `[new...] → member` runs, stderr warns `claudehome: multiple *_hub siblings found in <suite-root>; skipping hub-aware writes`. Member is created with plain `# <name>\n` CLAUDE.md.
- [ ] **AC-5T17** — Globally-unique name check (carry-over from folder-tree-v1) covers Hub and Member names too. A Member named `site` rejects creation if any Project/Hub/Member named `site` exists anywhere in the tree.
- [ ] **AC-5T18** — `shellcheck bin/claudehome install_client.sh install_server.sh` passes with no warnings.

### PC client (pwsh 7+) — `bin/claudehome.ps1`

- [ ] **AC-5T-PC1–PC11** — Mirror AC-5T1 through AC-5T11 from pwsh.
- [ ] **AC-5T-PC12** — `[new...]` selection in pwsh uses `Read-Host` for the type prompt, then the existing name prompt logic.
- [ ] **AC-5T-PC13** — `Invoke-ScriptAnalyzer bin/claudehome.ps1 install_client.ps1` passes with no warnings.
- [ ] **AC-5T-PC14** — Mac↔PC parity: creating a Member from PC produces byte-identical files on the mini as creating it from Mac (same CLAUDE.md content, same projects.md row, same `.git/` structure modulo timestamps).

### Local mode

- [ ] **AC-5T-LOCAL1** — `CLAUDEHOME_LOCAL=1 claudehome` walks the local tree, classifies all 5 types correctly, runs creation actions locally without SSH.
- [ ] **AC-5T-LOCAL2** — From iPhone Termius/Blink SSH'd into the mini, drill-down + creation work identically to local-mode terminal.

## Assumptions Exposed & Resolved

| Assumption | Challenge | Resolution |
|---|---|---|
| 5 types is the right number | Could be 2 (Folder/Project) with role suffixes as documentation | User chose 5 — mental model and disk state align; picker can surface badges |
| Suite contents are flat (Hub + Members only) | Could allow sub-folders for organizing many members | User chose Flexible: Hub + Members + sub-Folders, no nested Suites; membership transitive through sub-folders |
| Hub can be anywhere in a Suite | Could be top-level only, or anywhere with detection walking up | User chose Top-level child only — cleanest detection, unambiguous Hub for scaffolding |
| Multiple `[new ___ here]` rows for each type | Could be a single `[new...]` row with context-aware type prompt | User chose Single context-aware row — cleaner picker, one extra step per creation |
| `_pjt` suffix from hub-aware-v1 | Too cryptic, doesn't convey "shared workspace" | Renamed to `_suite` |
| Empty dir created via `[new project]` would be classified as Project | Heuristic v1 said empty = Project, but our new rule (CLAUDE.md presence) means empty = Folder | Resolved: `[new...] → project` always writes `# <name>\n` CLAUDE.md, so empty dirs are no longer projects (they're Folders by structural classification). Self-consistent. |

## Technical Context

### Files that change
- `bin/claudehome` (bash, 877 lines after folder-tree-v1) — replace heuristic in tree-walk emitter (4 copies); add Suite/Hub/Member type detection in parser; add `[new...]` single-row picker logic with context-aware prompt; add hub-aware scaffolding helpers (`detect_hub`, `prompt_description`, `hub_aware_writes`); update existing `prompt_new_folder`/`prompt_new_project` to dispatch via `[new...]` flow.
- `bin/claudehome.ps1` (pwsh, 567 lines) — symmetric.
- `CLAUDE.md` — update Architecture paragraph + Key docs + Windows verification with new ACs.
- `.omc/specs/deep-interview-claudehome-folder-tree-v1.md` — superseded annotation pointing at this spec.
- `.omc/plans/open-questions.md` — track OQ-1, OQ-2 (below).

### Files that DO NOT change
- `install_client.sh`, `install_client.ps1`, `install_server.sh` — no installer prompts, no env vars.
- `~/.claudehomerc` — no new keys.
- LaunchAgent plist — unaffected.
- Tmux session naming convention — `claudehome-<basename>`. Folder/Suite depth invisible at tmux layer.

### Brownfield code anchors
- Tree-walk emitter (bash): `bin/claudehome:182-217` (local), `:221-252` (remote), `:670-704` (refetch local), `:707-738` (refetch remote). Replace `n_all/n_dirs` block with single `[ -f "$p/CLAUDE.md" ]` test.
- Parser (bash): `bin/claudehome:287-320`. Update type-validity regex to `^[RFSPHM]$` (or whatever single-letter codes chosen) and add Suite-ancestor + suffix logic for Hub/Member detection.
- Picker row build (bash): `bin/claudehome:367-510` (build_rows_for_path). Add Suite/Hub/Member rendering branches; replace creation rows with single `[new...]`.
- Creation flow (bash): `bin/claudehome:559-665` (prompt_new_folder, prompt_new_project). Refactor into single `prompt_new_anything` that dispatches by type per context.
- PowerShell mirrors at corresponding offsets.

## Ontology (Key Entities)

| Entity | Type | Fields | Relationships |
|---|---|---|---|
| Folder | core | name, parent_path | contains 0..n Folders, 0..n Projects |
| Suite | core | name (ends `_suite`), parent_path | contains 0..1 Hub (top-level), 0..n Members (transitive through sub-Folders), 0..n sub-Folders. **Cannot** contain another Suite. |
| Project | core | name, parent_path, has CLAUDE.md, no Suite ancestor | belongs to a Folder (or root) |
| Hub | core | name (ends `_hub`), parent IS Suite, has CLAUDE.md, has README.md, has projects.md | belongs to exactly one Suite (top-level child) |
| Member | core | name, has CLAUDE.md, has Suite ancestor, NOT a Hub | belongs to a Suite (transitively); imports Hub's README via @-import (when scaffolded by `[new...] → member`) |

## Ontology Convergence

| Round | Entity Count | New | Changed | Stable | Stability Ratio |
|---|---|---|---|---|---|
| 1 | 5 | 5 (Folder, Suite, Project, Hub, Member) | — | — | N/A |
| 2 | 5 | 0 | 1 (Hub: top-level constraint added) | 4 | 100% |
| 3 | 5 | 0 | 1 (creation flow consolidated to single `[new...]`) | 4 | 100% |

Domain model converged at round 1; rounds 2-3 refined relationships and creation rules without changing the 5 entities.

## Open Questions

- **OQ-1**: How does the picker render at the Suite-root drill level when both folders and members coexist? Is there a visual separation (e.g., section headers like `── Folders ──` and `── Members ──`)? Or just sort alphabetical with type badges? Defer to first-implementation read; revisit if confusing.
- **OQ-2**: Suite/Hub naming auto-suffix policy. When user types `gene-mini` at `[new...] → suite`, should the action create `gene-mini_suite/` (auto-append) or reject with `name must end in '_suite'`? Auto-append is friendlier; reject is more explicit. Same for hub. Defer; recommend auto-append.

## Interview Transcript

<details>
<summary>Full Q&A (3 rounds)</summary>

### Round 1
**Targeting:** Constraints (0.5)
**Q:** What's allowed inside a Suite? — Strict / Flexible (+ sub-folders) / Permissive / Permissive minus nested Suites
**A:** Flexible: + sub-folders. Members transitive through sub-folders, no nested Suites.
**Ambiguity:** 31.7% (Goal: 0.90, Constraints: 0.65, Criteria: 0.40, Context: 0.70)

### Round 2
**Targeting:** Constraints (0.65)
**Q:** Where can the Hub live? — Top-level only / Anywhere / Anywhere with warn
**A:** Top-level child of Suite only. Deeper `*_hub` dirs are Members.
**Ambiguity:** 23.3% (Goal: 0.92, Constraints: 0.78, Criteria: 0.55, Context: 0.75)

### Round 3
**Targeting:** Constraints (0.78)
**Q:** Creation row layout — Guided minimum / Always full / Guided + advanced / Single context-aware
**A:** Single context-aware `[new...]` row + type prompt. Valid types depend on parent.
**Ambiguity:** 13.3% (Goal: 0.95, Constraints: 0.88, Criteria: 0.78, Context: 0.80) — **threshold met**

</details>
