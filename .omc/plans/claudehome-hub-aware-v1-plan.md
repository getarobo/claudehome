# Implementation Plan: claudehome hub-aware v1

## Source
- Spec: `.omc/specs/deep-interview-claudehome-hub-aware-v1.md` (PROPOSED, derived from `~/.claude/plans/ok-this-is-will-moonlit-teacup.md`)
- Parent specs: `deep-interview-claudehome-folder-tree-v1.md`, `deep-interview-claudehome-v1.md`, `deep-interview-claudehome-pc-v1.md`
- Parent plans: `claudehome-folder-tree-v1-plan.md`, `claudehome-v1-plan.md`, `claudehome-pc-v1-plan.md`
- Date: 2026-05-08
- Mode: RALPLAN-DR (SHORT) — small focused brownfield extension; ~50–80 lines added per client; no new env vars, no installer change, no daemons

---

## 1. Summary

Extend `prompt_new_project` (bash) and its pwsh counterpart so they detect a `*_hub` sibling of the new project's parent dir and, when found, run three additional writes (`git init`, `CLAUDE.md` with computed `@`-import, `projects.md` row append) before the tmux attach. A description prompt is added between the project-name prompt and the writes. No other claudehome behavior changes.

This is purely a `[new project here]` enrichment. Picker behavior from folder-tree v1 is unchanged. Existing 14 flat projects + any folder-tree v1 nested projects keep working untouched. Hub-aware writes only fire when both (a) `[new project here]` is invoked AND (b) the parent dir has exactly one `*_hub` sibling.

## 2. RALPLAN-DR Principles (non-negotiable)

1. **Single SSH round-trip preserved.** Hub-aware writes are folded into the existing folder-tree v1 SSH payload that already does `mkdir -p` and tmux attach. No second round-trip. (CLAUDE.md "Architecture"; folder-tree-v1-plan ADR.)
2. **Mac+PC parity.** Every behavior in `bin/claudehome` is mirrored in `bin/claudehome.ps1` — same hub-detection glob, same write order, same warning text, same description prompt, same pipe-escaping rule.
3. **No new state, no new env vars, no new installer prompts.** The naming convention (`*_hub`) is enforced via a single shell glob; the user creates hubs manually outside claudehome.
4. **Allowlist-before-interpolation, unchanged regex.** `[a-zA-Z0-9._-]` for project names (already enforced by AC-FT3); `<description>` content goes through quoted-heredoc / single-quote-escape paths only — never positional shell args.
5. **Tmux session naming unchanged.** `claudehome-<basename>` regardless of hub presence. Folder-tree v1's globally-unique name rule already prevents collisions across the tree.

## 3. Decision Drivers

1. **Reuse folder-tree v1's single-payload SSH structure.** Don't introduce a second `ssh …` invocation; just extend the existing `mkdir + tmux attach` payload with the three writes between them.
2. **Conditional firing on hub presence.** `[new project here]` at root or in a non-hub folder must behave identically to today (AC-HA3). No surprises for users not opted into the masterplan pattern.
3. **Partial failure is OK.** If `git init` fails on permissions, don't block the rest. Warn + continue. The user gets their tmux session no matter what.

## 4. Implementation steps

### 4.1 Bash (`bin/claudehome`)

#### Step 1 — Add `detect_hub` helper

After existing helpers (around the helper-function area, before `prompt_new_project`):

```bash
# detect_hub <parent_path>
# Emits the absolute path of the unique *_hub sibling under <parent_path>,
# or empty if zero matches. Warns to stderr on multiple matches.
detect_hub() {
  local parent="$1"
  local matches=()
  local m
  for m in "$parent"/*_hub; do
    [[ -d "$m" ]] && matches+=("$m")
  done
  case "${#matches[@]}" in
    0) printf '' ;;
    1) printf '%s' "${matches[0]}" ;;
    *) printf 'claudehome: multiple *_hub siblings found in %s; skipping hub-aware writes\n' "$parent" >&2; printf '' ;;
  esac
}
```

#### Step 2 — Add `prompt_description` helper

```bash
# prompt_description
# Reads a single-line description from stdin; empty → placeholder.
# Re-prompts on embedded newlines (Read-Host-style validation).
prompt_description() {
  local desc
  while :; do
    if ! read -r -p "One-line description (optional): " desc; then
      desc=""
      break
    fi
    if [[ "$desc" == *$'\n'* ]]; then
      printf 'claudehome: description must be single-line\n' >&2
      continue
    fi
    break
  done
  if [[ -z "$desc" ]]; then
    printf '<one-line description goes here>'
  else
    printf '%s' "$desc"
  fi
}
```

#### Step 3 — Modify `prompt_new_project` (around line 549)

Locate the existing `mkdir -p` (or its remote-payload equivalent) and the subsequent tmux attach. Insert hub-aware steps between them. Pseudocode (actual code must respect folder-tree v1's quoting):

```bash
# After folder creation (mkdir done), before tmux attach:
local hub_path
hub_path=$(detect_hub "$parent_path")
if [[ -n "$hub_path" ]]; then
  local description description_for_md
  description=$(prompt_description)
  description_for_md="${description//|/\\|}"   # escape pipes for projects.md row only
  hub_aware_writes "$parent_path/$name" "$hub_path" "$description" "$description_for_md"
fi
# Existing tmux attach continues here.
```

#### Step 4 — Add `hub_aware_writes` helper

```bash
# hub_aware_writes <project_path> <hub_path> <description> <description_pipe_escaped>
# Runs the three writes. Warns on per-step failure but does not abort.
hub_aware_writes() {
  local project_path="$1" hub_path="$2" desc="$3" desc_md="$4"

  # 1. git init
  git init "$project_path" >/dev/null 2>&1 || \
    printf 'claudehome: git init failed at %s\n' "$project_path" >&2

  # 2. Write CLAUDE.md
  local project_name
  project_name=$(basename "$project_path")
  cat > "$project_path/CLAUDE.md" <<EOF || printf 'claudehome: CLAUDE.md write failed at %s\n' "$project_path" >&2
# $project_name

@$hub_path/README.md

$desc
EOF

  # 3. Append to projects.md (only if it exists and is non-empty)
  if [[ -s "$hub_path/projects.md" ]]; then
    printf '| %s | %s | active | — | — |\n' "$project_name" "$desc_md" >> "$hub_path/projects.md" || \
      printf 'claudehome: projects.md append failed at %s\n' "$hub_path/projects.md" >&2
  else
    printf 'claudehome: %s/projects.md missing or empty; row not appended\n' "$hub_path" >&2
  fi
}
```

#### Step 5 — Remote-mode payload composition

The existing folder-tree v1 remote payload for `[new project here]` runs `mkdir -p` and `tmux new-session` over a single SSH `bash --norc --noprofile -c '…'` call. Extend that payload to include all four `hub_aware_*` helpers AND the conditional dispatch. The helpers must be emitted as part of the same payload (heredoc) so they exist in the remote shell that runs the dispatch.

Sketch (NOT copy-paste-ready — must align with folder-tree-v1-plan's escaping):

```bash
ssh ... bash --norc --noprofile -c "$(cat <<'OUTER'
# (helpers detect_hub, prompt_description, hub_aware_writes inlined here)
mkdir -p '$NEW_PROJECT_PATH'
HUB=$(detect_hub '$PARENT_PATH')
if [ -n "$HUB" ]; then
  hub_aware_writes '$NEW_PROJECT_PATH' "$HUB" '$DESCRIPTION' '$DESCRIPTION_ESCAPED'
fi
exec tmux new-session -A -s 'claudehome-$NEW_PROJECT_NAME' -c '$NEW_PROJECT_PATH' 'claude; exec $SHELL'
OUTER
)"
```

The description prompt happens **on the client side** (so the user types into their local terminal), and the resolved value is passed to the remote payload as a pre-validated, allowlist-filtered string. Description content does NOT need to follow the project-name allowlist (it's natural language); it must instead be passed via the heredoc, never as a positional shell arg.

### 4.2 PowerShell (`bin/claudehome.ps1`)

Symmetric implementation:

- **Hub detection:** `Get-ChildItem -Path $ParentPath -Directory -Filter '*_hub' -ErrorAction SilentlyContinue`. Count results; act per AC-HA-PC1 / PC2.
- **Description prompt:** `Read-Host 'One-line description (optional)'`. Validate single-line; placeholder on empty.
- **Pipe escaping:** `$DescEscaped = $Desc -replace '\|', '\|'`.
- **Three writes:** Use `git init` (assume on PATH on the mini), here-string for `CLAUDE.md` body, `Add-Content` for `projects.md` append.
- **Remote-mode composition:** PowerShell's existing path for new-project sends a bash payload to the mini via SSH. Extend that payload with the bash helpers — same payload as Mac. The pwsh client doesn't run the helpers itself; it just composes and ships the bash payload, identical to what the Mac client ships. This keeps the ON-MINI behavior single-source.

### 4.3 CLAUDE.md doc update

Add a new short subsection in `claudehome/CLAUDE.md`:

```markdown
## Hub-aware new-project (folder-tree-v1 + hub-aware-v1)

When `[new project here]` is invoked inside a folder that has exactly one
sibling whose basename ends in `_hub`, the flow runs three additional steps
between folder creation and tmux attach:

1. `git init` in the new project directory.
2. Write `CLAUDE.md` with an `@`-import line pointing at `<hub>/README.md`.
3. Append a row to `<hub>/projects.md`.

Detection is a simple shell glob (`<parent>/*_hub`). Zero matches → today's
behavior. Two or more → warn and skip (multi-hub deferred). Sibling-suffix
naming is the only convention recognized; no marker files, no extension
points. See `.omc/specs/deep-interview-claudehome-hub-aware-v1.md`.
```

Also append the new spec/plan paths to the "Key docs" list.

### 4.4 Update `.omc/plans/open-questions.md`

Add a new section for any open questions surfaced during implementation. Likely candidates:

- **OQ-HA-1:** What happens if the user creates a project at top level whose name happens to end in `_hub`? Today this would be picked up by `detect_hub` for any sibling created later. Fine, but document.
- **OQ-HA-2:** Should `[new project here]` warn when invoked in a folder ending `_pjt` but with NO `*_hub` sibling? (Probably no — we don't recognize `_pjt` semantically; only `_hub` triggers behavior.)

## 5. Tests / verification

### 5.1 Setup fixtures (Mac mini, local mode)

```bash
# Test hub
mkdir -p ~/projects/claudehome-projects/test_pjt/test_hub
cat > ~/projects/claudehome-projects/test_pjt/test_hub/README.md <<'EOF'
# test_hub
Test hub for AC-HA verification.
EOF
cat > ~/projects/claudehome-projects/test_pjt/test_hub/projects.md <<'EOF'
# Members

| Member | Purpose | Status | Runtime | Consumes |
|---|---|---|---|---|
EOF
```

### 5.2 AC walk-through (manual)

| AC | Steps | Expected |
|---|---|---|
| AC-HA1 | `claudehome` → drill `test_pjt` → `[new project here]` → name `foo` → desc `does the foo thing` | `test_pjt/foo/.git/`, `test_pjt/foo/CLAUDE.md` containing `@<abs>/test_hub/README.md`, `test_pjt/test_hub/projects.md` has new row, tmux session `claudehome-foo` attached |
| AC-HA2 | Inspect `test_pjt/foo/CLAUDE.md` | `@`-import path is the absolute path of `test_hub`, not a hardcoded string |
| AC-HA3 | `claudehome` → root level → `[new project here]` → name `bar` | `bar/` exists with no `.git/`, no `CLAUDE.md`; tmux attached |
| AC-HA4 | `mkdir test_pjt/another_hub` then `[new project here]` inside `test_pjt` | stderr: `claudehome: multiple *_hub siblings found in <parent>; skipping hub-aware writes`; only folder + tmux |
| AC-HA5 | `[new project here]` inside `test_pjt`, name `qux`, description empty | `qux/CLAUDE.md` body contains `<one-line description goes here>`; `projects.md` row also has placeholder |
| AC-HA6 | `[new project here]` inside `test_pjt`, name `baz`, description `pipe \| inside` | `projects.md` row has `pipe \\| inside`; `CLAUDE.md` body has `pipe \| inside` literal |
| AC-HA7 | `: > test_pjt/test_hub/projects.md` (truncate to 0 bytes); `[new project here]` inside `test_pjt`, name `quux` | stderr warning; `quux/CLAUDE.md` and `.git/` still exist |
| AC-HA8 | Run with `ssh -v` (remote mode); `[new project here]` inside `test_pjt` | exactly one `Authenticated to <host>` in the verbose log |
| AC-HA9 | `claudehome --help` | usage text matches pre-change baseline |
| AC-HA10 | `shellcheck bin/claudehome install_client.sh install_server.sh` | no warnings |

PC AC-HA-PC1–PC8 mirror the above from a Windows pwsh client. AC-HA-PC6 specifically: take diffs of the files produced by the Mac and PC clients with the same inputs; expect byte-identical output.

### 5.3 Lint

- `shellcheck bin/claudehome install_client.sh install_server.sh`
- `Invoke-ScriptAnalyzer bin/claudehome.ps1 install_client.ps1`

### 5.4 Smoke test

- `bin/claudehome --help` exit 0
- `bin/claudehome.ps1 --help` exit 0
- Existing folder-tree v1 ACs (AC-FT1–FT12) all still pass — hub-aware additions must not regress drill-down behavior.

## 6. Risks

- **R1 — `gene-mini_pjt/gene-mini_hub/` doesn't exist yet on the user's mini.** Until it does, only AC-HA3 can be verified there (no-hub case). All other ACs require either the test fixture in §5.1 or the actual gene-mini_hub creation. Acceptable: ship the spec/plan + code now; ACs validate against the test fixture.
- **R2 — pwsh + remote bash payload escaping for multi-line CLAUDE.md content.** Embedding a multi-line heredoc inside a pwsh string that becomes a bash `-c` arg is finicky. Folder-tree v1 plan likely already handled this for similar concerns; reuse its patterns. If not, add a unit test that round-trips a known string.
- **R3 — Description containing shell metacharacters (`;`, `$`, backticks, `\n`).** The description goes into a heredoc with quoted delimiter (`<<'EOF'`) so no expansion occurs. Newlines are rejected at the prompt. Backticks/dollar-signs inside a quoted heredoc are literal — safe.
- **R4 — Description containing `]` or other markdown-table-breaking characters.** Pipes are escaped (AC-HA6); other characters (e.g. `]`, `[`, `*`) render as Markdown but don't break the table structure. Acceptable; document.
- **R5 — Concurrent runs of `[new project here]` against the same hub.** Two simultaneous appends to `projects.md` could interleave. Probability: very low (single-user CLI, sequential picker). Mitigation: rely on shell `>>` atomicity for short writes; if it surfaces, add `flock` later.
- **R6 — Hub-aware writes produce stale `projects.md` after manual file move.** If the user `mv`'s a member out of `_pjt/`, the row stays. This is by design — the spec says filesystem is source of truth, projects.md is documentary. Document in CLAUDE.md.

## 7. Out of scope

- Building `gene-mini_pjt/gene-mini_hub/` itself. That's a separate task in the gene-mini hub plan (`~/.claude/plans/ok-this-is-will-moonlit-teacup.md`).
- Service-registration tooling. Manual edits to `services.yaml` and `openapi/` for now.
- Member-lifecycle automation (deprecation, exit-to-standalone, deletion).
- Scaffolding pluggability / generic `<hub>/.scaffolding.sh`.
- Multi-hub support.

## 8. Rollback

If hub-aware writes cause regressions, the rollback is a single-commit revert of:
- `bin/claudehome` changes (the four helpers + the dispatch in `prompt_new_project`).
- `bin/claudehome.ps1` changes (symmetric).
- `CLAUDE.md` doc additions.

The new spec/plan files in `.omc/` can stay (they're documentation, not behavior). Existing folder-tree v1 picker behavior is unaffected by the revert.
