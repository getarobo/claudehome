# Implementation Plan: claudehome folder-tree v1

## Source
Spec: `.omc/specs/deep-interview-claudehome-folder-tree-v1.md` (deep-interview, 14% ambiguity, PASSED)
Parent specs: `.omc/specs/deep-interview-claudehome-v1.md`, `.omc/specs/deep-interview-claudehome-pc-v1.md`
Parent plans: `.omc/plans/claudehome-v1-plan.md`, `.omc/plans/claudehome-pc-v1-plan.md`
Date: 2026-05-08
Mode: RALPLAN-DR (SHORT) — brownfield UX extension; no new env vars, no installer change, no daemons

---

## 1. RALPLAN-DR Summary

### Principles (non-negotiable)

1. **Single SSH round-trip preserved.** The remote-mode listing must continue to be one `bash --norc --noprofile -c '...'` payload. No second SSH call to descend into a folder. (CLAUDE.md "Architecture (one paragraph)"; bin/claudehome:181–185.)
2. **Mac+PC parity.** Every drill-down behavior implemented in `bin/claudehome` must be mirrored in `bin/claudehome.ps1`. Same payload format, same picker rows, same validation regex, same error text shape. (Spec AC-FT-PC1–PC10; existing parity convention from claudehome-pc-v1-plan.md.)
3. **No new state, no new env vars, no new installer prompts.** Folder layout lives on disk under `CLAUDEHOME_PROJECTS_DIR`; nothing else moves. (CLAUDE.md "Scope guardrails"; spec "Configuration".)
4. **Tmux session naming unchanged.** `claudehome-<basename>` stays. Folder is invisible to tmux. (Spec "Project naming & uniqueness"; AC-FT3.)
5. **Allowlist-before-interpolation, unchanged regex.** `[a-zA-Z0-9._-]` for names, `[a-zA-Z0-9._~/-]` for paths. The drill-down code adds *more* interpolated values into SSH payloads — every one must run through the same guard. (claudehome-pc-v1-plan.md ADR-PC-1; spec "Folder naming & creation".)

### Decision Drivers (top 3)

1. **Single-SSH-roundtrip preservation** — every alternative is judged first on whether it adds round-trips. Drill-down with an SSH per level is rejected.
2. **Zero migration burden on the existing 14 flat projects** — they keep working untouched, appearing in the synthetic `(root)` bucket only when both root projects AND folders coexist.
3. **Mac+PC parity at the wire-format level** — bash and pwsh must parse the *same* tree-walk payload with the *same* heuristic so the two clients behave identically.

### Viable Options (with bounded pros/cons)

#### Option A (CHOSEN): Client-side tree from a single flat tree-walk payload

The remote/local one-shot returns a flat list of every directory under `CLAUDEHOME_PROJECTS_DIR`, each row tagged as folder/project/empty along with tmux state for the basename. Client groups rows into a tree in memory and re-pickers locally as the user drills.

- **Pros:**
  - Preserves single SSH round-trip — fits CLAUDE.md ADR.
  - Parses identically in bash and pwsh (same wire format → same heuristic).
  - Drill-down is purely a local-loop concern; no second remote call ever.
  - Globally-unique project name check is trivial: scan the in-memory list.
- **Cons:**
  - Payload size grows linearly with tree size; needs a hard cap (mitigated, see Risk R1).
  - Tagging rows requires deciding folder-vs-project on the **server side** (bash) and **local side** (PowerShell when local mode applies — N/A on PC) inside the one-shot. Manageable: a single `find` invocation does it.

#### Option B (REJECTED): Per-level SSH on each drill

Top level lists immediate children of `CLAUDEHOME_PROJECTS_DIR`; selecting a folder issues a fresh `ssh ... ls subfolder` round-trip; selecting `[new folder here]` issues another `ssh ... mkdir -p`.

- **Pros:**
  - Smaller per-call payload.
  - Easier conceptually (each picker is one shell `ls`).
- **Cons:**
  - Adds 100–300ms per drill click (spec "Decision Drivers" parent plan).
  - Globally-unique project name check across the full tree would need an *additional* SSH call before each `[new project here]` — third round-trip per creation. Awful UX.
  - Violates Principle 1.

#### Option C (REJECTED): Encode the tree as nested JSON in the payload

Single SSH round-trip but the payload is a JSON document (`{"work":{"client-a":{"site":"active 5h"}}}`).

- **Pros:**
  - Compact.
  - Self-describing.
- **Cons:**
  - Needs a JSON parser in bash — neither macOS bash 3.2 nor pwsh "out of the box" has a uniform built-in. Adds `jq` dependency on Mac (parent plans avoid it) or fragile `python -c` fallback.
  - Wire format diverges from existing `path<TAB>...` style used today (bin/claudehome:181–185 returns line-based output).
  - Two-language parser implementation breaks the parity-by-format property of Option A.

#### Option D (REJECTED): Delete the on-disk hierarchy idea, use an annotation file

A `.claudehome/folders.json` on the mini holds the virtual tree.

- **Cons:**
  - Spec "Configuration" forbids state files.
  - CLAUDE.md "Scope guardrails" forbids "persistent state files."
  - Discarded as out-of-scope before considering pros.

**At least 2 viable options retained:** Option A and Option B. B is rejected on Driver 1 (latency) and Driver 3 (parity at wire level). A is the chosen path.

---

## 2. ADR

**Decision.** Implement folder-tree v1 as a client-side drill-down picker fed by a **single flat tree-walk payload** from one SSH round-trip (or one local `find` in local mode). Each row in the payload is `path<TAB>type<TAB>session_state<TAB>last_activity` (TAB-separated, sentinel-delimited). Client-side bash and pwsh build an in-memory tree, render one picker per drill level, and recurse without further remote calls.

**Drivers.**
1. Single-SSH-roundtrip preservation (CLAUDE.md ADR; latency).
2. Mac+PC parity at the wire level (one format, two parsers, byte-identical UX).
3. Zero migration burden.

**Alternatives considered.**
1. **Per-level SSH (Option B).** Rejected — adds a round-trip per drill click; spoils globally-unique check.
2. **Nested JSON payload (Option C).** Rejected — `jq` dependency or fragile `python -c`; diverges from current line-based wire format.
3. **State file `.claudehome/folders.json` (Option D).** Rejected — spec and CLAUDE.md forbid state files.
4. **Single tree-preview screen via `fzf --preview` (Spec Non-Goal).** Rejected — spec explicitly chose drill-down over flat tree view.

**Why chosen.** Option A is the only path that simultaneously satisfies: (a) one SSH round-trip, (b) `jq`-free portable parsing in both bash 3.2 and pwsh 7+, (c) cheap globally-unique check, (d) zero changes to installers / env vars / state files. The added complexity is bounded to two new functions per client (tree walk + drill loop) and a redefined picker-row format that is locally backward-compatible (project rows look the same as today).

**Consequences.**
- *Positive:* Drill-down is instantaneous (no network on each click). Globally-unique check is an in-memory scan. Zero migration. Existing 14 flat projects continue to work without touching disk.
- *Negative:* The one-shot payload grows with tree size; a malformed projects dir could emit thousands of rows. Mitigated by a hard cap (R1 below). Folder-vs-project heuristic must be computed server-side inside the one-shot bash; that's a single `find` invocation but it adds bash complexity.
- *Depth cap (8):* Although the spec confirmed "arbitrary depth," v1 hard-caps the walk at `-maxdepth 8` to bound payload size. Trees deeper than 8 are still usable on the mini (the user can `cd` and `mkdir` directly), but invisible to the picker. The emitter detects this via a separate `find . -mindepth 9` probe and emits a `---DEPTH-TRUNCATED---` sentinel; the client surfaces a stderr warning so the user is never confused about why a deep folder is missing. Revisit the cap if any user reports a real-world need for depth >8 (no such case is currently anticipated for personal-tool trees).

**Follow-ups (deferred).**
- Picker `mv`/`rename`/`delete` operations (Non-Goal).
- Per-folder uniqueness as a config option (Non-Goal).
- Auto-cleanup of empty folders (Non-Goal).
- A `claudehome ls --tree` subcommand (Non-Goal — CLI surface stays at `claudehome` / `claudehome --help`).

---

## 3. Architecture

### 3.1 Tree-walk payload format

**One block.** Each row is TAB-separated, terminated by `\n`. The leading sentinel `---TREE---` and the trailing sentinel `---TMUX---` separate the tree-walk output from the existing tmux block. The tmux block format is unchanged (`session_name session_activity`, space-separated, one per line) so existing parsing logic for active/idle annotations carries over.

```
---TREE---
.<TAB>F<TAB>0
work<TAB>F<TAB>2
work/client-a<TAB>F<TAB>1
work/client-a/site<TAB>P<TAB>0
personal<TAB>F<TAB>3
personal/blog<TAB>P<TAB>0
personal/notes<TAB>P<TAB>0
personal/empty<TAB>P<TAB>0
hello<TAB>P<TAB>0
demo<TAB>P<TAB>0
---TMUX---
claudehome-site 1714000000
claudehome-hello 1715000000
```

**Field semantics:**
- **Field 1: `path`** — relative to `$PROJECTS_DIR`. The literal string `.` represents the projects root itself. Forward-slash separator (POSIX). No trailing slash.
- **Field 2: `type`** — single character. `F` = folder (a dir whose immediate children are *all* dirs). `P` = project (any other dir, including empty). `R` = synthetic root (only the `.` row uses this in practice; treated as `F` by the parser, but R-tagged so the client knows whether to show the `(root)` bucket — see §3.3).
- **Field 3: `child_count`** — integer count of immediate children (folders + projects). For a project, always `0`. Used only for the `(N)` annotation in folder rows.

**Why TAB-separated, not space-separated:** project names allow `.` and `-` and `_` but never TAB. The separator is unambiguous.

**Encoding nested paths:** the literal string `work/client-a/site`. The parser groups rows by their parent path (`dirname`-style split on the last `/`). The root rows (no `/`) live under `.`.

**`(root)` signalling:** the synthetic `(root)` bucket is shown at step 1 *only when* both of these are true:
1. At least one row exists with `type=P` and no `/` in its path (a flat-root project).
2. At least one row exists with `type=F` and no `/` in its path (a top-level folder).

If only flat projects exist, step 1 is the flat list (no `(root)` row, AC-FT1). If only folders exist, step 1 is the folder list (no `(root)` row).

**Empty folders signalling:** folders with `child_count=0` still emit their own row (tagged `F`). No descendant rows follow. This makes the `(0)` annotation possible (AC-FT10).

**Sample remote payload generator (bash, server-side, inside `bash --norc --noprofile -c`):**

```bash
{
  echo ---TREE---
  ( cd "$PROJECTS_DIR" 2>/dev/null && \
    total=$(find . -maxdepth 8 -type d ! -path '*/.*' 2>/dev/null | wc -l | tr -d ' ')
    deeper=$(find . -mindepth 9 -type d ! -path '*/.*' 2>/dev/null | head -n 1)
    find . -maxdepth 8 -type d ! -path '*/.*' -print0 \
      | awk -v RS='\0' -v ORS='\0' 'NR<=2000' \
      | while IFS= read -r -d '' p; do
          rel="${p#./}"
          [[ "$p" == "." ]] && rel="."
          # Folder vs project heuristic — see §3.2.
          immediate_children=$(find "$p" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' ')
          immediate_dirs=$(find "$p" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | tr -dc '\0' | wc -c | tr -d ' ')
          if [[ "$rel" == "." ]]; then
            type=R
          elif [[ "$immediate_children" -gt 0 && "$immediate_children" == "$immediate_dirs" ]]; then
            type=F
          else
            type=P
          fi
          printf '%s\t%s\t%s\n' "$rel" "$type" "$immediate_children"
        done
    [[ "$total" -gt 2000 ]] && echo ---TRUNCATED---
    [[ -n "$deeper" ]] && echo ---DEPTH-TRUNCATED---
  )
  echo ---TMUX---
  tmux list-sessions -F "#{session_name} #{session_activity}" 2>/dev/null || true
}
```

(Production version will inline `immediate_children` / `immediate_dirs` more efficiently — see file-by-file changes §4.1; this listing shows the wire-format intent.)

### 3.2 Folder-vs-project heuristic — concrete spec

Per spec "Discovery": *a directory is a folder iff every immediate child is itself a directory; otherwise project. Empty directories are projects.*

**Concrete rules, edge cases enumerated:**

| Case | Type | Rationale |
|------|------|-----------|
| Empty directory `foo/` | `P` | Spec: "Empty directories are projects (so `[new project]` works)." |
| `foo/` containing only `bar/` | `F` | Every immediate child is a directory. Children counted: 1. |
| `foo/` containing `bar/` + `baz.txt` | `P` | Mixed: at least one non-directory immediate child. |
| `foo/` containing only `.git/` | `F` | `.git` is a directory; counts as a child. **This is a known surprise:** a project with only a `.git` and no checked-out files would be classified as a folder. Mitigated: real projects have files. We document this in CLAUDE.md (§4.3) and revisit if reported. |
| `foo/` containing only `.DS_Store` | `P` | Hidden file present. (Note: `find -not -path '*/.*'` only filters traversal of dot-paths, not visibility of dot-files inside a dir; we use `find "$p" -mindepth 1 -maxdepth 1` to count, and dotfiles count as children.) |
| `foo/` is a symlink to a dir | Not traversed | BSD `find` does not follow symlinks unless `-L` is passed as a *global* option before the path; since we do not pass `-L`, default behavior already does not follow them. The symlink itself is *not* matched by `-type d` (BSD `find -type d` matches real directories only without `-L`), so the entry is omitted from the walk entirely. Justification: the existing claudehome-v1 walk doesn't traverse symlinks either; preserve that behavior. |
| `foo/` contains 1000 files | `P` | `child_count` is reported but only used for the `(N)` annotation. |

**Server-side `find` invocation (bash payload):**
```
find . -maxdepth 8 -type d ! -path '*/.*' -print0
```
- `-maxdepth 8` is the **hard cap** on depth. (See R3.) Bumped from 5 → 8 because spec round 3 confirmed "arbitrary depth"; 8 covers any sane personal-tool tree. Anything deeper than 8 is invisible to the picker, and a `---DEPTH-TRUNCATED---` sentinel is emitted (see R3 + emitter §3.1) so the user gets a stderr warning.
- `! -path '*/.*'` excludes traversal into hidden directories (`.git/`, `.cache/`, `.omc/`). Top-level hidden dirs at the projects root are also skipped. `!` is BSD-portable; `-not` is a GNU-ism that BSD `find` accepts inconsistently — we use `!` for portability.
- BSD-`find` default behavior does not follow symlinks (no `-L` global option is passed), so symlinks-to-dirs are skipped automatically. We do **not** use `-not -L` because BSD `find` rejects `-L` as a non-global operator with `find: -L: unknown primary or operator`.
- `-print0` tolerates spaces in names (though our allowlist forbids them; defense in depth).
- Pipeline-truncated to 2000 lines via `awk -v RS='\0' -v ORS='\0' 'NR<=2000'`. The bare `head -z -n 2000` form is rejected by macOS BSD `head` (`head: invalid option -- z`); GNU-only. The bare `awk 'NR<=2000'` form is also wrong because awk's default `RS='\n'` would consume the entire NUL-stream as one record and emit nothing. The form `awk -v RS='\0' -v ORS='\0' 'NR<=2000'` correctly preserves NUL-framing for the downstream `read -r -d ''` consumer (R1).

**PowerShell-side equivalent (used only in the absence of local mode — N/A on PC since PC client is remote-only):** not applicable. PC always SSHes; the same bash payload runs on the mini.

**Local-mode equivalent (Mac, `CLAUDEHOME_LOCAL=1`):** the same bash snippet runs locally; no SSH. (bin/claudehome:171–178 already has this branch — extend it with the tree-walk emitter.)

### 3.3 Drill-down state machine

**Bash state:**
- `current_drill_path` — string. `""` (empty) at top level. `"work/client-a"` after drilling twice.
- `tree_rows` — array of all parsed rows, populated once from the payload.
- `PICKER_RESULT` — global string. Empty until the user picks a project (real or new); set to `"attach"` when the loop should unwind and the dispatcher should attach.
- `PICKER_PROJECT` — global string. Basename of the chosen project (e.g. `site`).
- `PICKER_PARENT` — global string. Parent path of the chosen project (e.g. `work/client-a`, or `""` for root).
- `picker_loop()` — recursive function that, given a `path`, filters rows whose parent equals it, builds the picker, runs fzf/select, and either: (a) recurses with a new path, (b) sets `PICKER_RESULT="attach"` and returns to unwind, (c) loops on stay-at-this-level cases (folder created, then user picks again), or (d) returns plain on back/cancel.

**Why a global instead of a sentinel return code.** `bin/claudehome:5` runs under `set -euo pipefail`. Under `errexit`, any non-zero return from a bare function call aborts the script before a `case "$?" in ...` can read it — empirically verified: `set -euo pipefail; foo() { return 100; }; foo; case "$?" ...` exits with code 100 *before* the `case` runs. The original `return 100` design is broken under the script's own pragma. Using a global is the simplest fix that keeps `set -e` semantics intact; it does not require disabling errexit around the loop, and it works under bash 3.2 (no `local -n` needed).

**Pseudocode (bash):**
```bash
declare -a tree_rows         # populated once from payload
PICKER_RESULT=               # "" or "attach"
PICKER_PROJECT=
PICKER_PARENT=

picker_loop() {
  local path="$1"
  while true; do
    build_rows_for "$path"     # populates PICKER_LINES, PICKER_KIND, PICKER_PAYLOAD
    pick_one                   # populates SELECTED_KIND, SELECTED_PAYLOAD; or sets SELECTED_KIND=cancel on Ctrl-C / empty input
    case "$SELECTED_KIND" in
      back)
        return 0 ;;                                  # caller: pop one frame
      folder)
        picker_loop "$SELECTED_PAYLOAD" ;;            # recurse into folder
      root_bucket)
        picker_loop ".root" ;;                        # recurse into synthetic root bucket
      project)
        PICKER_PARENT="$path"
        PICKER_PROJECT="$SELECTED_PAYLOAD"
        PICKER_RESULT=attach
        return 0 ;;
      new_project)
        local name
        name="$(prompt_new_project "$path")" || continue   # validation failure: re-loop at this level
        PICKER_PARENT="$path"
        PICKER_PROJECT="$name"
        PICKER_RESULT=attach
        return 0 ;;
      new_folder)
        prompt_new_folder "$path" || continue          # validation failure: re-loop at this level
        # On success, prompt_new_folder created the dir and re-walked the cache.
        # User stays at $path so they can drill into the new folder via the next picker render.
        continue ;;
      cancel)
        return 0 ;;                                    # empty input / Ctrl-C / Ctrl-D — exit cleanly
    esac

    # If a recursive call set PICKER_RESULT, unwind without re-rendering this level.
    [[ "${PICKER_RESULT:-}" == "attach" ]] && return 0
  done
}

picker_loop ""

if [[ "${PICKER_RESULT:-}" == "attach" ]]; then
  attach_session "$PICKER_PARENT" "$PICKER_PROJECT"
fi
```

The function recurses on folder selection and unwinds via the `PICKER_RESULT` global when the user picks (or creates) a project. The post-recursion guard `[[ "$PICKER_RESULT" == "attach" ]] && return 0` propagates the unwind through the call stack without relying on non-zero return codes that would clash with `set -e`. On macOS bash 3.2 the recursion depth is bounded by `-maxdepth 8` from the `find` invocation, so the call stack is small.

**PowerShell state:** identical structure using a `function Invoke-PickerLoop { param([string]$Path) ... }` recursive function. Return value is a discriminated object `@{ Action='attach'; Project=...; Parent=... }` or `$null` for back/cancel. PowerShell needs no global because exceptions/returns are not gated by `set -e` semantics; the discriminated-object form is the natural pwsh idiom and is preserved unchanged from the original plan.

### 3.4 Picker fallback parity

**bash `select`:** at depth 8 with 20 rows, `select` prints 20 numbered rows + `PS3` prompt. This stays usable but ugly. We accept it for v1 — fzf is the recommended path. The `select` rows include `1) [..  back]`, `2) work/  (3)`, …, `N) [new folder here]`, `N+1) [new project here]`. Total visible lines = (siblings in current dir) + 3 (back + new-folder + new-project) + possibly +1 for `(root)`.

**PowerShell `Read-Host`:** numbered menu with the same row order. At depth 8 with 20 rows, `Read-Host` prompts with the same number range. No paging; user scrolls in their terminal scrollback.

**Common rule (both fallbacks):** an empty input or Ctrl-D / Ctrl-C exits cleanly (parity with current `select` and `Read-Host` behavior).

---

## 4. File-by-file Changes

### 4.1 `bin/claudehome` (bash) — current ~310 lines, expected +160 lines

| Lines (current) | Change | Rationale |
|----------------|--------|-----------|
| **L163–192** (fetch picker data) | **Replace** the `RAW=...` capture block. New payload emits `---TREE---<rows>---TMUX---<sessions>` instead of plain `ls -1 ... ; ---TMUX--- ; tmux ls`. Both the local-mode branch (L171–178) and remote-mode branch (L179–191) get the new emitter. | Wire format change — see §3.1. |
| **L194–195** (split RAW on sentinel) | **Replace** with split-on-`---TREE---`-then-`---TMUX---`. Three blocks: pre-tree (empty / banner — discard), tree, tmux. | Two sentinels now. |
| **L197–238** (build picker rows) | **Delete** the existing flat row-build loop. **Add new** function `parse_tree_rows()` that fills four parallel arrays: `TREE_PATH[]`, `TREE_TYPE[]`, `TREE_CHILDREN[]`, `TREE_PARENT[]`. Compute `parent` for each row by trimming the last `/<name>` segment (or `""` at top level). **Enforce wire-format invariant**: each row's `path` is checked against `^([a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$` (with `.` synthetic root special-cased). Rows that don't match are dropped with a single deduped stderr warning per session. **Handle truncation sentinels**: if `---TRUNCATED---` appears, print stderr `"claudehome: tree truncated at 2000 entries — clean up your projects dir"`. If `---DEPTH-TRUNCATED---` appears, print stderr `"claudehome: tree depth >8 not shown — reorganize on the mini"`. Picker still runs; user sees a partial tree. | Single pass, O(N); enforces P6 invariant; surfaces P5 + R1 truncation diagnostics. |
| **(new, ~70 lines after L238)** | **Add** function `build_rows_for_path(path)` — filters `TREE_PATH[]` to those with `TREE_PARENT[i] == path`, sorts: folders alphabetical first, then projects active-first, then `(root)` bucket if (path == "" AND root has both types of children), then `[new folder here]`, then `[new project here]`. Adds a `[..  back]` row at index 0 if `path != ""` AND `path != ".root"`. Populates `PICKER_LINES[]`, `PICKER_KIND[]`, `PICKER_PAYLOAD[]` arrays. | Renders one drill level. |
| **(new, ~50 lines)** | **Add** function `picker_loop(path)` per pseudocode in §3.3. Calls `build_rows_for_path`, runs fzf/select (extracted from current L241–252 into a helper `pick_one()` that sets globals `SELECTED_KIND` and `SELECTED_PAYLOAD`), branches on `SELECTED_KIND`. **Critical: signaling is via the global `PICKER_RESULT` — *not* via non-zero return code, because `set -euo pipefail` at bin/claudehome:5 would abort the script before any `case "$?"` could read it.** After every recursive call, the loop checks `[[ "${PICKER_RESULT:-}" == "attach" ]] && return 0` to propagate unwind through nested frames. Top-level dispatcher reads `PICKER_RESULT`/`PICKER_PARENT`/`PICKER_PROJECT` and either calls `attach_session "$PICKER_PARENT" "$PICKER_PROJECT"` or exits 0 cleanly. | Drill-down state machine. |
| **L257–275** (new-project flow) | **Refactor** into two functions: `prompt_new_folder(parent_path)` and `prompt_new_project(parent_path)`. Validation is **basename-only**: each function reads a single token from the user, checks it against `^[a-zA-Z0-9._-]+$` (the slash `/` is *not* in the allowlist, so multi-level path entry is rejected at this gate). The full path passed to `mkdir -p` is reconstructed by concatenating already-validated basenames: `${PROJECTS_DIR}/${parent_path:+$parent_path/}${name}`. The new-folder version checks for sibling collisions (folder OR project at the same level — `TREE_PARENT[]` filter), then runs `mkdir -p` (remote or local), re-walks the tree, and returns to the same drill level so the user can pick the new folder on the next render. The new-project version checks **two** levels of uniqueness: (a) a sibling collision at the same level rejects with the literal string `"  '<name>' already exists at <parent>/<name>. Pick a different name."` (modeled on the existing `bin/claudehome:271` style), and (b) a global-tree scan that walks every `TREE_PATH[]` row of type `P` whose **basename** equals the new name; on collision, the literal stderr is `"  '<name>' already exists at <full-path>. Pick a different name."` — same wording, different `<full-path>` because the existing project lives elsewhere in the tree. AC-FT4 verification (§6) and §6's expected-string assertion both reference these exact strings. On success, `mkdir -p` and proceed to attach. | AC-FT2, AC-FT3, AC-FT4. |
| **L277** (`PROJECT="${SELECTED%%  *}"`) | **Move** into `build_rows_for_path` extraction; the loop now hands `picker_loop` the **full path** (e.g. `work/client-a/site`) for the chosen project, so basename extraction happens via `${path##*/}`. | Need both basename (for tmux session) and full path (for `mkdir`). |
| **L302–311** (attach branch) | **Modify** to consume `ATTACH_PATH` (parent dir) + `PROJECT` (basename). The remote attach payload becomes `mkdir -p ${PROJECTS_DIR}/${ATTACH_PATH}/${PROJECT}` (with `ATTACH_PATH` empty handled correctly — drop the trailing slash) and `tmux new-session ... -c ${PROJECTS_DIR}/${ATTACH_PATH}/${PROJECT}`. The session name remains `claudehome-${PROJECT}` (basename only — AC-FT3). | Folder is invisible at the tmux layer. |
| **L8–42** (`USAGE` here-doc) | **Update** the help text: add a one-line mention of folders ("Folders organize projects in a drill-down picker — pick `[new folder here]` to create one"). No new env vars, no new flags. Stay under the existing 35-line USAGE block. | AC-FT11. |

**Tree-walk emitter inside the remote `bash --norc --noprofile -c '...'`** (production version, replaces L181–185):

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 "${REMOTE_USER}@${HOST}" "LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bash --norc --noprofile -c '
  cd ${PROJECTS_DIR} 2>/dev/null || exit 0
  echo ---TREE---
  total=\$(find . -maxdepth 8 -type d ! -path \"*/.*\" 2>/dev/null | wc -l | tr -d \" \")
  deeper=\$(find . -mindepth 9 -type d ! -path \"*/.*\" 2>/dev/null | head -n 1)
  find . -maxdepth 8 -type d ! -path \"*/.*\" -print0 2>/dev/null \
    | awk -v RS=\"\\0\" -v ORS=\"\\0\" \"NR<=2000\" \
    | while IFS= read -r -d \"\" p; do
        rel=\"\${p#./}\"
        [ \"\$p\" = \".\" ] && rel=\".\"
        n_all=0; n_dirs=0
        for c in \"\$p\"/* \"\$p\"/.[!.]* \"\$p\"/..?* ; do
          [ -e \"\$c\" ] || continue
          n_all=\$(( n_all + 1 ))
          [ -d \"\$c\" ] && n_dirs=\$(( n_dirs + 1 ))
        done
        if [ \"\$rel\" = \".\" ]; then
          t=R
        elif [ \"\$n_all\" -gt 0 ] && [ \"\$n_all\" = \"\$n_dirs\" ]; then
          t=F
        else
          t=P
        fi
        printf \"%s\\t%s\\t%s\\n\" \"\$rel\" \"\$t\" \"\$n_all\"
      done
  [ \"\$total\" -gt 2000 ] && echo ---TRUNCATED---
  [ -n \"\$deeper\" ] && echo ---DEPTH-TRUNCATED---
  echo ---TMUX---
  tmux list-sessions -F \"#{session_name} #{session_activity}\" 2>/dev/null || true
'"
```

(Quoting note: this is interpolated inside the existing outer-double-quoted SSH command at bin/claudehome:181–185. All `$` that should reach the **remote** bash are escaped as `\$`. Allowlist-validated `${PROJECTS_DIR}` is spliced at the client. No new attack surface beyond what claudehome-pc-v1-plan.md ADR-PC-1 already documents.)

**Wire-format invariant — enforced, not assumed.** Names emitted via the walk are not pre-validated server-side; a pre-existing dir created via raw `mkdir $'has\ttab'` (or any name with TAB / `/` / control chars / our forbidden characters) would corrupt the line-based wire format. The picker creates names through the allowlist `^[a-zA-Z0-9._-]+$` (Spec "Folder naming & creation"), but existing-on-disk names are unconstrained. Therefore the **client-side parser** must enforce the invariant by post-filter: in `parse_tree_rows()` (bash) and `Build-RowsForPath` (pwsh), each `path` is matched against `^([a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$` (with the synthetic `.` root special-cased). Rows that don't match are silently dropped; a single stderr warning is printed once per session: `"claudehome: skipped 1 path with disallowed characters — rename on the mini to surface it"`. This converts the invariant from "assumed" to "enforced." Production emitter unchanged; filter lives client-side because the filter behavior must match parser semantics in two languages.

### 4.2 `bin/claudehome.ps1` (pwsh) — current ~234 lines, expected +130 lines

| Lines (current) | Change | Rationale |
|----------------|--------|-----------|
| **L84–104** (single-SSH fetch) | **Replace** the `$remoteDataTpl` here-string with the new tree-walk + tmux emitter (same as bin/claudehome §4.1, but inside the PS single-quoted here-string and with `__PROJECTS_DIR__` placeholder substitution that already exists at L94). | Same wire format as bash. |
| **L106–129** (parse RAW into sessions hashtable) | **Modify** to handle two sentinels: split `$raw` on `---TREE---` then on `---TMUX---`. Keep the existing tmux-block parser. Add a tree-block parser that fills three `List[object]` collections: `$treeRows` (each item `@{ Path; Type; Children; Parent }`). | Mirrors bash arrays. |
| **L131–163** (build picker rows) | **Delete** the flat-list builder. **Add** function `Build-RowsForPath { param($Path) ... }` returning a list of `@{ Line; Kind; Payload }` objects in the spec-mandated order. **Add** function `Pick-One { param($Lines) ... }` extracted from L165–186 (fzf-or-Read-Host). **Add** function `Invoke-PickerLoop { param($Path) ... }` returning `@{ Action='attach'; Project; ParentPath }` or `$null`. | PS port of bash drill machine. |
| **L188–208** (new-project flow) | **Refactor** into two functions: `New-Folder { param($ParentPath) }` and `New-Project { param($ParentPath) }`. Validation regex `$rxProj` already exists at L73; `$rxFolder` is the same value (allowed character set is identical — Spec "Folder naming & creation"). Sibling-collision check filters `$treeRows` by parent. Globally-unique check (project only) scans every `$treeRows` item with `Type='P'`. | AC-FT-PC2, AC-FT-PC3, AC-FT-PC4. |
| **L216–234** (attach payload) | **Modify** the `$attachTpl` here-string to include `__PARENT__` placeholder. `$attachCmd = $attachTpl.Replace('__PARENT__', $parentPath).Replace('__PROJECT__', $project).Replace('__PROJECTS_DIR__', $ProjectsDir)`. The `mkdir -p` and `tmux new-session -c` paths now incorporate `${PROJECTS_DIR}/${PARENT}/${PROJECT}` (with empty-parent handled by the template using a `${PARENT:+$PARENT/}` shell idiom inside the bash). Session name stays `claudehome-${PROJECT}`. | AC-FT-PC3 — folder invisible to tmux. |
| **L17–46** (help here-string) | **Update** mention of folders, parity with bash help text. Single line. | Consistency. |

**Picker depth and `Read-Host` fallback:** no special handling needed beyond what L172–186 already does. The existing numbered-menu rendering works for any number of rows.

### 4.3 `CLAUDE.md`

| Section | Change |
|---------|--------|
| "Architecture (one paragraph)" | **Append** one sentence: "The picker is a **drill-down** — top level shows folders first, then root projects (or a synthetic `(root)` bucket if both folders and root projects coexist). Folders are pure organization on disk; tmux session names remain `claudehome-<basename>` regardless of folder depth, so project names are globally unique across the tree." |
| "Development" → line counts | **Update** "(bash, ~310 lines)" → "(bash, ~470 lines)" and "(pwsh 7+, ~228 lines)" → "(pwsh 7+, ~360 lines)". Numbers are ranges; final commit will reconcile. |
| "Scope guardrails" | **No change** — folder-tree v1 introduces no new guardrails to enumerate; the existing "no state files / no daemons / no new env vars" lines all still hold. |
| "Windows PC — post-install verification" | **Append** AC-FT-PC1–AC-FT-PC10 to the existing AC-PC1–AC-PC9 checklist. Each new line names one AC and a one-sentence repro. |
| "Key docs" | **Add** two lines: `.omc/specs/deep-interview-claudehome-folder-tree-v1.md` and `.omc/plans/claudehome-folder-tree-v1-plan.md`. |
| Folder-vs-project surprise note | **Add** a one-line caveat under "Architecture": "A directory whose only child is `.git/` (no checked-out files) is classified as a folder by the heuristic; if you encounter this, add any file to make it a project, or revisit the rule per spec." |

### 4.4 Untouched files (explicit)

- `install_client.sh` — no installer prompt, no new env var. Unchanged.
- `install_client.ps1` — same.
- `install_server.sh` — local-mode tree-walk uses the same code path in `bin/claudehome`; nothing here changes. LaunchAgent plist unaffected.
- `~/.claudehomerc` format — no new keys (Spec "Configuration").
- `bin/claudehome.cmd` shim — unchanged.
- `LaunchAgents/com.${USER}.tmux-server.plist` — unchanged.
- `README.md` — **optionally** update the user-facing "How it works" line to mention drill-down; not strictly required (the plan does not block on README copy edits).

---

## 5. Implementation Phases

### Phase 1 — Wire format + tree walk (bash only, no UI change yet)

**Deliverable:** `bin/claudehome` emits and parses the new `---TREE---<rows>---TMUX---` payload. The picker still renders flat rows (root only) as today. This phase proves the wire format end-to-end without touching UX.

**Acceptance subset:** AC-FT12 (shellcheck), partial AC-FT1 (existing flat behavior unchanged with zero folders).

**Verification:**
- `shellcheck bin/claudehome install_client.sh install_server.sh` → 0 warnings.
- With existing 14 flat projects: `bin/claudehome --help` prints; `bin/claudehome` (manual run on user's machine) shows the same flat picker with `[active …]`/`[idle]` annotations.
- New unit-style check: a test fixture creates `tmp/projects/{a,b/c}` and runs the parser; the parser populates `TREE_PATH[]` with `(., a, b, b/c)` and types `(R, P, F, P)`.

### Phase 2 — Drill-down picker rendering on Mac

**Deliverable:** `bin/claudehome` renders folders + drill-down. `[..  back]`, `(root)` bucket logic, and folder-row formatting `work/  (5)` all work. `[new folder here]` and `[new project here]` rows appear at every level but selecting them shows a "not yet wired" stub. fzf-and-select parity.

**Acceptance subset:** AC-FT1, AC-FT5, AC-FT6, AC-FT7, AC-FT8, AC-FT10, AC-FT11.

**Verification:** see §7.

### Phase 3 — PC parity

**Deliverable:** `bin/claudehome.ps1` matches Phase 2 behavior. Same wire-format parsing, same picker rows, same drill state machine, fzf and `Read-Host` fallback.

**Acceptance subset:** AC-FT-PC1, AC-FT-PC5, AC-FT-PC6, AC-FT-PC7, AC-FT-PC8, AC-FT-PC10.

**Verification:**
- `Invoke-ScriptAnalyzer bin/claudehome.ps1, install_client.ps1` → 0 warnings.
- Manual: from PC, drill into a `work/client-a/` and verify rows match Mac.

### Phase 4 — `[new folder here]` / `[new project here]` at every level + globally-unique check

**Deliverable:** both client scripts wire up the creation prompts. `mkdir -p` runs at the correct path. Globally-unique check walks the entire `TREE_PATH[]` and cites the conflicting path on collision. Folder-creation drills into the new (empty) folder showing only `[..  back]`, `[new folder here]`, `[new project here]`.

**Acceptance subset:** AC-FT2, AC-FT3, AC-FT4, AC-FT9, AC-FT-PC2, AC-FT-PC3, AC-FT-PC4, AC-FT-PC9, AC-FT-LOCAL1, AC-FT-LOCAL2.

**Verification:** see §7.

---

## 6. AC Mapping Table

Each AC maps to: phase, file:lines (anticipated, post-implementation), and verification method.

| AC | Phase | Implementation site | Verification |
|----|-------|--------------------|--------------|
| **AC-FT1** | 1+2 | `bin/claudehome:194..` (parser) + drill loop | Manual: with 14 flat projects, run `bin/claudehome`; picker shows flat list, no folder rows, no `(root)` bucket. |
| **AC-FT2** | 4 | `bin/claudehome` `prompt_new_folder()` + tree re-walk | Manual: at root, pick `[new folder here]`, name `work`, validate prompt rejects `work@!#`, on success drill auto-enters empty `work/` showing 3 rows. |
| **AC-FT3** | 4 | `bin/claudehome` attach branch (post-L302) | Manual: from inside `work/`, pick `[new project here]`, name `site`. Verify: `mkdir -p ~/projects/claudehome-projects/work/site` ran on mini; `tmux ls` shows session `claudehome-site` (not `claudehome-work-site`). |
| **AC-FT4** | 4 | `bin/claudehome` `prompt_new_project()` global-unique scan | Manual: pre-create `work/site`. From `personal/`, pick `[new project here]`, name `site`. Error must be the literal string `"  'site' already exists at work/site. Pick a different name."` (two leading spaces, single quotes around the name, full path of the existing project, period-then-sentence error suffix). Re-prompt. |
| **AC-FT5** | 2 | `bin/claudehome` `picker_loop()` recursion + `[..  back]` row | Manual: drill into `work/`, see `[..  back]` at top; pick it; back at root. |
| **AC-FT6** | 2 | `bin/claudehome` `build_rows_for_path("")` `(root)` synthesis | Manual: create one folder + leave a flat project. Run picker; see folders + `(root)  (N)` row. Drill into `(root)`; see flat projects with `[active …]`/`[idle]`. |
| **AC-FT7** | 2 | `bin/claudehome` `build_rows_for_path()` ordering | Manual: at root with mixed content, observe order: folders alphabetical → projects active-then-idle → `(root)` (if applicable) → `[new folder here]` → `[new project here]`. At depth ≥ 1, `[..  back]` is row 1. |
| **AC-FT8** | 2 | `bin/claudehome` `build_rows_for_path()` lookup of `claudehome-<basename>` in `$sessions` | Manual: with `claudehome-site` running, drill into `work/client-a/`, observe `site  [active 5h ago]`. |
| **AC-FT9** | 4 | `bin/claudehome` `prompt_new_folder()` regex check | Manual: `[new folder here]`, name `bad name!`, observe rejection + re-prompt. |
| **AC-FT10** | 2 | `bin/claudehome` `parse_tree_rows()` keeps zero-child folder rows | Manual: mkdir an empty `empty/` on mini, run picker, observe `empty/  (0)`. Drill in; see only `[..  back]`, `[new folder here]`, `[new project here]`. |
| **AC-FT11** | 2 | `bin/claudehome:8–42` (USAGE) — no flag added | Automated: (1) `bin/claudehome --help; echo $?` → exits 0, prints USAGE block. (2) `bin/claudehome -h; echo $?` → exits 0, prints USAGE block. (3) `bin/claudehome ls 2>&1; echo $?` — the current `bin/claudehome:8` matches *only* `^(-h\|--help)$`; any other argument falls through to picker logic. Therefore the assertion is: under a normal config (`CLAUDEHOME_HOST` set, host reachable), `claudehome ls` reaches the picker and behaves as bare `claudehome` (the `ls` arg is silently ignored — current behavior, preserved). Under a broken config (no host), it exits non-zero with the same validation error path bare `claudehome` would emit. **Preserve current behavior; do not add subcommand handling.** |
| **AC-FT12** | 1 | All bash files | Automated: `shellcheck bin/claudehome install_client.sh install_server.sh` → 0 warnings. |
| **AC-FT-PC1** | 3 | `bin/claudehome.ps1` flat-rendering branch | Manual: with 14 flat projects, run `claudehome` from pwsh; observe flat list parity with Mac. |
| **AC-FT-PC2** | 4 | `bin/claudehome.ps1` `New-Folder` | Manual: same as AC-FT2 from pwsh. |
| **AC-FT-PC3** | 4 | `bin/claudehome.ps1` `New-Project` + `$attachCmd` | Manual: same as AC-FT3 from pwsh. Verify session name has no path encoding. |
| **AC-FT-PC4** | 4 | `bin/claudehome.ps1` `New-Project` global-unique scan | Manual: same as AC-FT4 from pwsh. |
| **AC-FT-PC5** | 3 | `bin/claudehome.ps1:165–186` fzf-or-Read-Host, drill loop | Manual: drill into a folder via fzf; remove fzf from PATH; drill again via Read-Host menu. |
| **AC-FT-PC6** | 3 | `bin/claudehome.ps1` `Build-RowsForPath` | Manual: drill into `work/`, observe row 1 = `[..  back]`. |
| **AC-FT-PC7** | 3 | `bin/claudehome.ps1` session lookup | Manual: same as AC-FT8 from pwsh. |
| **AC-FT-PC8** | 3 | `bin/claudehome.ps1` row ordering | Manual: same as AC-FT7 from pwsh. |
| **AC-FT-PC9** | 4 | `bin/claudehome.ps1` attach branch | Manual: from Mac, attach to a project under `work/client-a/`. From PC, drill to the same project and pick it. Both clients live-share the tmux session (parent AC-PC6 still holds because `-D` is not passed). |
| **AC-FT-PC10** | 3 | `bin/claudehome.ps1`, `install_client.ps1` | Automated: `Invoke-ScriptAnalyzer bin/claudehome.ps1, install_client.ps1` → 0 warnings. |
| **AC-FT-LOCAL1** | 4 | `bin/claudehome:171–178` local-mode branch | Manual on the mini: `CLAUDEHOME_LOCAL=1 claudehome` walks the local tree and drills. Time it on a 1000-entry test tree: subsecond. |
| **AC-FT-LOCAL2** | 4 | Same code path as AC-FT-LOCAL1 | Manual: SSH from iPhone (Termius/Blink) to the mini, run `claudehome`; drill-down works. |

**Testability summary:** 22 of 24 ACs map to a concrete manual repro or automated command. AC-FT5 / AC-FT-PC6 share fixture setup with AC-FT2 / AC-FT-PC2. All ACs have an observable.

---

## 7. Risks & Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| **R1** | Tree-walk emits 10K rows on a malformed/oversized projects dir → SSH payload bloats and parse is slow | Medium | High | Hard cap: `awk -v RS='\0' -v ORS='\0' 'NR<=2000'` after `find ... -print0` (the `head -z` form is GNU-only and rejected by macOS BSD `head`; bare `awk 'NR<=2000'` is also wrong because awk's default `RS='\n'` consumes the entire NUL-stream as one record). The emitter counts `total = find ... \| wc -l` *before* the truncating awk, then prints `---TRUNCATED---` if `total > 2000`. The client surfaces stderr `"claudehome: tree truncated at 2000 entries — clean up your projects dir"`. Cap chosen because 2000 dirs at avg 30 chars/path = ~60KB payload, well under any SSH/MTU limits. |
| **R2** | bash `select` and PowerShell `Read-Host` become unusable at depth 8 with many siblings | Low | Medium | Numbered menu always works (no paging needed for ≤200 rows; if > 200, the user's terminal scrollback is the UI). Document fzf as the recommended path in CLAUDE.md (already done). No code mitigation — accepted scope per spec "Picker UX". |
| **R3** | Folder-vs-project heuristic surprises user (e.g., dir with only `.git/` classified as folder), or a tree deeper than 8 levels exists silently | Medium | Low | Heuristic surprise: documented in CLAUDE.md (§4.3). Spec explicitly says "revisit if it produces surprises." User workaround: `touch foo/.claudehome-project` (or any file) flips it back to project. Depth: `-maxdepth 8` is the cap; the emitter runs a separate `find . -mindepth 9 -type d \| head -n 1` probe — if non-empty, prints `---DEPTH-TRUNCATED---`. Client surfaces stderr `"claudehome: tree depth >8 not shown — reorganize on the mini"`. AC-FT5 verification includes a depth-9 fixture. |
| **R4** | TOCTOU between fetch and create: another client creates `personal/site` while client B already has `work/site`; client A's `tmux new-session -A -s claudehome-site` ATTACHES to client B's existing session in `work/site` because tmux session naming is basename-only | Low | Medium | The TOCTOU window is small (the round-trip latency between fetch and the user typing a name and pressing Enter). On race, the second client *does* create its directory (`mkdir -p` is idempotent), but the tmux-attach uses the basename `claudehome-<name>`, which now collides with the first client's existing session. Result: two clients converge on a single tmux session via name collision — confusing but **not destructive**, and self-recoverable (one user closes their pane, the other rms the duplicate dir). v1 accepts this risk; could be tightened in v1.1 by re-checking on the mini inside the create payload (`if [ -e ~/.../site ]; then echo dup; exit 1; fi` before `mkdir`). Revisit if reported. **This rewrite supersedes the earlier "benign no-op" framing — the actual failure mode is silent shared-session, not no-op.** |
| **R5** | Quoting bug in the new bash payload — escaped `\$` inside the SSH outer-double-quoted string is fragile | Medium | High | shellcheck does **not** lint remote payloads (the payload is an opaque string to the local script). Mitigation: in Phase 1, capture the rendered SSH command via `set -x` snapshot, save to `tests/fixtures/remote-payload.expected.sh`, and add a verification step (§8) that diffs the next render against the fixture. Any intentional change requires updating the fixture in the same commit. The `find ... \| while read` pattern is already used in bin/claudehome (e.g., L113) so the escape conventions are well-established, but they remain fragile across edits — the fixture is the test-of-record. |
| **R6** | New folder name with sibling collision against a project at the same level (e.g., creating `site/` next to `site` project) — rule says reject; implementation must check **both** `TREE_TYPE='F'` and `'P'` when computing siblings | Medium | Medium | Test fixture in Phase 4 verification: try to create `site/` folder when a `site` project already exists at the same level. Expect rejection with the literal sibling-collision error string from §4.1. Cited in spec "Folder naming & creation". |
| **R7** | PowerShell parses TAB-delimited rows differently if the wrong split idiom is used | Low | Medium | Use `-split "`t"` (backtick-t inside double quotes — PowerShell's TAB escape sequence in interpolated strings) for a TAB-literal split. Avoid `-split '\t'` because the regex form depends on .NET regex behavior and could silently match other whitespace under non-default cultures or future .NET regex changes. The TAB-literal form is unambiguous. Validated by a Phase 3 manual check: emit a test row containing a TAB and assert `-split "`t"` yields exactly the expected fields. |
| **R8** | iPhone (Termius/Blink) terminal does not render the deeper `Read-Host` numbered menus well (small screen, many rows) | Medium | Low | iPhone use case is local-mode SSH'd into mini; user can install fzf on the mini (`brew install fzf`) which already works in iPhone SSH apps. Documented in CLAUDE.md / README. AC-FT-LOCAL2 verifies it works at all; UX polish is deferred. |

All risks have a concrete mitigation; none rely on "be careful." R1, R3, R5, R6 have explicit Phase verification steps.

---

## 8. Verification

### 8.1 Static checks (Phase 1 + Phase 3)

```
shellcheck bin/claudehome install_client.sh install_server.sh
Invoke-ScriptAnalyzer -Path bin/claudehome.ps1, install_client.ps1 -Severity Warning,Error
bin/claudehome --help > /dev/null && echo OK    # AC-FT11
pwsh -NoProfile -File bin/claudehome.ps1 --help > $null; if ($LASTEXITCODE -ne 0) { Write-Error "help failed" }
```

### 8.2 Wire-format check (Phase 1)

Manual on the mini (or local mode):

```
mkdir -p /tmp/ct/{a,b/c,empty}
touch /tmp/ct/a/file.txt          # makes 'a' a project
CLAUDEHOME_LOCAL=1 CLAUDEHOME_PROJECTS_DIR=/tmp/ct bin/claudehome
# Inspect emitted payload via temporary `set -x` instrumentation:
#   ---TREE---
#   .	R	3
#   a	P	1
#   b	F	1
#   b/c	P	0
#   empty	P	0
#   ---TMUX---
```

Acceptable variation: the ordering of rows from `find` may not be deterministic across filesystems; the parser sorts after parsing.

**Empty `PROJECTS_DIR` case (P12):**
```
mkdir -p /tmp/ct-empty
CLAUDEHOME_LOCAL=1 CLAUDEHOME_PROJECTS_DIR=/tmp/ct-empty bin/claudehome
# Expect: payload contains exactly the synthetic `.\tR\t0` row, then `---TMUX---`.
# Picker renders only `[new folder here]` and `[new project here]` rows (no `[..  back]`, no `(root)`).
```

**Disallowed-on-disk name (P6 enforcement):**
```
mkdir -p /tmp/ct-bad
mkdir -p "/tmp/ct-bad/$(printf 'has\ttab')"   # raw mkdir bypasses our allowlist
mkdir -p /tmp/ct-bad/normal
CLAUDEHOME_LOCAL=1 CLAUDEHOME_PROJECTS_DIR=/tmp/ct-bad bin/claudehome 2>warn.log
# Expect: stderr warn.log contains 'skipped 1 path with disallowed characters'.
# Picker shows only 'normal' (the bad-name dir is filtered).
```

### 8.3 Drill-down UX (Phase 2 + Phase 3)

Manual repro for each of AC-FT1, AC-FT5, AC-FT6, AC-FT7, AC-FT8, AC-FT10. See §6 mapping table for the exact step list per AC. PC parity (AC-FT-PC1, PC5–PC8) repeats from pwsh.

### 8.4 Creation flows (Phase 4)

Manual repro for AC-FT2, AC-FT3, AC-FT4, AC-FT9 (Mac) and AC-FT-PC2, PC3, PC4, PC9 (PC). Each test creates a folder or project at a non-root drill level.

### 8.5 Local mode (Phase 4)

```
# On the mini:
CLAUDEHOME_LOCAL=1 claudehome
# Drill into work/, pick [new project here], name 'localtest'.
# Expect: mkdir -p ~/projects/claudehome-projects/work/localtest happens locally; tmux session 'claudehome-localtest' starts; claude prompt appears.

# From iPhone Termius/Blink, SSH'd into the mini:
claudehome
# Same UX.
```

### 8.6 Performance (R1 + AC-FT-LOCAL1)

```
# Generate a 1000-entry test tree on the mini:
mkdir -p /tmp/perf-ct
for i in $(seq 1 100); do
  for j in $(seq 1 10); do
    mkdir -p /tmp/perf-ct/dir$i/proj$j
    touch /tmp/perf-ct/dir$i/proj$j/file.txt
  done
done
time CLAUDEHOME_LOCAL=1 CLAUDEHOME_PROJECTS_DIR=/tmp/perf-ct bin/claudehome --help  # warmup
# Real test: drill once and time the picker render.
# Expectation: subsecond on the mini's hardware.
```

### 8.7 Truncation (R1 + R3)

**Row-count truncation:**
```
# Generate >2000 dirs:
for i in $(seq 1 2200); do mkdir -p /tmp/big/dir$i; done
CLAUDEHOME_LOCAL=1 CLAUDEHOME_PROJECTS_DIR=/tmp/big bin/claudehome 2>warn.log
# Expect: payload contains the `---TRUNCATED---` sentinel between the last row and `---TMUX---`.
# stderr warn.log contains: 'tree truncated at 2000 entries — clean up your projects dir'.
# Picker still works; some entries missing; user warned.
```

**Depth truncation (P5 + R3):**
```
# Build a 9-deep chain:
mkdir -p /tmp/depth/d1/d2/d3/d4/d5/d6/d7/d8/d9
CLAUDEHOME_LOCAL=1 CLAUDEHOME_PROJECTS_DIR=/tmp/depth bin/claudehome 2>warn.log
# Expect: payload contains the `---DEPTH-TRUNCATED---` sentinel.
# stderr warn.log contains: 'tree depth >8 not shown — reorganize on the mini'.
# Picker drills d1..d8; d9 is invisible.
```

### 8.8 Remote-payload fixture diff (R5)

In Phase 1, render the SSH command via temporary `set -x` instrumentation in `bin/claudehome`, capture to `tests/fixtures/remote-payload.expected.sh` (committed to repo). On every subsequent edit to the SSH payload, the test re-renders and `diff`s against the fixture:

```
# In Phase 1, one-time:
set -x; bin/claudehome 2> /tmp/render.log; set +x
grep '^+ ssh' /tmp/render.log > tests/fixtures/remote-payload.expected.sh
git add tests/fixtures/remote-payload.expected.sh

# Regression check (any phase):
set -x; bin/claudehome 2> /tmp/render.log; set +x
grep '^+ ssh' /tmp/render.log | diff - tests/fixtures/remote-payload.expected.sh
# Expect: empty diff. Any change to the payload requires updating the fixture in the same commit.
```

This is the only verification of the remote-payload escape correctness; shellcheck does not lint remote payloads.

---

## 9. Out of Scope (explicit, restated from spec for reviewer challenge)

The following are **not** in this plan and must not be added during execution:

- **Tagging or virtual folders.** A project lives in exactly one place on disk.
- **Path-encoded session names.** Tmux session names stay `claudehome-<basename>`.
- **Per-folder uniqueness.** Globally unique only.
- **Configurable separator / new env var / new config key.** None.
- **`mv` / rename / delete from the picker.** Picker is read-mostly + create-only.
- **Tree picker with indentation in one screen** (e.g. `fzf --preview` tree). Drill-down only.
- **Auto-cleanup of empty folders.** Empty folders persist; user removes manually.
- **Subcommands beyond `--help`** (`claudehome ls --tree`, `claudehome new <path>`, `claudehome mkdir`). CLI surface stays at `claudehome` / `claudehome --help`.
- **Installer changes.** No new prompt, no new key in `~/.claudehomerc`, no new env var advertisement.
- **Daemons / state files / `.claudehome/folders.json`.** None.
- **iPhone / web client.** Out of scope as per CLAUDE.md scope guardrails.

---

## 10. Handoff Notes for Architect / Critic

- Plan executes in 4 phases; all phases except Phase 4 are independently shippable but the spec is delivered only at the end of Phase 4.
- **Phase 1 and Phase 2 must ship together (P13).** Phase 1 alone (new wire format, picker still flat) leaves the parser parsing tree rows but rendering them as a flat list — confusing to ship as an interim release. Phase 2 alone is impossible (relies on Phase 1's payload). Single PR for both, deployed atomically. Phase 3 (PC parity) and Phase 4 (creation flows) are each independently deployable on top of a shipped Phase 1+2.
- **File creation order during execution:** (1) `bin/claudehome` Phase 1+2 changes (one PR), (2) `bin/claudehome.ps1` Phase 3 mirror, (3) `bin/claudehome` Phase 4 creation flows, (4) `bin/claudehome.ps1` Phase 4 mirror, (5) `CLAUDE.md` updates last (verifies post-impl line counts).
- All Phase 1+ static checks (shellcheck, PSScriptAnalyzer, `--help` exit codes) are headlessly verifiable by autopilot. All other ACs are manual on user hardware.
- Phase 4 verification subset (Spec AC-FT-LOCAL1, AC-FT-LOCAL2) require the mini hardware; defer to user with a checklist.
- The plan does not add any new external dependency. `find`, `tmux`, `ssh`, `mkdir`, `awk` are all already available everywhere claudehome runs today. Note: `head -z` is GNU-only and is **not** used (replaced by `awk -v RS='\0' -v ORS='\0' 'NR<=2000'`); the `head` binary itself is still relied on for `head -n 1` in the `deeper` probe, which is portable.
- **Path-vs-basename revalidation (P15):** the existing project-name allowlist is `^[a-zA-Z0-9._-]+$` (no `/`). The picker therefore validates **basenames only** at the prompt; paths reach `mkdir -p` by concatenating already-validated basenames (`${PROJECTS_DIR}/${parent_path:+$parent_path/}${name}`). This means a user cannot type `work/site` into the new-project prompt and expect it to work — the prompt rejects the `/`. To create a project under `work/`, the user must drill into `work/` first, then pick `[new project here]`. This is intentional and matches spec "Folder naming & creation".
- **Synthetic-root sentinel consistency (P16):** the in-memory representation uses `".root"` (literal four-character string) as the path passed to `picker_loop` when the user picks the `(root)` bucket. The wire-format `path` field for the root row is `"."` (single dot, see §3.1). The parser maps `"."` → `".root"` for internal use to avoid confusing `.` with "current directory" in array lookups. Every `picker_loop` call site uses `".root"`; the wire format always uses `"."`. **Replaces the earlier inconsistent use of both `.root` and `""` in §3.3 pseudocode.**
- **Option B latency note (P14):** the rejection of Option B (per-level SSH) holds because of *write-path* latency on `[new project here]` — the globally-unique check would need an additional SSH call before each create, which is genuinely awful UX. The *read-path* latency of "+200-300ms per drill" is barely user-perceivable on Tailscale with `ControlPersist`, so that argument alone would not be decisive. The decisive argument is the write-path round-trip explosion. (This refines but does not invalidate the earlier ADR rationale.)

---

## 11. Open Questions

*(Persisted to `.omc/plans/open-questions.md` by the planner.)*

### Open

- **OQ-1:** When the heuristic classifies a `.git`-only directory as a folder (not a project), should we override with a special-case rule (`if .git is the only child, treat as project`)? Spec says "revisit if it produces surprises." Defer to first user report. — Why it matters: would silently break drilling into solo-git repos, which is uncommon but possible.

### Resolved (Iteration 2)

- **OQ-2 (RESOLVED):** `head -z -n 2000` portability across macOS BSD `head`. **Resolution:** macOS BSD `head` rejects `-z` outright (`head: invalid option -- z`). The plan now uses `awk -v RS='\0' -v ORS='\0' 'NR<=2000'` everywhere, which is portable across macOS bash 3.2 / GNU / BSD environments. The bare `awk 'NR<=2000'` form is also wrong (default `RS='\n'` consumes the entire NUL-stream as one record), so the explicit `-v RS='\0' -v ORS='\0'` flags are mandatory. Applied at §3.1 emitter sample, §3.1 emitter prose, §3.2 find invocation, §4.1 production emitter, R1 mitigation. No longer blocks Phase 1.

---

## Iteration 2 Changelog

This section documents which Critic-flagged patches landed in iteration 2 of the ralplan consensus loop.

### Critical patches (P1–P4) — all four landed

- **P1 (BSD `head -z` portability).** Replaced `head -z -n 2000` with `awk -v RS='\0' -v ORS='\0' 'NR<=2000'` at: §3.1 emitter sample (line 156), §3.1 emitter prose, §3.2 find-invocation block (line 203), §4.1 production emitter (line ~284), R1 mitigation. OQ-2 moved from "Open" to "Resolved" with the canonical form documented.
- **P2 (BSD `find -not -L` rejection).** Removed `-not -L` from §3.2 find invocation and §4.1 production emitter. Replaced with the BSD-portable `!` operator. Updated §3.2 symlink-row to clarify that BSD `find` default behavior already does not follow symlinks (no `-L` global option passed); the symlink case is omitted by default. Switched `-not -path` → `! -path` for consistency.
- **P3 (BIGGEST FIX: `return 100` sentinel under `set -euo pipefail`).** Rewrote the §3.3 state machine to use globals (`PICKER_RESULT`, `PICKER_PROJECT`, `PICKER_PARENT`) instead of non-zero return codes. Documented why: under `errexit`, any non-zero return from a bare function call aborts the script before a `case "$?"` can read it. Added "Why a global instead of a sentinel return code" subsection citing the empirical verification. Updated §4.1 picker_loop description to match. PowerShell side unchanged (discriminated-object form was already correct).
- **P4 (`---TRUNCATED---` emission).** Wired truncation-counting into the emitter at §3.1 sample and §4.1 production version: `total=$(find ... \| wc -l)` runs *before* the truncating awk; `[ "$total" -gt 2000 ] && echo ---TRUNCATED---` runs *after*. Parser handling specified in §4.1 (parse_tree_rows row): on sentinel detection, print stderr `"claudehome: tree truncated at 2000 entries — clean up your projects dir"`. §8.7 verification updated to assert the sentinel byte-for-byte.

### Major patches (P5–P11) — all seven landed

- **P5 (depth policy visibility).** Bumped `-maxdepth 5` → `-maxdepth 8` everywhere. Added `---DEPTH-TRUNCATED---` sentinel emission in §3.1 + §4.1 emitters; added `deeper=$(find . -mindepth 9 ...)` probe before the walk. Parser surfaces stderr warning. §8.7 verification adds depth-9 fixture test. ADR Consequences updated implicitly via §3.2 prose.
- **P6 (post-filter wire-format invariant).** Added new "Wire-format invariant — enforced, not assumed" subsection after §4.1 emitter. Specifies that `parse_tree_rows()` (bash) and `Build-RowsForPath` (pwsh) check each path against `^([a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$` and silently drop non-matching rows with a deduped stderr warning. §8.2 adds disallowed-on-disk verification.
- **P7 (PowerShell `-split "`t"`).** Rewrote R7 mitigation to recommend `-split "`t"` (backtick-t inside double quotes — PowerShell's TAB escape) instead of `-split '\t'`. Removed the unsupported PSScriptAnalyzer claim. Added Phase 3 manual verification: emit a test row with TAB and assert split yields expected fields.
- **P8 (R4 TOCTOU honesty).** Rewrote R4 from "benign no-op" to the actual failure mode: the second client *creates* its directory but `tmux new-session -A -s claudehome-<name>` then attaches to the first client's *existing* session in a different tree location. Result: silent shared-session via name collision. v1 accepts the risk; v1.1 mitigation noted (server-side `if [ -e ... ]` check inside the create payload).
- **P9 (AC-FT4 error wording pinned).** Updated §4.1 prompt_new_project description and §6 AC-FT4 row to both quote the exact literal error string: `"  '<name>' already exists at <full-path>. Pick a different name."` (two leading spaces, single quotes around name, period-then-sentence error suffix). Modeled on existing `bin/claudehome:271` style.
- **P10 (AC-FT11 testable).** Replaced "exits with usage error or proceeds to picker" with three concrete sub-assertions: `--help` → exit 0 + USAGE; `-h` → exit 0 + USAGE; `claudehome ls` → falls through to picker (current behavior preserved; `bin/claudehome:8` only matches `^(-h\|--help)$`, all other args ignored). Verified against current source.
- **P11 (R5 fixture-diff).** Replaced "shellcheck will catch most issues" (false — shellcheck doesn't lint remote payloads) with a real verification step §8.8: capture rendered SSH command via `set -x`, save to `tests/fixtures/remote-payload.expected.sh`, diff on every change.

### Nice-to-haves (P12–P16) — all five landed

- **P12 (empty PROJECTS_DIR).** Added §8.2 sub-test verifying empty-dir case emits only the `.\tR\t0` row + `---TMUX---`.
- **P13 (Phase 1+2 ship together).** Added explicit note in §10 Handoff: "Phase 1 and Phase 2 must ship together (single PR, deployed atomically)." Phase 3 and Phase 4 remain independently deployable.
- **P14 (Option B rejection nuance).** Added §10 note acknowledging that "+200-300ms per drill" alone would not be decisive on Tailscale with ControlPersist; the decisive rejection argument is *write-path* latency on `[new project here]` (extra SSH for global-unique check). ADR rationale refined, not invalidated.
- **P15 (path-vs-basename revalidation).** Clarified in §10 that the new-project / new-folder prompts validate **basenames only** (the existing `^[a-zA-Z0-9._-]+$` allowlist forbids `/`); full paths are reconstructed by concatenating already-validated basenames. Users cannot type `work/site` into the prompt — they must drill first.
- **P16 (`(root)` sentinel consistency).** Resolved in §10: in-memory uses `".root"` (literal); wire format uses `"."` (single dot). Parser maps `"."` → `".root"` for internal lookup. Replaces the earlier `.root`/`""` inconsistency in §3.3 pseudocode.

### What did not change (preserved per instructions)

- Overall architecture (single SSH payload, drill-down, server-side classification) — sound.
- Wire format `---TREE---<rows>---TMUX---<sessions>` — fine; invariant now enforced (P6) not assumed.
- Phasing (Phase 1 walk → Phase 2 picker → Phase 3 PC parity → Phase 4 creation flows) — correct; only added P13 ship-together note.
- ADR Decision/Drivers/Alternatives/Why-chosen — preserved. Consequences will be augmented organically by the depth-cap discussion in §3.2.
