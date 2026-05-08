# Implementation Plan: claudehome 5-type v1

## Source

Spec: `.omc/specs/deep-interview-claudehome-5type-v1.md` (deep-interview, 13.3% ambiguity, PASSED, 2026-05-08)
Subsumes: `.omc/specs/deep-interview-claudehome-hub-aware-v1.md` (PROPOSED, never shipped — its scaffolding rules are absorbed into the `[new...] → member` action of this plan)
Replaces (heuristic only): `.omc/specs/deep-interview-claudehome-folder-tree-v1.md` (SHIPPED 1.2.0.0 — wire format, drill machine, allowlists, sentinels, truncation logic all carry over; only the binary Folder/Project heuristic is replaced by 5-type structural classification)
Parent plans: `.omc/plans/claudehome-folder-tree-v1-plan.md` (structural template; this plan mirrors that structure section-for-section), `.omc/plans/claudehome-v1-plan.md`, `.omc/plans/claudehome-pc-v1-plan.md`
Date: 2026-05-08
Mode: RALPLAN-DR (SHORT) — brownfield UX/classification extension on top of shipped folder-tree v1; no new env vars, no installer change, no daemons. Deliberate sub-section §3.4 added because hub-aware scaffolding writes user data on disk and warrants a pre-mortem.

---

## 1. RALPLAN-DR Summary

### Principles (non-negotiable)

1. **Single SSH round-trip preserved.** The remote-mode listing must continue to be one `bash --norc --noprofile -c '...'` payload. The 5-type classification adds at most one extra `[ -f $p/CLAUDE.md ]` test per directory inside the existing emitter — no second SSH call. Carry-over from folder-tree-v1 ADR (`.omc/plans/claudehome-folder-tree-v1-plan.md` Principle 1; `bin/claudehome:181-258`).
2. **Mac+PC parity at the wire-format level.** Bash and pwsh parse the *same* tree-walk payload with the *same* type field semantics (`R/F/S/P/H/M`). Same regex, same picker rows, same error text, same scaffolding bytes. Carry-over from folder-tree-v1 Principle 2; spec AC-5T-PC14 (byte-identical files).
3. **No new state, no new env vars, no new installer prompts.** Folder/Suite/Hub/Member layout lives on disk; classification is purely structural (CLAUDE.md presence + suffix + ancestor chain). No `.claudehome/types.json`, no `~/.claudehomerc` keys, no installer flags. Spec "Configuration"; CLAUDE.md "Scope guardrails".
4. **Tmux session naming unchanged.** `claudehome-<basename>` stays, regardless of type or depth. A Member at `gene-mini_suite/apps/site/` still attaches to `claudehome-site`. Spec "Single SSH round-trip preserved"; carry-over from folder-tree-v1.
5. **Allowlist-before-interpolation, unchanged regex set.** `^[a-zA-Z0-9._-]+$` for basenames, `^[a-zA-Z0-9._~/-]+$` for `PROJECTS_DIR`. The `_suite`/`_hub` suffix is appended *after* basename validation. Description content (Member only) goes through quoted-heredoc on bash and single-quote-doubled on pwsh — never positional shell arg. Spec "Allowlist hygiene".

### Decision Drivers (top 3)

1. **Backward compatibility with the shipped folder-tree-v1 wire format and drill machinery.** The 4 emitter copies (bash:182-217, 221-252, 670-704, 707-738; pwsh:97-130, mkdir helper at 445-447), parser (bash:287-320; pwsh:158-234), build_rows (bash:367-510; pwsh:264-364), and attach branch (bash:868-892; pwsh:574-584) must remain structurally intact. Only the n_all/n_dirs glob is replaced; everything else extends.
2. **Single fast classification per row.** `[ -f $p/CLAUDE.md ]` (one stat()) replaces the n_all/n_dirs glob (one open() + N stats). Performance improves on average. The Suite-ancestor check is computed in the parser by walking up the path string (zero filesystem ops).
3. **Mac+PC parity at the byte level.** AC-5T-PC14 demands byte-identical Member CLAUDE.md and projects.md row across clients. This forces the bash and pwsh scaffolding helpers to use the *same* template strings, the *same* placeholder substitution, the *same* pipe-escape only-in-projects.md rule.

### Viable Options (with bounded pros/cons)

#### Option A (CHOSEN): Wire-format extension `R/F/P` → `R/F/S/P/H/M` with structural-only classification

Each row in the existing tree-walk payload carries a single-letter type code drawn from `{R,F,S,P,H,M}`. Classification rules:
- Server-side emitter computes `[ -f "$p/CLAUDE.md" ]` (regular file, not symlink).
- Server-side emitter computes basename suffix presence (`_suite`, `_hub`).
- Client-side parser computes Suite-ancestor by walking the path string (post-classification step).

**Pros:**
- Drop-in extension of the shipped wire format; existing `R`/`F`/`P` codes keep their meaning.
- Single emitter change (replace n_all/n_dirs glob with two probes). Performance neutral or better.
- Suite-ancestor check is O(depth) string scan; depth ≤8, trivial.
- Parser invariant tightens cleanly: `^[RFP]$` → `^[RFSPHM]$`. Six codes, all unique, all mnemonic.
- Hub-aware scaffolding lives in one place: the `[new...] → member` action. No fragmented "is this a hub-aware folder?" detection scattered across the picker.

**Cons:**
- Wire format invariant change requires updating 4 emitter copies (bash local, bash remote, bash refetch local, bash refetch remote) + pwsh `$remoteDataTpl`. Editing 5 near-duplicates is error-prone.
- Parser regex is now 6 codes wide; a fixed set, but `R` is still parser-only (synthetic root, never user-visible) so reviewers may ask "why six?".

#### Option B (REJECTED): Suite/Hub/Member detection happens in the parser only; wire format stays at `R/F/P`

The emitter still emits `R/F/P` (CLAUDE.md present → P; absent → F; root → R). The parser then post-classifies P rows into Project/Hub/Member based on parent suffix + ancestor chain.

**Pros:**
- Wire format unchanged. Single emitter edit (just the n_all/n_dirs → CLAUDE.md probe swap).
- Parser is the single source of classification truth in two languages.

**Cons:**
- Suite (`F` with `_suite` suffix) is not visually distinguishable from a plain Folder until the parser splits them. The picker loses a clean type code, increasing test surface.
- Member badge `member` and Hub badge `HUB` require re-deriving the type at *every* picker render (the parser would need to walk up the path each time, or cache type per row, which is what Option A does explicitly via the type code).
- Wire-format-invariant (`type ∈ {R,F,P}`) becomes weaker — the parser can't reject corrupt rows where `tt=Q` or similar, because the legitimate set is artificially small while the actual semantic set is six.
- Rejected on Driver 1 (the existing parser already reads `tt` — promoting it to 6 codes is cheaper than adding a parallel `derived_type` field).

#### Option C (REJECTED): Two-pass tree walk — emit raw rows, then re-walk to classify

Emitter does a plain `find` first, then a second pass that opens each candidate dir and emits the type. Single SSH still.

**Pros:**
- Cleanest separation: discovery vs. classification.

**Cons:**
- Doubles `find` invocations on the mini. On a 2000-entry tree that's 2× the work for no gain. Driver 2 violation.
- Adds a second sentinel block to the wire format. The single-block invariant (one `---TREE---<rows>---TMUX---` slab) carries over from folder-tree-v1; breaking it for no semantic gain is poor cost/benefit.
- Rejected on Driver 2.

**At least 2 viable options retained:** Options A and B are both implementable; C is rejected on the first principle. **A is chosen** because the type code is the natural place to encode the structural classification, and because tightening the parser regex to `^[RFSPHM]$` strengthens the wire-format invariant rather than weakening it.

---

## 2. ADR

**Decision.** Implement 5-type structural classification by extending the shipped folder-tree-v1 wire format from 3 type codes (`R/F/P`) to 6 codes (`R/F/S/P/H/M`). The server-side emitter computes 4 of the 6 directly via `[ -f $p/CLAUDE.md ]` + basename suffix check (R for root, F for no-CLAUDE.md non-`_suite`, S for no-CLAUDE.md `_suite`-suffixed, P for has-CLAUDE.md no-Suite-ancestor). The client-side parser computes the remaining 2 (H for has-CLAUDE.md `_hub` direct child of Suite, M for has-CLAUDE.md transitive Suite ancestor) by walking up the path string. Hub-aware scaffolding (git init + `@`-import CLAUDE.md + projects.md row) is consolidated into a single `[new...] → member` action and only fires when the Suite root has exactly one `*_hub` direct child. The shipped folder-tree-v1 drill machine, picker fallback, allowlist regex, sentinels, truncation logic, and `[..  back]` row all carry over unchanged.

**Drivers.**
1. Backward compatibility with shipped wire format and drill machinery (D1).
2. Single fast classification per row (D2).
3. Mac+PC parity at the byte level (D3).

**Alternatives considered.**
1. **Option B — wire-format stays at `R/F/P`, parser post-classifies.** Rejected: weakens wire-format invariant, scatters classification across two layers, and requires the parser to re-walk path strings at every render rather than once at parse time.
2. **Option C — two-pass tree walk.** Rejected: doubles `find` cost, breaks single-block sentinel invariant, no semantic gain.
3. **Option D (genuine alternative considered) — separate hub-aware mode opt-in via `~/.claudehomerc`.** Rejected: adds a config knob, contradicts spec "Configuration" ("no new keys"), and the structural classification is deterministic enough that opt-in would just be a way to defer the migration of the 14 existing projects (which we address via the audit table in §7 R8 instead).

**Why chosen.** Option A is the only path that simultaneously satisfies: (a) one SSH round-trip, (b) one stat()-equivalent probe per directory, (c) cheap O(depth) Suite-ancestor lookup, (d) wire-format invariant *strengthens* (`^[RFP]$` → `^[RFSPHM]$` is six codes vs. three but the semantic ambiguity drops to zero), (e) zero installer/env-var/state-file additions, (f) byte-identical scaffolding bytes across Mac and PC. The added complexity is bounded to: (i) replace n_all/n_dirs glob with CLAUDE.md probe + suffix check in 4 emitter copies + 1 pwsh template, (ii) extend parser regex and add Suite-ancestor walk, (iii) replace `[new folder here]`/`[new project here]` rows with a single `[new...]` row + context-aware type prompt, (iv) add `prompt_description`, `detect_hub`, `hub_aware_writes` helpers in both languages.

**Consequences.**
- *Positive:* Classification is one stat() per directory + O(depth) string walk per row. On a 2000-entry tree at average depth 3 that's 2000 stats + ~6000 string scans = under 100ms total (see §7 R-PERF). Hub detection at scaffolding time is one shell glob (`<suite-root>/*_hub`). Picker rendering is unchanged in cost. Mac+PC byte-identical scaffolding is ensured by both clients calling the *same* bash payload over SSH for the writes (PC always SSHes; Mac in remote mode SSHes; Mac in local mode runs the same bash code locally).
- *Negative:* Migration surprise — 10 of the existing 14 flat projects do not have CLAUDE.md and will flip from Project to Folder on upgrade. See §7 R8 + §3.2 audit table + §4.3 CLAUDE.md recovery snippet. User-facing recovery is one shell command.
- *Negative:* The Multi-Hub case (a Suite with two or more `*_hub` direct children) is locked at "warn + skip hub-aware writes" with no deterministic primary picker. Critic is expected to challenge this; we hold the line because (a) the spec explicitly says so ("Multi-Hub case", line 79-80), (b) v1 explicitly defers multi-hub support ("Non-Goals" line 151), and (c) any deterministic primary picker (alphabetical first, oldest mtime, etc.) would be a hidden behavior that the user cannot opt out of without renaming directories. Warn-and-skip preserves user agency.
- *Negative:* The `R` code stays as a parser-only artifact (the synthetic `.` row). It's never user-visible. Reviewers may ask "why six codes?" — the answer is "five user-facing types plus the synthetic root, which is a parser convenience for the empty-PROJECTS_DIR case (see folder-tree-v1-plan §8.2 P12)".

**Follow-ups (deferred).**
- Multi-Hub deterministic primary picker (Spec Non-Goal; v1 warns and skips).
- Nested Suites support (Spec Non-Goal).
- Per-Suite uniqueness (Spec carries over folder-tree-v1's globally-unique constraint).
- Picker `mv` / `rename` / `delete` (Spec Non-Goal).
- Auto-migration of legacy flat projects (Spec Non-Goal; user runs one-line recovery command — see §4.3).
- A `claudehome doctor` subcommand that lints Suite/Hub/Member structure (Out of Scope per CLI surface guardrail).

---

## 3. Architecture

### 3.1 Wire format — 6 type codes

**One block, sentinel-delimited, carry-over from folder-tree-v1.** The leading sentinel `---TREE---` and the trailing sentinel `---TMUX---` separate the tree-walk output from the existing tmux block. The tmux block format is unchanged (`session_name session_activity`, space-separated, one per line). Truncation sentinels `---TRUNCATED---` (>2000 entries) and `---DEPTH-TRUNCATED---` (>8 deep) carry over.

**Row format unchanged:** `path<TAB>type<TAB>child_count\n`. Only the `type` field's domain expands.

**Type codes (six, all unique, all single-character):**

| Code | Name | Where assigned | Computed from |
|---|---|---|---|
| `R` | Synthetic Root | Server (the `.` row only) | `rel == "."` |
| `F` | Folder | Server | `! [ -f $p/CLAUDE.md ]` AND `basename(p)` does NOT end with `_suite` |
| `S` | Suite | Server | `! [ -f $p/CLAUDE.md ]` AND `basename(p)` ends with `_suite` |
| `P` | Project | Server | `[ -f $p/CLAUDE.md ]` AND no Suite ancestor (server-side approximation: row's full path contains no `*_suite/` segment) |
| `H` | Hub | Client (parser post-classification) | `[ -f $p/CLAUDE.md ]` AND parent is a Suite (parent's basename ends `_suite`) AND `basename(p)` ends `_hub` |
| `M` | Member | Client (parser post-classification) | `[ -f $p/CLAUDE.md ]` AND has a Suite ancestor (transitive) AND not a Hub |

**Why server emits P/H/M as P, then parser splits H and M out:** the server-side emitter is inside `bash --norc --noprofile -c '...'` and runs once per row in a `find ... | while read` pipe. Each row only has access to its own path string and its own `CLAUDE.md` probe — it does *not* know whether an ancestor is a Suite without re-walking up the tree (extra `find` cost). The parser already iterates all rows once and has every path in memory; it is the natural place to do the ancestor walk.

**Concretely:** the server emits `P` for any has-CLAUDE.md directory. The parser receives the rows, then for each `P` row it checks: does any segment of `path.split('/')` (excluding the last) end with `_suite`? If yes → Member candidate. If yes AND the parent's basename ends with `_hub` AND the parent's parent ends with `_suite` (i.e., parent IS a Suite) → Hub. Otherwise → Project.

**Wire-format invariant (tightened from folder-tree-v1).** Parser drops rows where:
- `tt` ∉ `{R, F, S, P, H, M}` (regex `^[RFSPHM]$`), OR
- `tp` ≠ `.` AND `tp` does not match `^([a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$` (carry-over).

The H and M codes are *internal* to the parser (the server never emits them directly), but the regex allows them so that hand-crafted test fixtures can inject `H`/`M` rows for unit-style verification (see §8 fixture-diff). In production the server only emits `R/F/S/P`; the parser materializes H/M from P rows.

**Sample wire output** (mini at `~/projects/claudehome-projects` after the user creates one Suite with one Hub and two Members):

```
---TREE---
.	R	5
claudehome	P	1
gene-mini_suite	S	3
gene-mini_suite/gene-mini_hub	P	2
gene-mini_suite/site	P	1
gene-mini_suite/api	P	1
gene-wezterm	P	1
test_folder1	F	0
---TMUX---
claudehome-claudehome 1715000000
```

After parser post-classification:

```
.                                       R
claudehome                              P (has CLAUDE.md, no _suite ancestor)
gene-mini_suite                         S (no CLAUDE.md, _suite suffix)
gene-mini_suite/gene-mini_hub           H (has CLAUDE.md, parent is Suite, basename _hub)
gene-mini_suite/site                    M (has CLAUDE.md, _suite ancestor, not _hub)
gene-mini_suite/api                     M (same)
gene-wezterm                            P
test_folder1                            F (no CLAUDE.md, no _suite suffix)
```

### 3.2 Classification rules — concrete spec with edge cases

**Server-side decision (inside `bash --norc --noprofile -c`):**

```
if [ "$rel" = "." ]; then
  t=R
elif [ -f "$p/CLAUDE.md" ]; then
  t=P
else
  case "$(basename "$p")" in
    *_suite) t=S ;;
    *)       t=F ;;
  esac
fi
```

**Critical**: `[ -f ... ]` requires the path to exist AND be a regular file (not a directory, not a symlink to a directory, not a broken symlink). This matches spec "Allowlist hygiene" (symlinks are not followed) and avoids classifying a `CLAUDE.md/` directory or a dangling `CLAUDE.md` symlink as "has CLAUDE.md".

**Client-side post-classification (in the parser, after rows are loaded):**

For each row of type `P`:
1. Split `path` on `/` → segments.
2. Walk segments[0..len-2] (every ancestor, not the row itself). If any segment ends with `_suite`, set `has_suite_ancestor=true` and remember the *first* such segment (closest-to-root, i.e., the Suite root).
3. If `has_suite_ancestor=false` → leave as `P`.
4. If `has_suite_ancestor=true`:
   - If parent's basename ends with `_suite` AND row's basename ends with `_hub` → `H`.
   - Else → `M`.

**Edge case enumeration:**

| Case | Type | Rationale | AC |
|---|---|---|---|
| `~/projects/.../foo/` no CLAUDE.md, basename `foo` | F | No CLAUDE.md, no `_suite` suffix → Folder. | AC-5T1 |
| `~/projects/.../bar_suite/` no CLAUDE.md | S | No CLAUDE.md, `_suite` suffix → Suite. | AC-5T2 |
| `~/projects/.../baz/` has CLAUDE.md, no Suite ancestor | P | Project. | AC-5T3 |
| `~/projects/.../bar_suite/foo_hub/` has CLAUDE.md, parent is Suite, `_hub` suffix | H | Hub. | AC-5T4 |
| `~/projects/.../bar_suite/site/` has CLAUDE.md, has Suite ancestor, no `_hub` | M | Member. | AC-5T5 |
| `~/projects/.../bar_suite/apps/weird_hub/` has CLAUDE.md, has Suite ancestor, basename `_hub` BUT parent is `apps/` not the Suite | M | "Hub" must be top-level child of Suite (parent IS the Suite). At deeper depth, the `_hub` suffix is treated as a literal name part → Member. | AC-5T6 |
| `~/projects/.../bar_suite/sub_suite/` no CLAUDE.md | F + stderr warning | Nested Suites unsupported. Server emits S (suffix-based), parser detects Suite ancestor, demotes to F, prints `claudehome: nested Suites not supported; treating <path> as Folder`. | AC-5T7 |
| `~/projects/.../bar_suite/foo_hub/` (Suite has TWO `*_hub` direct children) | H + H | Each row classifies independently. Multi-Hub *picker* still shows both as Hub. Hub-aware scaffolding sees two siblings and warns. See §3.4. | AC-5T16 |
| `~/projects/.../foo/` is a symlink to a real Suite directory elsewhere | omitted from walk | `find -type d` without `-L` does not match symlinks-to-dirs. Spec "Allowlist hygiene". | (no AC; carry-over from folder-tree-v1 §3.2) |
| `~/projects/.../foo/CLAUDE.md/` is itself a directory | F or S | `[ -f ]` fails on a directory. Treated as if no CLAUDE.md. Edge case; not explicitly tested. | (carry-over) |
| `~/projects/.../foo/CLAUDE.md` is a symlink to a regular file | F or S | `[ -f ]` does not follow symlinks (BSD behavior is to return false unless `-L` is set globally). Treated as no CLAUDE.md. Spec "Allowlist hygiene" + "Single SSH round-trip preserved". | (defensive; carry-over) |
| Empty `PROJECTS_DIR` | only `.` row → R | Picker shows just `[new...]`. Carry-over from folder-tree-v1 §8.2 P12. | (carry-over) |

**Suite-ancestor walk inside the bash `find ... \| while read` pipe.** The bash emitter cannot easily compute Suite-ancestor server-side because each iteration of the pipe sees one path at a time, not the whole tree. Two options were considered:
1. **Server emits H/M directly by walking up `$p` for each row.** Each row would do `parent="$p"; while [ "$parent" != "." ]; do basename=$(basename "$parent"); case "$basename" in *_suite) ...; esac; parent=$(dirname "$parent"); done`. This works but adds a O(depth) loop *per row* on the mini, in a subshell, inside an SSH payload. Reasonable but bash-heavy.
2. **Server emits `P` for all has-CLAUDE.md rows; client parser splits H/M from P.** O(depth) string split in bash/pwsh in-memory. Faster, simpler, single source of truth for the ancestor logic.

**Chosen: option 2** (parser-side post-classification). The `Suite-ancestor` check is bash-native string-only: split on `/`, scan segments. Same logic in pwsh. This puts the ancestor logic in *one* place per language rather than splitting it between server and client.

**Existing 14 flat projects audit (mini state at 2026-05-08):**

```
Has CLAUDE.md (4) — will classify as Project (unchanged):
  claude_adventure
  claudehome
  gene-wezterm
  srl-claude-plugins

Missing CLAUDE.md (10) — will FLIP to Folder on upgrade:
  daily-report
  fuel-in-seoul
  fuel_seoul
  gene-mini-project
  instagram-logger
  invest-my-life
  marriage-doc
  smoking-plan
  test1
  test_folder1
```

These 10 directories will appear as drillable Folders after the upgrade (with empty content if they have no children, or with their children as a sub-tree if they have any). The user can recover any of them to Project status by `touch <dir>/CLAUDE.md`. See §4.3 for the global recovery command.

### 3.3 Picker flow with single `[new...]` row

**Picker rows (consolidated):**

The shipped folder-tree-v1 builds picker rows in this order at every drill level:
1. `[..  back]` (non-root only)
2. Folders alphabetical
3. Projects active-then-idle
4. `(root)` bucket (root only, conditional)
5. `[new folder here]`
6. `[new project here]`

The 5-type spec **drops the `(root)` bucket** ("No synthetic `(root)` bucket" — line 86) and **collapses the two creation rows into one `[new...]`** (line 99). New row order:

1. `[..  back]` (non-root only)
2. Folders + Suites alphabetical, **interleaved by basename** (the `_suite` suffix sorts naturally — e.g., `apps/`, `gene-mini_suite/`, `personal/`, `work/`)
3. Projects + Hubs + Members active-then-idle, alphabetical within each activity tier (Hub and Member badges visible; type does not affect ordering)
4. `[new...]` (always last)

**OQ-1 resolution (Suite-root drill rendering).** The plan adopts the explicit ordering "alphabetical-interleaved-folders+suites then active-then-idle for projects/hubs/members". Confirmed in §6 AC mapping (AC-5T1 through AC-5T6).

**Type label rendering (per spec "Picker rendering — type labels"):**

| Type | Display | Note |
|---|---|---|
| Folder | `<name>/  (N)` | Trailing slash + child count, carry-over from folder-tree-v1. |
| Suite | `<name>_suite/  (N)` | The `_suite` suffix is part of the basename — no separate badge. |
| Project | `<name>  [active 5m]` or `<name>  [idle]` | Carry-over. |
| Hub | `<name>_hub  HUB  [active 5m]` | The `_hub` suffix is part of the basename + a `HUB` badge before the activity column. |
| Member | `<name>  member  [idle]` | A `member` badge before the activity column. |

**`[new...]` selection flow:**

When the user picks `[new...]`, claudehome reads the current drill directory's type and presents a context-aware type prompt:

```
Current drill type            → Valid creation types       → Disambiguation step
──────────────────────────────────────────────────────────────────────────────────
R (root)                      → folder, suite, project     → none (always at depth 0)
F + walk_to_suite_root empty  → folder, project            → call walk_to_suite_root first
  (plain Folder, NOT in Suite)
F + walk_to_suite_root non-   → folder, member             → call walk_to_suite_root first;
  empty (sub-folder INSIDE                                    Hub for scaffolding = result of
  a Suite — AC-5T15 case)                                     detect_hub <suite_root>
S + detect_hub returns 0      → folder, member, hub        → call detect_hub <parent_path>
  (Suite without Hub)
S + detect_hub returns ≥1     → folder, member             → call detect_hub <parent_path>
  (Suite with Hub already)
P / H / M                     → (cannot drill into)        → defensive die; picker never
                                                             offers `[new...]` from inside
                                                             a Project/Hub/Member
```

**Why F-type drill needs `walk_to_suite_root` upfront (P5):** the picker drilling state machine sees an F row and dispatches to `prompt_new_anything <path> "F"` — but F is structurally ambiguous (plain Folder vs. sub-Folder inside a Suite). Computing the Suite-ancestor at dispatch-time, ONCE, lets the type-prompt offer the right options AND lets the eventual `[new...] → member` action find its Hub without re-walking.

Implementation: a single shell function `prompt_new_anything <parent_path> <parent_type>` that:
1. Computes valid types from `parent_type` per the table above (P5 PATCHED — explicit `walk_to_suite_root` dispatch):
   - `parent_type == "R"` (root): valid types = `folder, suite, project`. Skip `walk_to_suite_root`.
   - `parent_type == "S"` (Suite root, drilled directly into a `*_suite/`): call `detect_hub <parent_path>` to compute `HUB_COUNT`. If 0 → `folder, member, hub`. If ≥1 → `folder, member` (Hub already exists; spec disallows multiple Hubs at same Suite root). Skip `walk_to_suite_root` (we are already AT a Suite root).
   - `parent_type == "F"` (Folder, ambiguous — could be plain Folder OR sub-Folder inside a Suite): **call `walk_to_suite_root <parent_path>` first** and switch on the result:
     - If `walk_to_suite_root` returns NON-EMPTY (caller is inside a Suite, depth ≥ 2): valid types = `folder, member`. The Hub for scaffolding purposes is found by `detect_hub <suite_root>` (using the result from the walk-up, NOT `parent_path`). This is the AC-5T15 sub-folder case.
     - If `walk_to_suite_root` returns EMPTY (plain Folder, NOT inside any Suite): valid types = `folder, project`.
   - `parent_type == "P"` / `H` / `M`: should never happen — the picker only drills into R/F/S, not P/H/M. Defensive `die "internal error: cannot drill into Project/Hub/Member"`.
2. Prompts: `Create what? [folder/suite/project]` (substring matches accepted, e.g., `f`/`s`/`p`/`h`/`m`).
3. Re-prompts until the user enters a valid choice or empty/Ctrl-D (which cancels and returns to the picker).
4. After type chosen, prompts `New <type> name: ` (unchanged from folder-tree-v1 prompt logic).
5. Validates name against `^[a-zA-Z0-9._-]+$` (carry-over from folder-tree-v1).
6. **Auto-suffix policy (OQ-2 RESOLVED; P2 patched).** For type `suite`/`hub`:
   - If user's input does NOT contain `_suite` (or `_hub`) anywhere — neither as a suffix nor as an interior substring: auto-append the suffix (`gene-mini` → `gene-mini_suite`).
   - If user's input contains `_suite` (or `_hub`) anywhere — as a trailing suffix (`gene-mini_suite`) **OR** as an interior substring (`gene-mini_suite_v2`): **reject** with stderr `"claudehome: name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended."` and re-prompt. This avoids both double-suffixed `gene-mini_suite_suite` AND triple-or-misleading `gene-mini_suite_v2_suite`.
   - **Bash check (both branches):**
     ```bash
     case "$name" in
       *_suite|*_suite_*) warn "name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended."; continue ;;
     esac
     # …same case for *_hub|*_hub_* under the hub branch.
     ```
     The shell glob `*_suite_*` matches `_suite` as an interior substring (`foo_suite_bar`). The pattern `*_suite` matches it as a trailing suffix. Together they cover both rejection cases. The bare auto-append branch (no `_suite` at all anywhere in `$name`) falls through to `name="${name}_suite"` and proceeds.
   - **Pwsh check (mirror):**
     ```powershell
     if ($name -match '_suite') { Write-WarnStderr "name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended."; continue }
     # …same -match '_hub' under the hub branch.
     ```
     The pwsh `-match` with the bare token `'_suite'` matches the substring anywhere in `$name`, mirroring the bash glob behavior. Same rejection wording.
   - **Both implementations LOCKED to the same wording** (per AC-5T-PC14 byte-identical-bytes principle for stderr text). New AC entries: AC-5T19 (suite substring rejection) and AC-5T20 (hub substring rejection mirror) — see §6.
7. Sibling-collision check (any type at same parent) — carry-over.
8. Globally-unique check for `project`/`member`/`hub` (any P/H/M-type row anywhere in the tree with the same basename — extends folder-tree-v1's check).
9. Dispatch to type-specific creation action (see §3.4).

### 3.4 Hub-aware scaffolding inside `[new...] → member`

**When triggered:** user picks `[new...] → member` AND drill context is inside a Suite (Suite root OR sub-folder inside a Suite).

**Hub detection (single shell glob):**

```bash
# At the Suite root, after the user names their new Member:
hub_count=0
hub_path=
for h in "${SUITE_ROOT}"/*_hub; do
  [ -d "$h" ] && [ -f "$h/CLAUDE.md" ] && {
    hub_count=$(( hub_count + 1 ))
    hub_path="$h"
  }
done
```

The check requires both `[ -d "$h" ]` (it's a real directory) AND `[ -f "$h/CLAUDE.md" ]` (it has CLAUDE.md, i.e., it's actually a Hub by spec definition; a hypothetical empty `*_hub` directory without CLAUDE.md would classify as Suite content but not as a Hub for scaffolding purposes).

**Decision tree:**

| `hub_count` | Action |
|---|---|
| 0 | Suite without Hub. Member is created with plain `# <name>\n` CLAUDE.md. No git init. No projects.md row. |
| 1 | Suite with Hub. Full hub-aware scaffolding runs (4 steps below). |
| ≥2 | Multi-Hub. Stderr warning `claudehome: multiple *_hub siblings found in <suite-root>; skipping hub-aware writes`. Falls back to the no-hub case (plain `# <name>\n` CLAUDE.md). |

**Multi-Hub resolution — LOCKED.** No deterministic primary picker. We do NOT pick alphabetical-first or oldest-mtime. Rationale: any deterministic rule would be a hidden behavior the user cannot opt out of without renaming directories. Warn-and-skip preserves agency. Critic is expected to challenge this; we hold the line per spec line 79-80 + Non-Goals line 151.

**The four hub-aware writes (single `hub_count=1` case):**

1. **`mkdir -p <member-path>`** — already done by the generic creation step.
2. **`git init <member-path>` (output suppressed; warn-and-continue on failure).** The new Member is meant to be a git repo per the masterplan-workspace pattern; `git init` is idempotent (no-op if already initialized).
3. **Write `<member-path>/CLAUDE.md`** with quoted-heredoc:
   ```
   # <name>

   @<hub-abs-path>/README.md

   <description>
   ```
   - `<hub-abs-path>` is the absolute path to the Hub (e.g., `/Users/genehan/projects/claudehome-projects/gene-mini_suite/gene-mini_hub`). Computed at write time, not hardcoded.
   - `<description>` is the result of `prompt_description` (see below). Empty input → placeholder `<one-line description goes here>`.
4. **Append a row to `<hub-abs-path>/projects.md`**:
   ```
   | <name> | <description-pipe-escaped> | active | — | — |
   ```
   - Pipe character `|` is escaped as `\|` ONLY in this projects.md row (preserves table integrity).
   - In the CLAUDE.md body, pipe stays literal.
   - If projects.md is missing or zero bytes: stderr warning `claudehome: <hub-abs-path>/projects.md missing or empty; row not appended` and skip ONLY this step. Steps 2 and 3 still ran. Carry-over from hub-aware-v1 spec.

**Description prompt (`prompt_description`):**

- Fires only when `[new...] → member` AND `hub_count == 1`. Does NOT fire for projects, hubs, suites, folders, or the no-Hub member case, or the Multi-Hub member case.
- Prompt text: `One-line description (optional): `.
- Empty input → placeholder `<one-line description goes here>` (carry-over from hub-aware-v1).
- Single-line only. Embedded `\n` rejected with retry: `claudehome: description must be single-line`.
- The description value is shell-quoted: bash uses `<<'EOF'` heredoc with quoted delimiter; pwsh uses single-quoted with embedded `'` doubled to `''`. Never positional shell arg.

**Hub-aware sub-folder case (AC-5T15).** When the user is inside `gene-mini_suite/apps/` (a sub-folder inside a Suite-with-Hub) and picks `[new...] → member`, the new Member is created at `apps/<name>/` BUT the Hub for scaffolding purposes is found by walking UP from the current drill path to the Suite root, then doing the `*_hub` glob there. The projects.md row goes to that Suite-root Hub. The description prompt fires. The CLAUDE.md `@`-import points to the Suite-root Hub's README.md.

**Implementation: a `walk_to_suite_root` helper in both languages.** Given a drill path like `gene-mini_suite/apps/foo`, walk up segments until finding one ending in `_suite`. Return its full path. Used inside `prompt_new_anything` to locate the Hub.

**Pre-mortem (3 scenarios, deliberate-mode requirement):**

1. **Failure: `git init` fails on the mini due to no `git` on PATH.** Likelihood: low (mini has Xcode CLT); impact: Member is created with CLAUDE.md and projects.md row, but no `.git/` directory. Mitigation: warn `claudehome: git init failed for <member-path>; .git/ not initialized` and continue. The user can run `git init` manually later. This is the spec's "warn-and-continue" stance.
2. **Failure: projects.md is missing entirely (Hub author hasn't created it yet).** Likelihood: medium (a fresh Hub created via `[new...] → hub` writes a projects.md template, but a hand-curated Hub may not). Impact: row append silently skipped if we're not careful. Mitigation: stderr `claudehome: <hub-abs-path>/projects.md missing or empty; row not appended`. CLAUDE.md write and git init still run. AC-5T-spec implicit; tested.
3. **Failure: race condition — two clients call `[new...] → member` at the same Suite at the same time, each picks the same name, the second one's mkdir succeeds but the first one's projects.md row is overwritten.** Likelihood: very low (multi-client concurrent writes are not a scenario for a personal-tool); impact: one row missing in projects.md. Mitigation: append uses `>>` (atomic-ish on most filesystems for writes < PIPE_BUF = 4KB), and the row is small (~80 chars). On NFS or weird filesystems this could race, but the mini is APFS local. Accepted risk; v1.1 could add `flock` if reported.

**Expanded test plan (deliberate-mode requirement):**

- **Unit:** §8.2 wire-format check tests the 6-code emitter. §8.3 verifies the parser's H/M post-classification logic.
- **Integration:** §8.4 creation flow tests every type from every drill context (matrix from §3.3 valid-creation table).
- **End-to-end:** §8.5 verifies the four hub-aware writes happen in order and produce byte-identical bytes to a hand-crafted reference. §8.6 verifies multi-Hub warn+skip.
- **Observability:** stderr warnings are pinned to literal strings and asserted in §8.7. Every warning has a verification command.

---

## 4. File-by-file Changes

### 4.1 `bin/claudehome` (bash) — current 881 lines, expected ~1100 lines (+220)

| Lines (current) | Change | Rationale |
|----------------|--------|-----------|
| **L8–45** (USAGE here-doc) | **Update**: replace the "Folders organize..." paragraph with "5-type structure: Folders organize, Suites group masterplan workspaces (`*_suite`), Projects/Hubs/Members are attachable. The last picker row is `[new...]` — pick a type and a name. Suite-with-Hub Members get hub-aware scaffolding (git init + `@`-import + projects.md row)." Stay under 35 lines. | Help reflects new behavior. AC-5T-spec implicit. |
| **L182–217** (local emitter) | **Replace** the `n_all/n_dirs` glob block with a `[ -f $p/CLAUDE.md ]` test + basename suffix check. New classification: R for `.`, P for has-CLAUDE.md, S for no-CLAUDE.md `*_suite`, F otherwise. Keep the `find ... \| while IFS= read -r -d ''` pattern (BSD-portable, handles 2000-cap counter). | Server-side classification per §3.2. |
| **L221–252** (remote emitter) | **Replace** the same glob block, escaped for the SSH `bash --norc --noprofile -c '...'` outer-double-quoted string. Every `$` reaching remote bash escaped as `\$`; every `"` escaped as `\"`. | Mirror local, remote-mode escape rules. |
| **L287–320** (parser) | **Extend**: regex `^[RFP]$` → `^[RFSPHM]$`. After loading rows, run a post-classification pass: for each row of type `P`, walk the path segments up; if any segment ends `_suite`, change type to M; if additionally the immediate parent ends `_suite` AND the row's basename ends `_hub`, change to H. Detect nested-Suite case (a row of type S whose ancestor chain contains a `_suite` segment): demote to F and emit one stderr warning per offending path. | Client-side post-classification per §3.2 + AC-5T7. |
| **L367–510** (build_rows_for_path) | **Replace `[new folder here]` and `[new project here]` rows with a single `[new...]` row.** Remove `(root)` bucket logic entirely (spec line 86). Add Suite/Hub/Member rendering branches: Suite renders as `<name>_suite/  (N)` (treated as Folder for ordering — interleaved alphabetically with Folders by basename; spec line 88). Hub renders as `<name>_hub  HUB  [active/idle]`; Member renders as `<name>  member  [active/idle]`. Sort key for type 2 group is now a single ordering of Folders+Suites by basename (no special bucket); type 3 group is Projects+Hubs+Members by activity then alphabetical. | AC-5T1 through AC-5T8 ordering. |
| **L559–665** (prompt_new_folder + prompt_new_project) | **Refactor into single `prompt_new_anything <parent_path> <parent_type>`** that: (a) computes valid types from `parent_type` per §3.3 table (with a side-glob `<suite-root>/*_hub` for the Suite-with-vs-without-Hub split), (b) prompts `Create what? [...]`, (c) prompts `New <type> name:`, (d) validates allowlist + applies auto-suffix per §3.3 OQ-2 rule, (e) sibling-collision check, (f) global-unique scan extended to cover P+H+M types (the `${TREE_TYPE[i]}` filter becomes `[[ "$t" == "P" \|\| "$t" == "H" \|\| "$t" == "M" ]]`). On success, dispatches to a per-type creation action. | AC-5T8 through AC-5T17. |
| **(new helpers, ~150 lines)** | **Add** functions: `walk_to_suite_root <drill_path>` (returns the closest-to-root `_suite`-suffixed segment's full path, or empty if none); `detect_hub <suite_root>` (sets globals `HUB_COUNT` + `HUB_PATH`; runs `for h in "$suite_root"/*_hub; do ... done` with `[ -d ]` AND `[ -f $h/CLAUDE.md ]` check); `prompt_description` (sets global `DESC` from stdin, defaults to placeholder, rejects newlines); `escape_pipe <description>` (sets global `DESC_ESCAPED` with `\|` substitution); `create_folder <path>`, `create_suite <path>`, `create_project <path>`, `create_hub <path> <suite_root>`, `create_member <path> <suite_root> <hub_path_or_empty>`. The `create_member` function is the meat: it does `mkdir -p`, conditionally does `git init >/dev/null 2>&1 \|\| warn`, writes CLAUDE.md via `cat >.. <<'CLAUDEMD_EOF'` (heredoc-quoted to forbid expansion of dollar-variables in the description), and conditionally appends to `<hub>/projects.md` after a `[ -s "$hub/projects.md" ]` check. | Per §3.4 hub-aware scaffolding. |
| **L868–877** (attach branch) | **No change.** Already supports `ATTACH_PATH+PROJECT` (folder-tree-v1 ADR — folder-depth invisible at tmux). The 5-type spec preserves this: a Member at `gene-mini_suite/apps/site/` attaches to `claudehome-site` regardless of depth. Just verify the `mkdir -p` step is still idempotent (yes — line 884, 889). | Tmux session naming carry-over (spec line 134-136). |
| **L674–786** (refetch_tree, both local + remote) | **Replace** the two `n_all/n_dirs` blocks with the new CLAUDE.md-probe + suffix-check classification. Identical changes to the two emitters above. The parser regex extension at L770 also applies. | Refetch must use the same wire format. |

**Critical bash-isms to preserve (carry-over from folder-tree-v1):**

- `set -euo pipefail` is in effect on `bin/claudehome:5`. Picker frames signal via globals `PICKER_RESULT`/`PICKER_PROJECT`/`PICKER_PARENT`, NOT via non-zero return codes. The new `prompt_new_anything` function returns success via `PROMPT_OK=1` global (carry-over from folder-tree-v1 §3.3 P3).
- **`warn()` helper (P1, NEW).** Under `set -euo pipefail`, every helper call must return 0 explicitly so it cannot trip `set -e`. Define near the top of `bin/claudehome` (alongside the existing `die()` helper) so all subsequent helpers — `create_member`, `create_hub`, `detect_hub`, `prompt_description`, the nested-Suite demotion loop, and the projects.md-missing branch — can call `warn`:
  ```bash
  warn() { echo "claudehome: $*" >&2; }   # always returns 0; safe under set -e
  ```
  All `git init >/dev/null 2>&1 || warn "git init failed for $member_path; .git/ not initialized"`-style calls in §4.1 and §3.4 depend on this helper being defined. Without it, `git init`'s non-zero exit would propagate `set -e` and abort the picker mid-creation, leaving partial on-disk state.
- BWK awk on macOS does NOT honor `-v RS='\0' -v ORS='\0' 'NR<=2000'`. The shipped code uses a bash counter inside `while read -r -d ''` loop (already at bash:194, 230, 680, 716). **Preserve this pattern unchanged**; the CLAUDE.md probe goes inside the same loop body.
- BSD `find` rejects `-not -L` and `-not -path`. Use `!` operator (`! -path '*/.*'`) for portability. Already in shipped code; preserve.
- `[ -f $p/CLAUDE.md ]` requires regular-file semantics — does NOT follow symlinks (BSD default) — matches spec "Allowlist hygiene" (symlinks not followed).
- Wire-format invariant enforced post-parse: drop rows where `tt` ∉ `{R,F,S,P,H,M}` (regex `^[RFSPHM]$`) OR `tp` ∉ allowlist regex.

**Sample server-side emitter** (replaces L182-217 local; L221-252 remote is the same code with SSH escape conventions; L674-738 are the refetch copies):

```bash
# Inside the find ... | while IFS= read -r -d '' p; do ... done loop:
i=$(( i + 1 ))
[ "$i" -gt 2000 ] && break
rel="${p#./}"
[ "$p" = "." ] && rel="."
n_all=0
for c in "$p"/* "$p"/.[!.]* "$p"/..?* ; do
  [ -e "$c" ] || continue
  n_all=$(( n_all + 1 ))
done
if [ "$rel" = "." ]; then
  t=R
elif [ -f "$p/CLAUDE.md" ]; then
  t=P
else
  case "${p##*/}" in
    *_suite) t=S ;;
    *)       t=F ;;
  esac
fi
printf '%s\t%s\t%s\n' "$rel" "$t" "$n_all"
```

The `n_all` count is preserved from folder-tree-v1 because the picker still annotates Folders and Suites with `(N)`. The classification logic replaces only the `n_all == n_dirs` heuristic (which was `[ "$n_all" -gt 0 ] && [ "$n_all" = "$n_dirs" ]`).

**Sample parser post-classification** (after the L320 main parse loop):

```bash
# Walk every row of type P; promote to M or H if Suite ancestor exists.
for (( i=0; i<${#TREE_PATH[@]}; i++ )); do
  [[ "${TREE_TYPE[$i]}" != "P" ]] && continue
  local path="${TREE_PATH[$i]}"
  local has_suite_ancestor=0
  local suite_root=""
  # Walk segments[0..len-2] (parent and above).
  IFS='/' read -ra segs <<< "$path"
  local n_segs=${#segs[@]}
  for (( j=0; j<n_segs-1; j++ )); do
    if [[ "${segs[$j]}" == *_suite ]]; then
      has_suite_ancestor=1
      [[ -z "$suite_root" ]] && suite_root="${segs[$j]}"
      # Build full suite_root path:
      local k acc=""
      for (( k=0; k<=j; k++ )); do
        acc="${acc:+$acc/}${segs[$k]}"
      done
      suite_root="$acc"
      break
    fi
  done
  if (( has_suite_ancestor )); then
    # Hub: parent is a Suite AND basename ends _hub.
    local parent="${TREE_PARENT[$i]}"
    local parent_basename="${parent##*/}"
    local row_basename="${segs[$n_segs-1]}"
    if [[ "$parent_basename" == *_suite && "$row_basename" == *_hub ]]; then
      TREE_TYPE[$i]=H
    else
      TREE_TYPE[$i]=M
    fi
  fi
done

# Demote nested Suites: a row of type S whose ancestor chain contains _suite
# is malformed; treat as Folder + warn once.
for (( i=0; i<${#TREE_PATH[@]}; i++ )); do
  [[ "${TREE_TYPE[$i]}" != "S" ]] && continue
  local path="${TREE_PATH[$i]}"
  IFS='/' read -ra segs <<< "$path"
  local n_segs=${#segs[@]}
  for (( j=0; j<n_segs-1; j++ )); do
    if [[ "${segs[$j]}" == *_suite ]]; then
      TREE_TYPE[$i]=F
      echo "claudehome: nested Suites not supported; treating $path as Folder" >&2
      break
    fi
  done
done
```

### 4.2 `bin/claudehome.ps1` (pwsh) — current 585 lines, expected ~770 lines (+185)

| Lines (current) | Change | Rationale |
|----------------|--------|-----------|
| **L17–48** (help here-string) | **Update** USAGE text parity with bash. Single line additions about Suite/Hub/Member and the `[new...]` row. | AC-5T-PC1 + parity. |
| **L97–130** (`$remoteDataTpl`) | **Replace** the n_all/n_dirs block with the same CLAUDE.md probe + suffix check (byte-identical bash inside the SSH payload). The PS template wrapper stays — only the bash payload's classification block changes. | AC-5T-PC1 + wire-format parity. |
| **L158–234** (`Read-Tree`) | **Extend** the regex check at L200 from `^[RFP]$` to `^[RFSPHM]$`. Add a post-parse pass that walks each row of type `P` and promotes to H/M based on Suite-ancestor walk. Add nested-Suite detection (S with Suite ancestor → F + stderr). Mirror bash exactly. | AC-5T-PC1 through AC-5T-PC11 parity. |
| **L264–364** (`Get-RowList`) | **Remove the `(root)` bucket synthesis logic.** **Replace `[new folder here]` and `[new project here]` rows with a single `[new...]`.** Add Suite/Hub/Member render lines. Sort key: Folders+Suites by basename (interleaved); Projects+Hubs+Members by activity then basename. | AC-5T-PC1 + spec lines 86, 88, 99. |
| **L413–501** (`New-Folder` + `New-Project`) | **Refactor into `New-Anything { param([string]$ParentPath, [string]$ParentType) }`** that prompts type, name, applies auto-suffix per OQ-2, dispatches to per-type creators. | AC-5T-PC8 + AC-5T-PC11 + AC-5T-PC12. |
| **(new helpers, ~120 lines)** | **Add** `Walk-ToSuiteRoot`, `Detect-Hub`, `Prompt-Description`, `Escape-Pipe`, `Create-Folder`, `Create-Suite`, `Create-Project`, `Create-Hub`, `Create-Member`. Each `Create-*` builds a single SSH bash payload via `$tpl.Replace(...)` (template substitution) and runs `& ssh.exe ...` once. The `Create-Member` function is the byte-identical sibling of bash's `create_member` — same heredoc, same template, same pipe-escape rule. AC-5T-PC14 explicitly requires byte-identical bytes on the mini regardless of which client wrote them. | Per §3.4. |
| **L574–584** (attach branch) | **No change.** Already accepts `$attachPath + $project`. Tmux session naming unchanged. | Spec line 134-136. |

**Critical pwsh-isms to preserve (carry-over from folder-tree-v1):**

- `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'` at L5-6. New helpers must use `Set-Item Env:` and `Get-Item -ErrorAction SilentlyContinue` patterns to avoid strict-mode violations on undefined keys.
- **`Write-WarnStderr` helper (P1, NEW; pwsh equivalent of bash `warn`).** Under `$ErrorActionPreference = 'Stop'`, native errors halt the script. The pwsh client already uses `[Console]::Error.WriteLine(...)` directly for stderr. The plan formalizes this as a one-line helper so the New-* / Detect-Hub / Prompt-Description code-paths share the exact wording used by bash. Define alongside the existing pwsh helpers:
  ```powershell
  function Write-WarnStderr([string]$Message) { [Console]::Error.WriteLine("claudehome: $Message") }
  ```
  Use everywhere bash uses `warn`: failed `git init` (via `Start-Process -PassThru` exit-code check), missing/empty projects.md, multi-Hub fallback, nested-Suite demotion. AC-5T-PC14 byte-identical-bytes is unaffected (warnings go to stderr, not to user files).
- `$PSNativeCommandArgumentPassing = 'Standard'` at L7 ensures consistent arg-passing on pwsh 7.0–7.6.
- UTF-8 console encoding at L13-15 — preserved.
- TAB-split: use `-split "`t"` (backtick-t inside double quotes — PowerShell's TAB escape sequence). Avoid `-split '\t'` (regex form, locale-dependent).
- Heredoc-equivalent: PowerShell single-quoted here-string (`@'...'@`) for the bash payload templates; placeholder substitution via `.Replace('__PROJECTS_DIR__', $ProjectsDir)`.

### 4.3 `CLAUDE.md`

| Section | Change |
|---|---|
| "Architecture (one paragraph)" | **Append** one sentence after the existing folder-tree paragraph: "5-type classification (v1.3.0+): each directory under `CLAUDEHOME_PROJECTS_DIR` is exactly one of Folder (no CLAUDE.md), Suite (`*_suite`, no CLAUDE.md), Project (CLAUDE.md, no Suite ancestor), Hub (`*_hub`, CLAUDE.md, top-level child of a Suite), or Member (CLAUDE.md, has Suite ancestor). The picker drills into Folders/Suites and attaches Projects/Hubs/Members. The single `[new...]` row prompts for a type then a name. Inside a Suite-with-Hub, `[new...] → member` triggers hub-aware scaffolding (git init + `@`-import CLAUDE.md + projects.md row)." |
| "Development" → line counts | **Update** `(bash, ~310 lines)` → `(bash, ~1100 lines)` and `(pwsh 7+, ~228 lines)` → `(pwsh 7+, ~770 lines)`. Numbers approximate; final commit reconciles. |
| "Scope guardrails" | **No new guardrails.** All existing ones (no state files, no daemons, no new env vars, no subcommands) carry over. |
| "Windows PC — post-install verification" | **Append** AC-5T-PC1 through AC-5T-PC14 to the existing AC-PC1–PC9 + AC-FT-PC1–PC10 checklist. One line per AC, one-sentence repro. |
| "Key docs" | **Add** two lines: `.omc/specs/deep-interview-claudehome-5type-v1.md` and `.omc/plans/claudehome-5type-v1-plan.md`. Mark folder-tree-v1 and hub-aware-v1 specs as "superseded by 5type-v1" in a parenthetical. |
| **NEW section: "Migrating legacy flat projects to 5-type (v1.3.0+)"** | **Add** ~12 lines explaining: 10 of the 14 existing projects do not have CLAUDE.md and will flip to Folder on upgrade. Recovery is one shell command. **Recommended command (global glob — chosen for convenience):** `for d in ~/projects/claudehome-projects/*/; do [ -d "$d" ] && [ ! -f "$d/CLAUDE.md" ] && touch "$d/CLAUDE.md" && echo "touched $(basename "$d")/CLAUDE.md"; done`. This walks every direct child of the projects root, skips those that already have CLAUDE.md, and creates an empty CLAUDE.md in the rest. Empty CLAUDE.md is sufficient for classification (the file's *content* doesn't matter — only its *presence*). Alternative: literally enumerate the 10 dirs (`for d in daily-report fuel-in-seoul fuel_seoul gene-mini-project instagram-logger invest-my-life marriage-doc smoking-plan test1 test_folder1; do touch ~/projects/claudehome-projects/$d/CLAUDE.md; done`). The global form is recommended because it is idempotent (re-run anytime) and self-discovers any future legacy dirs the user creates outside the picker. **Legacy `_pjt` suffix note (P6 NEW):** the never-shipped `hub-aware-v1` spec experimented with a `_pjt` suffix (e.g., `gene-mini_pjt/`). The 5-type model does NOT recognize `_pjt` — only `_suite` and `_hub` carry semantic weight. Any pre-existing `*_pjt/` directories on the mini classify as plain Folders (no special handling, no warning). If you have any, rename them: `for d in ~/projects/claudehome-projects/*_pjt; do [ -d "$d" ] && mv "$d" "${d%_pjt}_suite"; done`. The plan does NOT auto-detect or warn about `_pjt`; we accept this as an explicit non-goal because hub-aware-v1 was never released and any `_pjt` directories on disk are by definition manually created during exploration. |

**Why the global glob over the explicit enumeration:**
- *Idempotent:* `[ ! -f "$d/CLAUDE.md" ]` makes re-running safe.
- *Future-proof:* if a user adds another flat dir later via raw `mkdir`, the same command catches it.
- *Discoverable:* the `echo` line tells the user exactly which dirs were touched, so they can verify the audit.
- *No copy-paste error risk:* the explicit list is 10 entries long and a typo silently skips a dir.

### 4.4 Untouched files (explicit)

- `install_client.sh` — no installer prompt, no new env var, no new dotfile. Spec "Files that DO NOT change" line 218-222.
- `install_client.ps1` — same.
- `install_server.sh` — local-mode tree-walk uses the same `bin/claudehome` code path; LaunchAgent plist unaffected.
- `~/.claudehomerc` format — no new keys.
- `bin/claudehome.cmd` shim — unchanged.
- `LaunchAgents/com.${USER}.tmux-server.plist` — unchanged.
- `README.md` — optional one-line update mentioning Suites/Hubs/Members; not blocking.
- All `.omc/specs/*.md` other than the 3 named in §Source — unchanged.
- All other `.omc/plans/*.md` — unchanged. The folder-tree-v1 plan stays as the historical record of the 1.2.0.0 release.

---

## 5. Implementation Phases

### Phase ordering decision (P8 PATCHED)

**Why CLAUDE.md updates ship WITH Phase 1+2, not in a separate Phase 4 last:** the 71% legacy-project-flip surprise (R8, now High/High) means users see broken UX the instant they upgrade if the migration documentation hasn't already landed. Two viable orderings were considered:

- **Original (REJECTED):** Phase 1+2 code → Phase 3 PC parity → Phase 4 CLAUDE.md docs last. Users upgrade, drill into a "Folder" expecting tmux-attach, get an empty drill view, scratch their head, eventually find the CLAUDE.md note IF they read the repo carefully. Bad ordering — the recovery command lands AFTER the user is already confused.
- **Chosen (P8):** Phase 1+2 code AND CLAUDE.md "Migrating legacy flat projects" section ship in the SAME PR. Users see the migration warning + one-line recovery command BEFORE they upgrade (the docs commit lands first by convention; even if they upgrade in a single `git pull`, they have the recovery snippet ready in the same diff). This costs nothing in PR scope (the CLAUDE.md edit is ~12 lines per §4.3) and eliminates the "what just happened to my projects?" gap.

Phase 3 (PC parity) and the remaining CLAUDE.md updates (Architecture paragraph, line counts, Key docs) can land in subsequent PRs. The CRITICAL section to ship in PR-1 is just the "Migrating legacy flat projects" recovery snippet.

### Phase 1 — Wire format + classification (bash only) + CLAUDE.md migration note

**Deliverable:** `bin/claudehome` emits and parses the new `R/F/S/P/H/M` payload. The picker still uses the current row builder (`[new folder here]` and `[new project here]` and `(root)` bucket logic intact). This phase proves the wire format end-to-end without touching the picker UX. **Plus (P8):** CLAUDE.md gains the "Migrating legacy flat projects to 5-type (v1.3.0+)" section with the one-line recovery command — landed in the same PR as the wire-format change so users see the warning as soon as they `git pull`.

**Acceptance subset:** AC-5T18 (shellcheck), partial AC-5T1–AC-5T7 (classification correct; picker still renders folder-tree-v1 style).

**Verification:**
- `shellcheck bin/claudehome install_client.sh install_server.sh` → 0 warnings.
- Wire-format fixture diff (§8.2): emit a payload from a hand-crafted tree (Folder + Suite + Project + Suite-with-Hub + Member) and confirm the rows match expected types.
- Existing 14 projects still display (4 as Project, 10 as Folder).

**Ship together with Phase 2** (the `[..  back]` row and old picker stay intact during this phase, but the Suite/Hub/Member badges aren't rendered yet — confusing to ship interim).

### Phase 2 — Picker rendering + `[new...]` row + classification badges (bash)

**Deliverable:** `bin/claudehome` renders Suite/Hub/Member badges, drops the `(root)` bucket, replaces the two creation rows with a single `[new...]` row. The new row triggers `prompt_new_anything` with the context-aware type prompt. Hub-aware scaffolding (git init + CLAUDE.md + projects.md) wired up. All Mac AC-5T1–AC-5T18 satisfied.

**Acceptance subset:** AC-5T1 through AC-5T18.

**Verification:** see §8.

**Ships in same PR as Phase 1.**

### Phase 3 — PC parity

**Deliverable:** `bin/claudehome.ps1` matches Phase 1+2 behavior. Same wire-format parsing, same picker rows, same drill state machine, same hub-aware scaffolding bytes (AC-5T-PC14 byte-identical).

**Acceptance subset:** AC-5T-PC1 through AC-5T-PC14.

**Verification:**
- `Invoke-ScriptAnalyzer bin/claudehome.ps1, install_client.ps1` → 0 warnings (AC-5T-PC13).
- Manual: from PC, drill into a Suite-with-Hub and create a Member; diff the resulting CLAUDE.md and projects.md row against a Mac-created reference (AC-5T-PC14).

**Independently deployable on top of shipped Phase 1+2.**

### Phase 4 — Remaining CLAUDE.md updates + migration smoke verification

**Deliverable:** The CRITICAL "Migrating legacy flat projects" section already shipped with Phase 1+2 (P8). Phase 4 lands the remaining CLAUDE.md updates: new Architecture paragraph, updated bash/pwsh line counts, "Key docs" entries for the 5-type spec + plan, and the "Windows PC — post-install verification" AC checklist append for AC-5T-PC1 through PC14. README.md optionally updated. **The actual recovery command is run by the user** (we do NOT run it as part of the upgrade — that would violate the "no installer changes" guardrail and the "stay-flat" migration principle).

**Acceptance subset:** AC-5T-LOCAL1, AC-5T-LOCAL2 (verify the user's mini works after running the recovery command).

**Verification:**
- User runs the global-glob recovery command. Re-runs `claudehome`. Confirms all 14 projects show as Project (not Folder).
- Iphone Termius parity: SSH into mini, run `claudehome`, drill works.

**Independently deployable.**

---

## 6. AC Mapping Table — 36 ACs

**Breakdown (P4 patched):** Mac client (bash) = **20** (AC-5T1 through AC-5T20; iter-1's 18 + new AC-5T19 + AC-5T20 from P2). PC client (pwsh) = **14** (AC-5T-PC1 through AC-5T-PC14; iter-1 lumped 11 into a single row, now expanded into 11 individual rows + the 3 PC-specific ACs PC12/PC13/PC14 = 14 total). Local mode = **2** (AC-5T-LOCAL1, AC-5T-LOCAL2). **Total: 20 + 14 + 2 = 36.**

Each AC maps to: phase, file:lines (anticipated, post-implementation), and verification method.

### Mac client (bash)

| AC | Phase | Implementation site | Verification |
|----|-------|---------------------|--------------|
| **AC-5T1** | 1+2 | `bin/claudehome:182-217` (emitter), `:287-320` (parser), `:367-510` (build_rows) | Manual: create `~/projects/claudehome-projects/foo/` with no CLAUDE.md, no `_suite` suffix. Run `claudehome`. Picker shows `foo/  (0)`. Pick → drill into empty folder. |
| **AC-5T2** | 1+2 | Same as AC-5T1 | Manual: `mkdir bar_suite`. Picker shows `bar_suite/  (0)`. Pick → drill. Inside: `[..  back]`, `[new...]` only. |
| **AC-5T3** | 1+2 | `bin/claudehome:182-217`, `:367-510` | Manual: existing project with CLAUDE.md (e.g., `claudehome`). Picker shows `claudehome  [active <ts>]` or `[idle]`. Pick → tmux attach `claudehome-claudehome`. |
| **AC-5T4** | 1+2 | `bin/claudehome:287-320` (post-classification: Hub) | Manual: create `bar_suite/foo_hub/CLAUDE.md`. Picker shows `bar_suite/  (1)`. Drill in. Picker shows `foo_hub  HUB  [idle]`. Pick → attach. |
| **AC-5T5** | 1+2 | Same as AC-5T4 | Manual: create `bar_suite/site/CLAUDE.md`. Drill into `bar_suite/`. Picker shows `site  member  [idle]`. Pick → attach `claudehome-site`. |
| **AC-5T6** | 1+2 | Parser: parent-suffix check | Manual: create `bar_suite/apps/weird_hub/CLAUDE.md`. Drill into `bar_suite/`, then `apps/`. Picker shows `weird_hub  member  [idle]` (NOT `HUB`). |
| **AC-5T7** | 1+2 | Parser: nested-Suite demotion | Manual: create `bar_suite/inner_suite/`. Run `claudehome 2>warn.log`. `warn.log` contains `claudehome: nested Suites not supported; treating bar_suite/inner_suite as Folder`. Picker shows `inner_suite/  (0)` inside `bar_suite/`. |
| **AC-5T8** | 2 | `bin/claudehome:367-510` (single `[new...]` row), `:559-665` (`prompt_new_anything`) | Manual: at root, picker last row is `[new...]`. Pick → prompt `Create what? [folder/suite/project]`. Type `folder` → name prompt → success. |
| **AC-5T9** | 2 | `prompt_new_anything` + `create_folder` | Manual: at root, `[new...] → folder → testfolder`. Verify `~/projects/claudehome-projects/testfolder/` exists, no CLAUDE.md. Re-render: `testfolder/  (0)`. |
| **AC-5T10** | 2 | `create_suite` (auto-suffix) | Manual: at root, `[new...] → suite → gene-mini`. Verify `~/projects/.../gene-mini_suite/` exists. Drill in → only `[..  back]`, `[new...]`. Pick `[new...]` → prompt offers `folder/member/hub` (no `project`, no `suite`). |
| **AC-5T11** | 2 | `create_project` | Manual: at root, `[new...] → project → newproj`. Verify `~/projects/.../newproj/CLAUDE.md` exists with `# newproj\n`. Tmux attach to `claudehome-newproj`. |
| **AC-5T12** | 2 | `create_hub` | Manual: inside `bar_suite/` (no Hub yet), `[new...] → hub → gene-mini`. Verify `bar_suite/gene-mini_hub/CLAUDE.md` (`# gene-mini_hub\n`), `bar_suite/gene-mini_hub/README.md` (template), `bar_suite/gene-mini_hub/projects.md` (header row only). |
| **AC-5T13** | 2 | `create_member` (full hub-aware) | Manual: inside `bar_suite/` (with `gene-mini_hub` already), `[new...] → member`. Description prompt fires. Type `my new project`. Verify: (a) `bar_suite/site/.git/` exists, (b) `bar_suite/site/CLAUDE.md` contains `# site\n\n@<abs>/bar_suite/gene-mini_hub/README.md\n\nmy new project\n`, (c) `bar_suite/gene-mini_hub/projects.md` last line is `\| site \| my new project \| active \| — \| — \|`, (d) tmux attach to `claudehome-site`. |
| **AC-5T14** | 2 | `create_member` (no-Hub branch) | Manual: inside `empty_suite/` (no Hub), `[new...] → member`. Description prompt does NOT fire. Verify: (a) no `.git/`, (b) `empty_suite/site/CLAUDE.md` is `# site\n` only, no `@`-import, (c) no projects.md anywhere is touched, (d) tmux attach. |
| **AC-5T15** | 2 | `walk_to_suite_root` + `detect_hub` | Manual: inside `bar_suite/apps/` (sub-folder, Suite-with-Hub), `[new...] → member → site`. Description prompt fires. Verify CLAUDE.md `@`-import points to the Suite-root Hub's README abs path; projects.md row in `bar_suite/gene-mini_hub/projects.md`; tmux attach. |
| **AC-5T16** | 2 | `detect_hub` (multi-Hub branch) | Manual: create `bar_suite/foo_hub/CLAUDE.md` AND `bar_suite/baz_hub/CLAUDE.md`. Inside `bar_suite/`, `[new...] → member → site`. Description prompt does NOT fire. Stderr contains `claudehome: multiple *_hub siblings found in <abs>/bar_suite; skipping hub-aware writes`. Verify: (a) no `.git/`, (b) plain `# site\n` CLAUDE.md, (c) no projects.md row. |
| **AC-5T17** | 2 | `prompt_new_anything` global-unique scan | Manual: existing Project `site` somewhere in tree. Try `[new...] → hub → site` inside a Suite. Stderr: `  'site_hub' already exists at <path>. Pick a different name.` Re-prompt. (Or: try `[new...] → member → claudehome` — collides with existing `claudehome` project at root.) |
| **AC-5T18** | 1+2 | All bash files | Automated: `shellcheck bin/claudehome install_client.sh install_server.sh` → 0 warnings. |
| **AC-5T19** (P2 NEW) | 2 | `prompt_new_anything` suite branch (bash glob `case "$name" in *_suite\|*_suite_*)`) | Manual: at root, `[new...] → suite → "gene-mini_suite_v2"`. Stderr: `claudehome: name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended.` Re-prompt; no creation. Verifies BOTH suffix-form (`gene-mini_suite`) AND interior-substring form (`gene-mini_suite_v2`) are rejected — the iter-1 plan would have only caught the suffix form, silently producing `gene-mini_suite_v2_suite` for the substring case. |
| **AC-5T20** (P2 NEW) | 2 | `prompt_new_anything` hub branch (mirror of AC-5T19) | Manual: inside a Suite without an existing Hub, `[new...] → hub → "gene-mini_hub_v2"`. Stderr: `claudehome: name '_hub' substring not allowed; type just the prefix and the suffix is auto-appended.` Re-prompt; no creation. Verifies the same suffix + interior-substring rejection rule applies symmetrically to `_hub`. |

### PC client (pwsh)

| AC | Phase | Implementation site | Verification |
|----|-------|---------------------|--------------|
| **AC-5T-PC1** | 3 | `bin/claudehome.ps1:97-130` (`$remoteDataTpl`), `:158-234` (`Read-Tree`), `:264-364` (`Get-RowList`) | Manual: PC mirror of AC-5T1 — `mkdir foo` (no CLAUDE.md, no `_suite` suffix). Picker shows `foo/  (0)`. |
| **AC-5T-PC2** | 3 | Same as PC1 | Manual: PC mirror of AC-5T2 — `mkdir bar_suite`. Picker shows `bar_suite/  (0)`. Drill in → `[..  back]`, `[new...]` only. |
| **AC-5T-PC3** | 3 | `:97-130`, `:264-364` | Manual: PC mirror of AC-5T3 — existing project with CLAUDE.md. Picker shows project row + tmux-attach succeeds. |
| **AC-5T-PC4** | 3 | `:158-234` (parser post-classification: Hub) | Manual: PC mirror of AC-5T4 — `bar_suite/foo_hub/CLAUDE.md`. Picker shows `foo_hub  HUB  [idle]`. |
| **AC-5T-PC5** | 3 | Same as PC4 | Manual: PC mirror of AC-5T5 — `bar_suite/site/CLAUDE.md`. Picker shows `site  member  [idle]`. |
| **AC-5T-PC6** | 3 | Parser parent-suffix check | Manual: PC mirror of AC-5T6 — `bar_suite/apps/weird_hub/CLAUDE.md` shows `weird_hub  member  [idle]` (NOT `HUB`). |
| **AC-5T-PC7** | 3 | Parser nested-Suite demotion + `Write-WarnStderr` | Manual: PC mirror of AC-5T7 — `bar_suite/inner_suite/`. Stderr (PC console error stream): `claudehome: nested Suites not supported; treating bar_suite/inner_suite as Folder`. Picker shows `inner_suite/  (0)`. |
| **AC-5T-PC8** | 3 | `:264-364` (single `[new...]` row), `New-Anything` | Manual: PC mirror of AC-5T8 — `[new...]` is the last picker row; pick prompts type then name. |
| **AC-5T-PC9** | 3 | `New-Anything` + `Create-Folder` | Manual: PC mirror of AC-5T9 — create folder via `[new...] → folder → testfolder`. |
| **AC-5T-PC10** | 3 | `Create-Suite` (auto-suffix, mirror of bash with `-match '_suite'`) | Manual: PC mirror of AC-5T10 — `[new...] → suite → gene-mini` produces `gene-mini_suite/`. Drill-in offers `folder/member/hub` (no `project`, no `suite`). |
| **AC-5T-PC11** | 3 | `Create-Project` | Manual: PC mirror of AC-5T11 — `[new...] → project → newproj`. Verify `newproj/CLAUDE.md` byte-identical to Mac's output (single line `# newproj\n`). |
| **AC-5T-PC12** | 3 | `New-Anything` uses `Read-Host` for type + name + description prompts | Manual: from PC, run `[new...]` flow; observe `Read-Host` prompts. Without fzf on PATH, the picker falls back to numbered menu (carry-over from folder-tree-v1). |
| **AC-5T-PC13** | 3 | All pwsh files | Automated: `Invoke-ScriptAnalyzer bin/claudehome.ps1 install_client.ps1` → 0 warnings. |
| **AC-5T-PC14** | 3 | `Create-Member` (byte-identical to bash) | Automated: from Mac, create Member `M1` in Suite `S1` with description `desc1`; from PC, create Member `M2` in Suite `S2` with description `desc2`. SSH to mini and `diff` the two CLAUDE.md files (modulo the name interpolation) and the two projects.md row formats. Expect: byte-identical templates. **AC-5T-PC14 also covers cross-client validation of the AC-5T19/AC-5T20 substring rejection: any rejection wording emitted by pwsh `New-Anything` MUST be byte-identical to the bash `prompt_new_anything` stderr — one source of truth, validated by manual `diff` of stderr captures.** |

### Local mode

| AC | Phase | Implementation site | Verification |
|----|-------|---------------------|--------------|
| **AC-5T-LOCAL1** | 1+2 | `bin/claudehome` local-mode branches (L182-217 emitter, L884 attach) | Manual on the mini: `CLAUDEHOME_LOCAL=1 claudehome`. Walks local tree, classifies all 5 types, runs creation actions locally. |
| **AC-5T-LOCAL2** | 1+2 | Same as LOCAL1 | Manual from iPhone Termius/Blink SSH'd into mini: drill-down + creation works identically. |

**Testability summary:** all 36 ACs (20 Mac bash + 14 PC pwsh + 2 LOCAL) map to a concrete manual repro or automated command. AC-5T-PC1 through PC11 are mechanical mirrors of AC-5T1 through 11 — same fixture setup, same observable, now expanded into 11 individual rows for auditability. AC-5T19/20 (P2 NEW) are bash-side auto-suffix substring tests; their pwsh-side equivalent is rolled into AC-5T-PC14's byte-identical-stderr requirement (single source of truth for stderr wording across clients). AC-5T18 + AC-5T-PC13 are headless-automated; the rest are manual repro.

---

## 7. Risks & Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| **R1 (carry-over)** | Tree-walk emits >2000 rows on a malformed/oversized projects dir | Low | Medium | Hard cap at 2000 via bash counter (already shipped at bash:194, 230, 680, 716). `---TRUNCATED---` sentinel + stderr warning carry over. Cap unchanged for 5-type. |
| **R-PERF** | Stat() per directory adds latency on large trees; parser-side ancestor walk adds bash string comparisons | Low | Low | Quantified (P7 PATCHED with realistic numbers): server-side `[ -f $p/CLAUDE.md ]` is 2000 dirs × ~50µs/stat() on APFS = 100ms total. Well under 200ms perceptible. The shipped n_all/n_dirs glob did *more* work (open + N stats per dir) than the new single probe. Net server-side: performance neutral or *better*. **Client-side parser ancestor walk:** worst case is 2000 P-rows × depth 8 = 16K bash string comparisons. Each `[[ "${segs[$j]}" == *_suite ]]` glob in bash 3.2 takes ~30µs (measured: bash 3.2.57 on Apple Silicon, average over 100K iterations). Worst case: 16K × 30µs ≈ **500ms** — perceptible but bounded, and only if every project has CLAUDE.md AND tree is at max depth. **Typical case:** average user has depth ≤ 3 and ~20 projects → 6K × 30µs ≈ **180ms**, well under perceptibility threshold for picker rendering (humans don't notice latency below 200ms for click-to-render flows). The 50-500ms band is acceptable for v1; if telemetry ever shows the parser walk dominating, v1.1 can move H/M synthesis server-side (see OQ-4). |
| **R2 (carry-over)** | bash `select` and pwsh `Read-Host` unusable at depth 8 with many siblings | Low | Medium | fzf recommended; numbered menu always works. No code mitigation. Carry-over from folder-tree-v1 R2. |
| **R3 (Multi-Hub user surprise)** | User creates a second `*_hub` directory by mistake; Members under that Suite stop getting hub-aware scaffolding silently | Medium | Medium | Stderr warning is loud (`claudehome: multiple *_hub siblings found in <suite-root>; skipping hub-aware writes`). User sees it on every `[new...] → member` until they remove the duplicate. Fallback creates a plain Member CLAUDE.md so the new project still works. We do NOT pick a deterministic primary — that would hide the bug. v1.1 may add a `claudehome doctor` check (deferred). |
| **R4 (carry-over)** | TOCTOU between fetch and create — two clients race on the same name | Low | Medium | Carry-over from folder-tree-v1 R4: `mkdir -p` is idempotent, but tmux session naming collides on basename. v1 accepts the risk. |
| **R5 (5 emitter copies edit error)** | The bash emitter logic is duplicated in 4 copies (local, remote, refetch local, refetch remote) plus the pwsh `$remoteDataTpl`. A bug fix in one and not the others creates wire-format drift. | High | High | **Fixture-diff verification** (§8.7): after Phase 1 implementation, capture the rendered SSH command via `set -x`, save to `tests/fixtures/remote-payload.expected.sh`. Any future edit re-renders and `diff`s. Carry-over from folder-tree-v1 R5 + P11. **Additionally:** add a Phase 1 manual checklist that runs all 4 bash emitter paths (initial local, initial remote, refetch local after `[new...] → folder`, refetch remote after `[new...] → folder`) and confirms they produce identical row counts on a stable tree. |
| **R6 (parser regex break)** | Parser regex `^[RFP]$` → `^[RFSPHM]$`. A typo (`^[RFSPHL]$`, `^[RFSPHM]+$`, etc.) silently drops legitimate rows. | Medium | High | §8.3 wire-format-invariant verification: emit a hand-crafted row of each type code (R, F, S, P, H, M) and confirm all 6 survive parsing. Then emit a row of code `Q` (invalid) and confirm it is dropped + counter incremented + stderr warning printed. Make the test header-of-test-suite (Phase 1 Day 1). |
| **R7 (CLAUDE.md is a directory)** | A user who mistakenly does `mkdir foo/CLAUDE.md` (treating CLAUDE.md as a folder) creates a directory named CLAUDE.md inside `foo/`. The `[ -f "$p/CLAUDE.md" ]` test correctly fails. The directory then classifies as Folder, but the user expected Project. | Very low | Low | `[ -f ]` is regular-file-only (BSD default). The CLAUDE.md "Migrating legacy flat projects" section documents this: "if your `<dir>/CLAUDE.md` is itself a directory, classification falls back to Folder. Run `rmdir <dir>/CLAUDE.md && touch <dir>/CLAUDE.md` to fix." Edge case; not in AC. |
| **R8 (10 legacy flat projects flip to Folder)** | 10 of 14 existing projects have no CLAUDE.md and will appear as Folders after upgrade. Drilling into them shows their actual contents instead of attaching tmux. **Surprise migration breakage hits 71% of existing user projects (10/14).** | High | **High (P7 PATCHED — was Medium)** | The likelihood is High AND the impact is High because the user's primary picker UX changes for 71% of their tracked projects on the upgrade boundary — that's not a "Medium" by any reasonable rubric. Mitigation remains the one-line recovery, but the upgrade ordering matters (see P8 below). (a) Document in §3.2 audit table. (b) CLAUDE.md "Migrating legacy flat projects" section provides one-line recovery: `for d in ~/projects/claudehome-projects/*/; do [ -d "$d" ] && [ ! -f "$d/CLAUDE.md" ] && touch "$d/CLAUDE.md"; done`. (c) The recovery is *idempotent* and *future-proof*. (d) §10 Handoff Notes explicitly lists "user runs recovery command" as a manual step before deploying the upgrade. (e) **P8 mitigation: ship CLAUDE.md "Migrating legacy flat projects" section in the SAME PR as Phase 1+2 code** — users reading the repo see the recovery command BEFORE they upgrade and hit the broken UX. (f) The 10 dirs are personal/test/scratch projects (judged by names like `test1`, `smoking-plan`, `marriage-doc`) — losing tmux attach for them temporarily is low absolute pain, but the % of users affected (effectively 100% of single-user-personal-tool, since gene is the only user) makes this High-impact in expectation. |
| **R9 (description prompt blocks the picker)** | User picks `[new...] → member` in a Suite-with-Hub. Description prompt blocks for input. User Ctrl-C's; what happens to the in-flight `mkdir`? | Medium | Low | Order of operations: (a) name prompt → (b) description prompt → (c) creation actions. Ctrl-C BEFORE step (c) leaves no on-disk state. Ctrl-C DURING step (c) is unrecoverable but partial state (`mkdir` ran but git init didn't) is the same as folder-tree-v1's create-then-attach race. Document: prompt sequence completes BEFORE any disk write. **Mitigation:** structure `prompt_new_anything` as `read_inputs() && do_creation()` two-phase. `read_inputs()` collects name + (conditionally) description into globals; only after both succeed does the function call the type-specific creator. |
| **R10 (auto-suffix collision — both suffix AND interior substring)** | User types `gene-mini_suite` at the suite prompt → auto-append would produce `gene-mini_suite_suite` (double-suffix). User types `gene-mini_suite_v2` → auto-append would produce `gene-mini_suite_v2_suite` (substring buried in the middle). Both are bugs. | Medium | Low | OQ-2 RESOLVED + **P2 PATCHED**: reject ANY input containing `_suite` (or `_hub`) as a trailing suffix OR as an interior substring. Bash glob `case "$name" in *_suite\|*_suite_*) warn "name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended.";; esac` catches both cases in one check. Pwsh mirror via `-match '_suite'` (substring-anywhere). Re-prompt. Documented in §3.3 step 6. AC-5T10 covers happy-path auto-append; AC-5T19 covers `_suite` substring rejection (both suffix and interior); AC-5T20 covers `_hub` substring rejection. Tested in §8.9. |

All risks have a concrete mitigation; none rely on "be careful." R5, R6, R8 have explicit Phase verification steps.

---

## 8. Verification

### 8.1 Static checks (Phase 1 + Phase 3)

```bash
shellcheck bin/claudehome install_client.sh install_server.sh           # AC-5T18
pwsh -Command "Invoke-ScriptAnalyzer bin/claudehome.ps1, install_client.ps1 -Severity Warning,Error"  # AC-5T-PC13
bin/claudehome --help > /dev/null && echo OK
pwsh -NoProfile -File bin/claudehome.ps1 --help > $null
```

### 8.2 Wire-format check (Phase 1)

Manual on the mini (or local mode), with a hand-crafted fixture exercising all 5 user-facing types:

```bash
mkdir -p /tmp/ct/{plain_folder,bar_suite/foo_hub,bar_suite/site,bar_suite/apps/weird_hub}
touch /tmp/ct/regular_proj/CLAUDE.md
touch /tmp/ct/bar_suite/foo_hub/CLAUDE.md
touch /tmp/ct/bar_suite/site/CLAUDE.md
touch /tmp/ct/bar_suite/apps/weird_hub/CLAUDE.md
mkdir -p /tmp/ct/empty_suite

CLAUDEHOME_LOCAL=1 CLAUDEHOME_PROJECTS_DIR=/tmp/ct bin/claudehome
# Inspect emitter output via temporary `set -x`. Expected (modulo find ordering):
#   ---TREE---
#   .                                         R   <n>
#   plain_folder                              F   0
#   regular_proj                              P   1
#   bar_suite                                 S   3
#   bar_suite/foo_hub                         P   1
#   bar_suite/site                            P   1
#   bar_suite/apps                            F   1
#   bar_suite/apps/weird_hub                  P   1
#   empty_suite                               S   0
#   ---TMUX---
# After parser post-classification:
#   bar_suite/foo_hub                         H   (parent IS Suite, basename _hub)
#   bar_suite/site                            M
#   bar_suite/apps/weird_hub                  M   (parent NOT Suite — apps/)
```

### 8.3 Parser invariant (Phase 1, R6)

```bash
# Hand-craft a wire-format payload with every type code + one bogus.
cat > /tmp/wire-test <<'EOF'
---TREE---
.	R	0
folder	F	0
suite	S	0
project	P	0
hub	H	0
member	M	0
bogus	Q	0
---TMUX---
EOF

# Feed it to the parser via test harness (Phase 1 deliverable):
# Run a stripped-down version of bin/claudehome that reads from a file instead of
# fetching. Confirm: 6 of 7 rows parsed; 1 (bogus) dropped; SKIPPED_BAD_PATHS == 1;
# stderr contains "skipped 1 path".
```

### 8.4 Picker UX (Phase 2 + Phase 3)

Manual repro for each of AC-5T1 through AC-5T8 + AC-5T-PC1 through PC8. See §6 mapping table for fixture setup per AC.

### 8.5 Hub-aware creation flow (Phase 2 + Phase 3)

End-to-end repro of AC-5T13:

```bash
# Setup:
mkdir -p ~/projects/claudehome-projects/test_suite/test_hub
touch ~/projects/claudehome-projects/test_suite/test_hub/CLAUDE.md
echo "# test_hub" > ~/projects/claudehome-projects/test_suite/test_hub/CLAUDE.md
echo "# Hub README" > ~/projects/claudehome-projects/test_suite/test_hub/README.md
cat > ~/projects/claudehome-projects/test_suite/test_hub/projects.md <<'EOF'
| Name | Description | Status | Owner | Notes |
|------|-------------|--------|-------|-------|
EOF

# Run:
claudehome
# Drill → test_suite/ → [new...] → member → name="alpha" → description="hello world"
# Picker exits, tmux attaches to claudehome-alpha. Detach.

# Verify on the mini:
test -d ~/projects/claudehome-projects/test_suite/alpha/.git && echo "git init OK"
diff -u <(cat ~/projects/claudehome-projects/test_suite/alpha/CLAUDE.md) <(cat <<EOF
# alpha

@/Users/genehan/projects/claudehome-projects/test_suite/test_hub/README.md

hello world
EOF
)
# Expect: empty diff (CLAUDE.md byte-identical).

tail -1 ~/projects/claudehome-projects/test_suite/test_hub/projects.md
# Expect: | alpha | hello world | active | — | — |
```

### 8.6 Multi-Hub warn-and-skip (Phase 2, AC-5T16)

```bash
# Setup: a Suite with TWO Hubs.
mkdir -p ~/projects/claudehome-projects/multi_suite/hub_a ~/projects/claudehome-projects/multi_suite/hub_b
touch ~/projects/claudehome-projects/multi_suite/hub_a/CLAUDE.md
touch ~/projects/claudehome-projects/multi_suite/hub_b/CLAUDE.md
mv ~/projects/claudehome-projects/multi_suite/hub_a ~/projects/claudehome-projects/multi_suite/hub_a_hub
mv ~/projects/claudehome-projects/multi_suite/hub_b ~/projects/claudehome-projects/multi_suite/hub_b_hub

# Run:
claudehome 2>warn.log
# Drill → multi_suite/ → [new...] → member → name="alpha"
# Description prompt does NOT fire.

grep "multiple \*_hub siblings" warn.log
# Expect match: "claudehome: multiple *_hub siblings found in /Users/.../multi_suite; skipping hub-aware writes"

# Verify the Member is plain:
test ! -d ~/projects/claudehome-projects/multi_suite/alpha/.git && echo "no .git OK"
cat ~/projects/claudehome-projects/multi_suite/alpha/CLAUDE.md
# Expect: # alpha\n  (single line, no @-import)
```

### 8.7 Fixture-diff for the 4-copy emitter (R5 carry-over; P3 PATCHED — REGENERATE)

The shipped folder-tree-v1 plan §8.8 established the fixture-diff verification under `tests/fixtures/remote-payload.expected.sh` (or `remote-payload.folder-tree-v1.expected.sh` if the rename convention is in place). **The 5-type wire-format change invalidates that fixture entirely** — the classification block (n_all/n_dirs heuristic) is replaced by the CLAUDE.md probe + suffix check, so the captured shell text from v1.2.0.0 no longer matches what the new `bin/claudehome` emits.

**Decision (P3): REGENERATE, do not extend.** Phase 1 produces a brand-new fixture file from scratch. The folder-tree-v1 fixture is preserved as historical record but not consulted by 5-type CI checks.

**Per-feature fixture naming convention (formalized here):**
- `tests/fixtures/remote-payload.folder-tree-v1.expected.sh` — historical (1.2.0.0); reference only, not run by 5-type CI.
- `tests/fixtures/remote-payload.5type-v1.expected.sh` — **NEW**, generated in Phase 1.
- `tests/fixtures/remote-payload.5type-v1.ps.expected.txt` — pwsh `$remoteDataTpl` rendered output (Phase 3).
- Future features follow `remote-payload.<feature-slug>.expected.sh` / `.ps.expected.txt`.

**Phase 1 capture (regenerate from scratch):**

```bash
# Phase 1, one-time on the mini (or local mode):
mkdir -p tests/fixtures
git rm tests/fixtures/remote-payload.expected.sh 2>/dev/null || true   # if v1.2.0.0 fixture exists at the legacy unversioned path
# (The v1.2.0.0 fixture stays accessible via git history. We rename to a per-feature name on the way out:
#  if a fixture currently exists at the un-versioned path, also commit its rename to remote-payload.folder-tree-v1.expected.sh BEFORE this Phase 1 capture step,
#  so historical-record vs. current-CI is unambiguous.)

set -x
bin/claudehome 2> /tmp/render-initial.log
# (drill, pick [new...] → folder → testtmpa  — exercises refetch path)
set +x

grep '^+ ssh\|^+ find' /tmp/render-initial.log > tests/fixtures/remote-payload.5type-v1.expected.sh
git add tests/fixtures/remote-payload.5type-v1.expected.sh

# Verification step (P3 explicit): the new fixture MUST contain literal references to:
#   1. the CLAUDE.md probe — `[ -f "$p/CLAUDE.md" ]` (regular-file test, not symlink)
#   2. the suffix case — `*_suite) t=S ;;` (the new case-arm)
#   3. the type letters R, F, S, P (no H/M; those are parser-side)
grep -F '[ -f "$p/CLAUDE.md" ]' tests/fixtures/remote-payload.5type-v1.expected.sh \
  || { echo "FAIL: fixture missing CLAUDE.md probe — wire format not regenerated"; exit 1; }
grep -F '*_suite) t=S' tests/fixtures/remote-payload.5type-v1.expected.sh \
  || { echo "FAIL: fixture missing _suite suffix case — wire format not regenerated"; exit 1; }
grep -E 'tt[ =]+[RFSP]' tests/fixtures/remote-payload.5type-v1.expected.sh \
  || { echo "FAIL: fixture missing R/F/S/P type emission"; exit 1; }
grep -E 'n_all=.*n_dirs' tests/fixtures/remote-payload.5type-v1.expected.sh \
  && { echo "FAIL: fixture still references stale n_all/n_dirs heuristic — partial regen"; exit 1; }
echo "Fixture regen verified — wire format is genuinely 5-type."
```

**Regression check on every subsequent edit (Phase 2+):**

```bash
set -x; bin/claudehome 2> /tmp/render.log; set +x
grep '^+ ssh\|^+ find' /tmp/render.log | diff - tests/fixtures/remote-payload.5type-v1.expected.sh
# Expect: empty diff. Any change to a payload requires updating the fixture in the same commit.
```

**Coverage:** the fixture captures (1) initial-fetch local emitter, (2) initial-fetch remote emitter, (3) refetch local emitter (after a `[new...] → folder` action), (4) refetch remote emitter, (5) pwsh `$remoteDataTpl` (separate fixture for PC: `tests/fixtures/remote-payload.5type-v1.ps.expected.txt`, captured by a Pester script that templates the bash payload via `Replace`).

**Why REGENERATE not extend:** the v1.2.0.0 fixture's emitter block contains the n_all/n_dirs glob comparison (`[ "$n_all" -gt 0 ] && [ "$n_all" = "$n_dirs" ] && t=F || t=P`). The 5-type emitter replaces that with `[ -f "$p/CLAUDE.md" ] && t=P` + the `_suite` case. Lines diff cleanly — there is no semantic merge. Extending an obsolete fixture would silently mix old + new logic in CI, masking real wire-format drift.

### 8.8 Migration smoke (Phase 4, R8)

```bash
# On the mini, BEFORE upgrade:
ls ~/projects/claudehome-projects/  # 14 dirs as listed in §3.2
for d in ~/projects/claudehome-projects/*/; do
  [ -d "$d" ] && [ -f "$d/CLAUDE.md" ] && echo "HAS: $(basename "$d")" || echo "MISS: $(basename "$d")"
done
# Expect: 4 HAS, 10 MISS as enumerated in §3.2.

# AFTER upgrade, BEFORE recovery:
claudehome
# Picker shows 4 Project rows + 10 Folder rows. Drilling into each Folder shows nothing.

# Run recovery (one-line global glob):
for d in ~/projects/claudehome-projects/*/; do
  [ -d "$d" ] && [ ! -f "$d/CLAUDE.md" ] && touch "$d/CLAUDE.md" && echo "touched $(basename "$d")/CLAUDE.md"
done
# Expect: 10 lines of "touched ..." output.

# AFTER recovery:
claudehome
# Picker shows 14 Project rows. Original behavior fully restored.
```

### 8.9 OQ-2 auto-suffix policy (Phase 2, R10; P2 patched)

```bash
# Test 1 (happy path, AC-5T10): bare name → auto-append.
claudehome  # at root
# [new...] → suite → "gene-mini" → confirms creation of gene-mini_suite/
ls ~/projects/claudehome-projects/gene-mini_suite || echo "FAIL: not created"

# Test 2 (AC-5T19, suffix-form rejection): name already ends with _suite → reject.
claudehome
# [new...] → suite → "gene-mini_suite"
# Expect stderr: "claudehome: name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended."
# Re-prompt (no creation, picker remains).

# Test 3 (AC-5T19, interior-substring rejection — P2): name has _suite buried inside.
claudehome
# [new...] → suite → "gene-mini_suite_v2"
# Expect stderr: "claudehome: name '_suite' substring not allowed; type just the prefix and the suffix is auto-appended."
# Re-prompt (no creation). The bash glob `*_suite_*` catches this case where `*_suite` (suffix-only) would not.
ls ~/projects/claudehome-projects/gene-mini_suite_v2 2>/dev/null && echo "FAIL: should not exist"
ls ~/projects/claudehome-projects/gene-mini_suite_v2_suite 2>/dev/null && echo "FAIL: double-substring auto-append leaked"

# Test 4 (AC-5T20 mirror, hub equivalent): same three sub-tests with the hub branch:
#   - "gene-mini" → auto-appends to "gene-mini_hub" (happy path)
#   - "gene-mini_hub" → rejected (suffix form)
#   - "gene-mini_hub_v2" → rejected (interior substring)
# Repro must be done inside a Suite without an existing Hub (so [new...] → hub is offered).
```

---

## 9. Out of Scope (explicit, restated from spec for reviewer challenge)

The following are **not** in this plan and must not be added during execution:

- **Content-based classification.** No parsing of CLAUDE.md content for `@`-imports or markers. Structural only. Spec line 149.
- **Nested Suites.** A Suite cannot contain another Suite. v1 detects + warns + demotes-to-Folder; full support deferred. Spec line 150.
- **Multi-Hub deterministic primary picker.** Multi-Hub Suites warn-and-skip; no primary selection. Spec line 151.
- **Auto-migration of existing projects.** v1 does not run the recovery command for the user. Spec line 152. (We provide the one-line command in CLAUDE.md.)
- **Picker mv/rename/delete.** Spec line 153 (carry-over).
- **Marker files (`.hub`, `.suite`, `.claudehome-folder`, etc.).** CLAUDE.md is the only marker. Spec line 154.
- **Tagging or virtual folders.** Each directory has exactly one type. Spec line 155.
- **Hub validation.** No check that `<hub>/README.md` exists, that `projects.md` has the right header, etc. Hub author concern. Spec line 156.
- **Custom suffixes / configuration.** `_suite` and `_hub` are hardcoded. No `~/.claudehomerc` key. Spec line 157.
- **Subcommands beyond `--help`.** CLI surface stays at `claudehome` / `claudehome --help`. Spec line 158; CLAUDE.md scope guardrail.
- **Backward compatibility with the legacy `_pjt` suffix.** hub-aware-v1 used `_pjt`; this spec uses `_suite`. Users with existing `_pjt` directories rename. Spec line 159.
- **Daemons / state files / `.claudehome/types.json`.** None.
- **iPhone / web client.** Out of scope per CLAUDE.md scope guardrails (carry-over).

---

## 10. Handoff Notes for Architect / Critic

- **Plan executes in 4 phases; Phase 1+2 ship together** (single PR, deployed atomically). Phase 1 alone (new wire format, no Suite/Hub/Member badges) leaves the parser parsing 6-code rows but rendering them as 3-code-style — confusing as an interim release. Phase 3 (PC parity) and Phase 4 (CLAUDE.md + migration recovery) are each independently deployable on top of shipped Phase 1+2.
- **File creation order during execution:** (1) `bin/claudehome` Phase 1+2 (one PR), (2) `bin/claudehome.ps1` Phase 3 mirror, (3) `CLAUDE.md` updates last.
- **All 4 bash emitter copies must be edited in lock-step.** This is the highest-risk edit class (R5). The fixture-diff verification (§8.7) is the only programmatic check; manual validation in Phase 1 must run all 4 paths (initial local, initial remote, refetch local after `[new...] → folder`, refetch remote after `[new...] → folder`).
- **Parser post-classification logic must be byte-identical between bash and pwsh.** Member/Hub detection is a string-only ancestor walk; both implementations split on `/` and check basename suffix. Phase 3 verification (§8.3) injects a hand-crafted wire payload and confirms both languages classify identically.
- **The recovery command for legacy flat projects is run BY THE USER, not by the upgrade.** This is a deliberate non-goal (spec line 152, Auto-migration). The CLAUDE.md "Migrating legacy flat projects" section provides the one-line command. Architect/Critic should challenge if they think auto-migration is warranted; we hold the line because (a) modifying user projects on upgrade violates the "no installer changes" guardrail, (b) the recovery is one shell command and the user is technical enough to run it (this is a personal-tool, not a consumer product), (c) `touch <dir>/CLAUDE.md` is reversible (`rm <dir>/CLAUDE.md` flips back to Folder).
- **Multi-Hub policy is LOCKED at warn+skip** with no deterministic primary picker. Critic is expected to challenge "why not pick alphabetical-first as a v1 polish?" Answer: any deterministic rule is hidden behavior the user cannot opt out of without renaming. Warn-and-skip preserves agency. Spec line 79-80 + Non-Goals line 151 explicitly say so.
- **OQ-2 auto-suffix policy is LOCKED at "auto-append; reject if user already typed the suffix".** Documented in §3.3 + R10 + AC-5T10. Tested in §8.9.
- **The Suite-ancestor walk inside the `find ... \| while read` pipe is non-trivial.** The chosen approach is to emit `P` for all has-CLAUDE.md rows server-side, then post-classify in the parser (one O(depth) string scan per P row, in-memory). This puts the ancestor logic in *one* place per language. Alternative (server-side walk-up per row) was rejected for adding O(depth) bash subshell work per row in the SSH payload.
- **OQ-1 (Suite-root drill rendering) RESOLVED.** Picker at Suite-root drill level shows: `[..  back]` → Folders+Suites alphabetical interleaved → Projects+Hubs+Members active-then-idle → `[new...]`. Same ordering as every other drill level. No section headers, no separator rows. Spec lines 88, AC-5T-PC1.
- **No new external dependency.** `find`, `tmux`, `ssh`, `mkdir`, `git` are already on the mini today (claudehome v1 + folder-tree v1 carry-over). `git init` is the only addition; Xcode CLT ships it on macOS, and the mini already has it (the `claudehome` repo itself is git-tracked).

---

## 11. Open Questions

*(Persisted to `.omc/plans/open-questions.md` by the planner.)*

### Open

- **OQ-3 (NEW):** When a user picks `[new...] → folder` inside a Suite (top-level child of Suite), the resulting `bar_suite/<newfolder>/` is a sub-folder. If the user later moves a Project into `<newfolder>/` via raw `mv`, that Project becomes a Member transitively. **Question:** should the picker offer to "promote" a Folder to a Project on user demand (i.e., touch CLAUDE.md inside it)? Defer to first user request. — Why it matters: closes the loop on raw-`mv` workflow without forcing the user to drop to a shell.
- **OQ-4 (P9 NEW, deferred — Architect's structural-smell observation):** The parser regex `^[RFSPHM]$` accepts H and M codes that the server emitter never actually emits (server emits P for all has-CLAUDE.md rows; parser materializes H/M from P via the ancestor walk). Architect flagged this as a potential structural smell — the wire format's "legitimate set" and the parser's "accepted set" are not symmetric. **Question:** should v1.1 move H/M synthesis to the server-side emitter for wire-format-vs-parser symmetry? **Defer until measured:** does the parser-side ancestor walk introduce real bugs in practice? Defensible as-is per Architect (single source of truth in shell payload, server avoids per-row subshell walks). Revisit if telemetry shows parser bugs OR if the R-PERF 500ms worst-case ancestor walk becomes a real complaint. — Why it matters: clean wire-format invariants are easier to audit; if a future contributor sees `H` in the parser regex but never in any emitter, they may delete it as dead code.
- **OQ-5 (P10 NEW, deferred — Architect's optional Multi-Hub revisit):** Multi-Hub Suites currently warn-and-skip with no deterministic primary picker. Architect suggested an alphabetical-first primary Hub fallback as friendlier UX (the user's `[new...] → member` would still succeed, just attach to the alphabetically-first Hub). The plan currently LOCKS warn+skip per spec line 79-80 + Non-Goals line 151. **Question:** should v1.1 switch Multi-Hub from warn+skip to alphabetical-first-primary + warn? **Defer until first user reports they actually got into a multi-Hub state.** Rationale for current lock: any deterministic rule is hidden behavior the user cannot opt out of without renaming directories. Warn-and-skip preserves agency. Alphabetical-first is a convenient v1.1 polish IF user reports surface that Multi-Hub is a real workflow rather than a misconfiguration. — Why it matters: this is the only major ergonomic concession in the spec; revisiting it after first contact with reality is cheaper than locking it in v1.

### Resolved (in this iteration)

- **OQ-1 (RESOLVED, was spec OQ-1):** Suite-root drill rendering. **Resolution:** alphabetical-interleaved Folders+Suites, then active-then-idle Projects+Hubs+Members, then `[new...]`. Same ordering as every other drill level. No section headers. Documented in §3.3.
- **OQ-2 (RESOLVED, was spec OQ-2):** Auto-suffix policy for Suite/Hub. **Resolution:** auto-append `_suite`/`_hub` to user-typed name if missing; reject (with re-prompt) if user-typed name already ends with the suffix. Documented in §3.3 + R10 + tested in §8.9.

### Persisted to .omc/plans/open-questions.md (Analyst pending)

The Analyst step is expected to add any further requirements gaps. None known at plan-draft time.

---

## Iteration 2 Changelog

This iteration applies the Architect (APPROVE WITH IMPROVEMENTS, 7 patches) + Critic (ITERATE, 4 critical + 4 major) feedback from iter-1. All four critical patches landed; all four major patches landed; both nice-to-have patches landed as deferred OQs. No architectural changes — these are precision/mechanical fixes plus one explicit walkthrough.

### Critical patches

- **P1 — `warn()` helper defined explicitly (Critic-found, Architect missed).** Added bash `warn() { echo "claudehome: $*" >&2; }` definition in §4.1 bash-isms section. Added pwsh equivalent `Write-WarnStderr` in §4.2 pwsh-isms section. Both must return 0 / not throw, so `git init >/dev/null 2>&1 || warn "..."` does not trip `set -euo pipefail` and abort the picker mid-creation. Without this, partial on-disk state was a real failure mode.
- **P2 — Auto-suffix substring rejection (Critic-found bug).** §3.3 step 6 now uses `case "$name" in *_suite|*_suite_*) reject ;;` to catch BOTH suffix-form (`gene-mini_suite`) AND interior-substring form (`gene-mini_suite_v2`). Previously the plan's `*_suite` glob would have silently let `gene-mini_suite_v2` through and produced `gene-mini_suite_v2_suite` on auto-append. Pwsh mirror via `-match '_suite'`. New ACs AC-5T19 (suite substring) and AC-5T20 (hub substring mirror) added to §6. R10 risk text updated to call out both cases. §8.9 expanded to test all three sub-cases (happy path, suffix rejection, interior-substring rejection) per branch.
- **P3 — §8.7 fixture: REGENERATE not extend.** Rewrote §8.7 to make explicit that the v1.2.0.0 fixture is invalidated by the wire-format change (n_all/n_dirs heuristic → CLAUDE.md probe + suffix check). Phase 1 produces a brand-new fixture file `tests/fixtures/remote-payload.5type-v1.expected.sh` from scratch. Added a verification step that the new fixture references `[ -f "$p/CLAUDE.md" ]` literally AND contains the new type-classification logic AND does NOT contain stale `n_all/n_dirs` text. Documented per-feature fixture naming convention.
- **P4 — AC count is 36, not 32 (Critic-found, Architect missed).** §6 header updated to "AC Mapping Table — 36 ACs" with breakdown (20 Mac + 14 PC + 2 LOCAL = 36). PC table expanded from a single lumped row "AC-5T-PC1 through AC-5T-PC11" into 11 individual rows for auditability. New ACs AC-5T19 and AC-5T20 added to Mac table after AC-5T18. PC mirror of these substring tests rolled into AC-5T-PC14's existing byte-identical-stderr requirement (one source of truth for stderr wording across clients) rather than adding two more PC ACs — keeps total at 36. Testability summary line updated.

### Major patches

- **P5 — Explicit `walk_to_suite_root` dispatch in §3.3 step 1.** §3.3 `prompt_new_anything` step 1 now spells out exactly what happens for each `parent_type`. Critically, F-type (Folder) is structurally ambiguous (plain Folder vs. sub-Folder inside a Suite) — the plan now explicitly calls `walk_to_suite_root` first to disambiguate, and switches valid creation types based on the result. The valid-types table reformatted to a 3-column form showing Drill type → Valid types → Disambiguation step.
- **P6 — `_pjt` legacy migration note added to §4.3.** New paragraph in the CLAUDE.md "Migrating legacy flat projects" section explains: the never-shipped hub-aware-v1 spec used `_pjt`; the 5-type model uses `_suite`. Plan does NOT auto-detect or warn about `_pjt` (any such directories classify as plain Folders). Provided one-line rename command for users who happen to have any.
- **P7 — Realistic perf numbers + R8 impact M → H.** R-PERF rewritten with measured numbers (16K bash glob × ~30µs each = 500ms worst case; typical depth-3 user ≈ 180ms). R8 impact bumped from Medium to **High** (10 of 14 = 71% of existing user projects flip to Folder on upgrade — that is High-impact in expectation, regardless of the user's pain tolerance for the specific 10 projects).
- **P8 — Phase ordering: ship CLAUDE.md migration note WITH Phase 1+2.** New "Phase ordering decision" sub-section in §5 explains the rejected (docs-last) and chosen (docs-with-code) orderings. Phase 1 now ships the "Migrating legacy flat projects" section in the same PR as the wire-format change so users see the recovery command BEFORE they hit the broken UX. Phase 4 retains the remaining CLAUDE.md updates (Architecture paragraph, line counts, Key docs, AC checklist append) but no longer carries the critical migration note.

### Nice-to-have patches (deferred to OQ)

- **P9 — OQ-4 added.** Architect's "structural smell" — parser regex accepts H/M codes the server never emits — formally deferred as OQ-4. Defensible per Architect; revisit only if measured bugs surface. Persisted to open-questions.md.
- **P10 — OQ-5 added.** Architect's "optional Multi-Hub alphabetical-first revisit" formally deferred as OQ-5. Plan still LOCKS warn+skip for v1; v1.1 may revisit after first user reports a real Multi-Hub state. Persisted to open-questions.md.

### What did NOT change (intentional, per punch-list directive)

- Overall architecture: 4 server codes (`R/F/S/P`) + 2 client-synthesized codes (`H/M`) — sound.
- Wire format `R/F/S/P/H/M` — fine; parser regex permissive intentionally.
- Suite contents rule (Hub top-level + Members transitive + sub-Folders, no nested Suites).
- Single `[new...]` row, hub-aware in `[new...] → member`.
- AC count progression (32 → 34 → 36) — correct after adding AC-5T19/20.

### Files updated this iteration

- `/Users/genehan/projects/claudehome-projects/claudehome/.omc/plans/claudehome-5type-v1-plan.md` (this file).
- `/Users/genehan/projects/claudehome-projects/claudehome/.omc/plans/open-questions.md` (OQ-4 and OQ-5 appended as deferred follow-ups for the 5type-v1 work).
