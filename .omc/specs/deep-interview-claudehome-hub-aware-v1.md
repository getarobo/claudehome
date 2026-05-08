# Deep Interview Spec: claudehome hub-aware v1

## Metadata
- Interview ID: ch-hubaware-2026-05-08
- Rounds: N/A — derived from a finalized human-readable plan (`~/.claude/plans/ok-this-is-will-moonlit-teacup.md`) iterated across ~15 user-driven refinements rather than via deep-interview rounds. Round-by-round transcript is in the conversation that produced the plan file.
- Final Ambiguity Score: not measured
- Type: brownfield
- Generated: 2026-05-08
- Status: PROPOSED
- Builds on: `deep-interview-claudehome-folder-tree-v1.md` (Mac AC-FT1–FT12, PC AC-FT-PC1–PC10, local AC-FT-LOCAL1–2) and the v1 + pc-v1 specs it extends.

## Goal

Extend claudehome's `[new project here]` flow so that when the new project's parent directory contains a sibling whose basename ends in `_hub`, the flow ALSO writes hub scaffolding for the new project: a `CLAUDE.md` with an `@`-import of the hub's README, an appended row in `<sibling>_hub/projects.md`, and `git init` in the new project's directory.

This is the claudehome-side piece of a larger "masterplan workspace" pattern (e.g. `gene-mini_pjt/gene-mini_hub/`) where one `*_hub` repo serves as docs/registry for sibling member repos that all `@`-import its README. The picker behavior itself is unchanged from folder-tree v1; only `[new project here]` gets richer side effects.

## Constraints

### Hub detection
- After `[new project here]` creates `<parent_path>/<new-project>/`, scan `<parent_path>` for **any sibling directory whose basename ends in `_hub`** via a shell glob (`<parent_path>/*_hub`).
- **Zero matches** → behave exactly as today (folder + tmux). This is the case at the root of `CLAUDEHOME_PROJECTS_DIR` and in any folder that's not a `*_pjt`-style group.
- **One match** → trigger the three hub-aware writes below.
- **Two or more matches** (unsupported) → print warning to stderr `claudehome: multiple *_hub siblings found in <parent>; skipping hub-aware writes` and behave as today. Multi-hub support is explicitly deferred.

### The three hub-aware writes (in order)

1. **`git init`** in the new project directory (`<parent_path>/<new-project>/`). Output suppressed; failures warn but do not abort.
2. **Write `<new-project>/CLAUDE.md`** containing exactly:
   ```
   # <new-project>

   @<hub_absolute_path>/README.md

   <description>
   ```
   - `<hub_absolute_path>` is **computed at write time** from the detected `*_hub` sibling — its absolute path on the mini, NOT a hardcoded string.
   - `<description>` is the result of a new description prompt (see below). Empty input → placeholder string `<one-line description goes here>`.
3. **Append a row to `<hub_absolute_path>/projects.md`** of the form:
   ```
   | <new-project> | <description> | active | — | — |
   ```
   - Append goes at the bottom of the existing `projects.md`.
   - If `projects.md` is missing or zero bytes, warn `claudehome: <hub>/projects.md missing or empty; row not appended` and skip ONLY this step. The hub author is expected to maintain the file's table header.

### Order of operations
- Folder creation (existing AC-FT3 / AC-FT-PC3) happens FIRST.
- Three hub-aware writes happen NEXT, in the order above.
- Tmux attach (existing AC-FT3 / AC-FT-PC3) happens LAST.

### Description prompt
- After the existing project-name prompt, AND after hub detection has confirmed a single `*_hub` sibling, prompt: `One-line description (optional): `.
- Empty input is allowed → use placeholder `<one-line description goes here>`.
- Single-line only; reject embedded newlines (re-prompt with `claudehome: description must be single-line`).
- Pipe character `|` in the description must be escaped as `\|` ONLY in the `projects.md` row (to preserve table integrity); the `CLAUDE.md` body keeps it literal.

### Single SSH round-trip preserved
- Hub-aware writes happen on the mini, in the **same SSH session** that created the folder. No second round-trip. Mirrors folder-tree v1 ADR.
- For local mode (`CLAUDEHOME_LOCAL=1`), all writes happen locally. Same code path.

### Mac + PC parity
- Both `bin/claudehome` (bash) and `bin/claudehome.ps1` (pwsh 7+) implement the same hub-aware writes. Same hub-detection glob, same write order, same skip-on-multi-hub behavior, same description prompt, same warning text.
- `bin/claudehome.cmd` shim is unchanged.

### Allowlist hygiene
- New interpolated values (`<new-project>`, `<description>`) follow folder-tree v1's allowlist-before-interpolation rule.
  - `<new-project>` is already validated by AC-FT3 / AC-FT-PC3 (existing `[a-zA-Z0-9._-]` allowlist).
  - `<description>` content: shell-quote on the bash side (`<<'EOF'` heredoc with quoted delimiter, value passed via stdin, NOT positional argument). Single-quote escape on the pwsh side.

### Idempotency / partial failure
- Re-creating a project with the same name is already forbidden globally (AC-FT4); the hub-aware writes therefore never run on re-create.
- If any of the three writes fails (e.g. `git init` succeeds but `CLAUDE.md` write fails on permissions), do NOT roll back. Print a warning per failed step and continue. The new project's tmux session still attaches.

## Non-Goals

- **Hub creation from the picker.** No `[new hub here]` row. Hubs are created manually by the user.
- **Service registration / consumer registration / ADR authoring.** These remain manual edits to the relevant hub files. They don't fit the picker flow.
- **Multi-hub support.** A `*_pjt` group has at most one `*_hub`. Multi-hub is explicitly skipped (warn + continue).
- **Validating that the hub is well-formed.** No check that `<hub>/README.md` exists, that the `@`-import resolves, or that `projects.md` has the right header. Those are documentation-health concerns, not picker concerns.
- **Generic "scaffolding pluggability".** The three writes are hardcoded. No `<hub>/.scaffolding.sh`, no extension point.
- **Backporting to non-`_hub` siblings.** Detection is strictly suffix-based (`*_hub`). No marker file fallback, no `.scaffolding.json`, no other naming convention recognized.
- **Migration of existing flat projects into hub-aware structure.** Existing projects (claudehome's 14 flat projects in folder-tree v1) are unaffected. Only new projects created via `[new project here]` get hub-aware writes.

## Acceptance Criteria

These extend the existing AC numbering. Mac criteria are **AC-HA1–AC-HA10**, PC criteria are **AC-HA-PC1–AC-HA-PC8**, local-mode is **AC-HA-LOCAL1**.

### Mac client (bash) — `bin/claudehome`

- [ ] **AC-HA1** — Inside a folder that contains a single `*_hub` sibling, `[new project here]` prompts for project name (existing flow), then prompts for a description, then creates the folder, runs `git init`, writes `CLAUDE.md` with the computed `@`-import path, appends a row to `<hub>/projects.md`, and finally attaches tmux. Order: folder → git init → CLAUDE.md → projects.md → tmux.
- [ ] **AC-HA2** — `<hub_absolute_path>` in the written `@`-import line is the actual absolute path on the mini, computed from the detected sibling. For `gene-mini_pjt/gene-mini_hub/`, the line reads `@/Users/genehan/projects/claudehome-projects/gene-mini_pjt/gene-mini_hub/README.md` (or the `~/`-expanded equivalent — pick one form and stay consistent).
- [ ] **AC-HA3** — In a folder with NO `*_hub` sibling (e.g. at root of `CLAUDEHOME_PROJECTS_DIR`, or inside an arbitrary non-`_pjt` folder), `[new project here]` runs the existing folder-tree v1 flow only. No description prompt, no `CLAUDE.md` write, no `projects.md` append, no `git init`. Behavior identical to AC-FT3.
- [ ] **AC-HA4** — In a folder with MULTIPLE `*_hub` siblings, the flow prints exactly `claudehome: multiple *_hub siblings found in <parent>; skipping hub-aware writes` to stderr and skips all hub-aware writes. Folder + tmux still happen.
- [ ] **AC-HA5** — Description prompt: empty input is accepted; the placeholder `<one-line description goes here>` is used in BOTH the `CLAUDE.md` body and the `projects.md` row.
- [ ] **AC-HA6** — Description containing a pipe character `|` is escaped as `\|` in the `projects.md` row only. The `CLAUDE.md` body keeps it literal.
- [ ] **AC-HA7** — If `<hub>/projects.md` is missing or zero bytes, print `claudehome: <hub>/projects.md missing or empty; row not appended` to stderr and skip ONLY the projects.md append step. CLAUDE.md write and `git init` still run.
- [ ] **AC-HA8** — All hub-aware writes happen in the same SSH session as folder creation (remote mode). Verify by running `ssh -v` and counting exactly one `Authenticated to <host>` line per `[new project here]` invocation.
- [ ] **AC-HA9** — `claudehome --help` / `claudehome -h` text is unchanged. CLI surface stays exactly `claudehome` and `claudehome --help`.
- [ ] **AC-HA10** — `shellcheck bin/claudehome install_client.sh install_server.sh` passes with no warnings.

### PC client (pwsh 7+) — `bin/claudehome.ps1`

- [ ] **AC-HA-PC1** — All Mac AC-HA1 behavior reproduced from a Windows pwsh client. Same prompts, same write order, same warnings.
- [ ] **AC-HA-PC2** — Multi-hub warning text matches Mac exactly (`claudehome: multiple *_hub siblings found in <parent>; skipping hub-aware writes`).
- [ ] **AC-HA-PC3** — Description input via `Read-Host`. Empty input → placeholder. Single-line only (newlines refused with same retry behavior as Mac).
- [ ] **AC-HA-PC4** — Hub-aware writes happen on the mini via the existing SSH path; never on the Windows client filesystem.
- [ ] **AC-HA-PC5** — `Invoke-ScriptAnalyzer bin/claudehome.ps1 install_client.ps1` passes with no warnings.
- [ ] **AC-HA-PC6** — From the Windows client, creating a new member inside `gene-mini_pjt/` produces the exact same files on the mini as creating it from a Mac client. Diff comparison is byte-identical (modulo timestamps).
- [ ] **AC-HA-PC7** — `bin/claudehome.cmd` shim is unchanged; `claudehome` from `cmd.exe` continues to route through it as today.
- [ ] **AC-HA-PC8** — Pipe-character escaping in `projects.md` row matches Mac exactly.

### Local mode

- [ ] **AC-HA-LOCAL1** — `CLAUDEHOME_LOCAL=1 claudehome` running on the mini executes hub-aware writes locally (no SSH). Result identical to remote mode for the same inputs.

## Assumptions Exposed & Resolved

| Assumption | Challenge | Resolution |
|------------|-----------|------------|
| Hub is detected by suffix `_hub` | Could have used a marker file (`.hub`) or a name-match (`<group>_hub` matching parent) | Suffix glob chosen for simplicity; multi-hub case warns rather than picks heuristically |
| Three writes are atomic | Could fail mid-way and leave partial state | Partial failure is allowed (warn + continue); rollback explicitly out of scope |
| Description prompt is required | Could have been derived from a default or omitted | Prompt added because the row in `projects.md` looks awful empty; placeholder accepted on empty |
| `@`-import path uses absolute or `~/` | Both work in Claude Code | Pick one form and stay consistent within the implementation; tested in AC-HA2 |
| Existing AC-FT3 mkdir step is reusable | Yes — folder-tree v1 already does the mkdir over the same SSH session | Extension hooks into the existing payload, no second round-trip |

## Technical Context

### Files that change
- `bin/claudehome` — extend `prompt_new_project` (around line 549–559 area per folder-tree-v1-plan anchors) to do hub detection + the three writes after `mkdir -p` and before tmux attach.
- `bin/claudehome.ps1` — symmetric extension to its new-project handler.
- `CLAUDE.md` — add a "Hub-aware new-project" subsection under "Architecture (one paragraph)" (or a new sibling section), ~5 lines describing the convention. Update the spec links list to add this spec.
- `.omc/plans/open-questions.md` — add any new open questions surfaced during implementation.

### Files that do NOT change
- `install_client.sh`, `install_client.ps1`, `install_server.sh` — no installer prompts, no env vars, no new dotfiles.
- `~/.claudehomerc` — no new keys.
- Tmux session naming convention — `claudehome-<basename>` everywhere (folder-tree v1 + this spec both preserve it).
- Picker drill-down logic from folder-tree v1.
- `CLAUDEHOME_PROJECTS_DIR` semantics.

### Brownfield code anchors
- Bash new-project flow: `bin/claudehome:549–559` (`prompt_new_project`). Insert hub-aware steps after `mkdir -p` and before the tmux attach call.
- PowerShell new-project flow: `bin/claudehome.ps1:191–207, 227` (anchors borrowed from folder-tree-v1-plan section "Brownfield code anchors").
- Hub detection helper (NEW): a small shell function `detect_hub <parent_path>` that emits the absolute path of the unique `*_hub` sibling (or empty + warning to stderr).
- Description prompt helper (NEW): `prompt_description` returning the input string or the placeholder.
- Three-write helper (NEW): `hub_aware_writes <project_path> <hub_path> <description>`.

### Single-payload composition (remote mode)
The existing folder-tree v1 SSH payload for `[new project here]` already runs `mkdir -p <path>` followed by the tmux attach. Extending the payload looks like:

```bash
ssh ... "
  mkdir -p '$NEW_PROJECT_PATH' &&
  HUB=\$(detect_hub '$PARENT_PATH') &&
  if [ -n \"\$HUB\" ]; then
    git init '$NEW_PROJECT_PATH' >/dev/null 2>&1 || echo 'claudehome: git init failed' >&2
    cat > '$NEW_PROJECT_PATH/CLAUDE.md' <<'CLAUDEMD_EOF'
# $NEW_PROJECT_NAME

@\$HUB/README.md

$DESCRIPTION
CLAUDEMD_EOF
    if [ -s \"\$HUB/projects.md\" ]; then
      echo \"| $NEW_PROJECT_NAME | $DESCRIPTION_ESCAPED | active | — | — |\" >> \"\$HUB/projects.md\"
    else
      echo 'claudehome: '\$HUB'/projects.md missing or empty; row not appended' >&2
    fi
  fi
  tmux new-session -A -s 'claudehome-$NEW_PROJECT_NAME' -c '$NEW_PROJECT_PATH' 'claude; exec \$SHELL'
"
```

This is sketchy syntax — the actual implementation must follow folder-tree v1's quoting/escaping pattern exactly to preserve the allowlist-before-interpolation rule. The above is a structural sketch, not a copy-paste-ready snippet.

## Ontology (Key Entities)

| Entity | Type | Fields | Relationships |
|--------|------|--------|---------------|
| Hub | core domain | absolute_path, README_path, projects_md_path | sibling of zero or more Members at the same parent level |
| Member | core domain | name (globally unique per folder-tree v1), parent_path, hub (optional ref) | created by `[new project here]`; gets hub scaffolding iff a hub is detected |
| ScaffoldOp | supporting | kind (`git_init` / `claude_md_write` / `projects_md_append`), target_path, status (`ok` / `failed` / `skipped`) | one of three per member-create when hub exists |
