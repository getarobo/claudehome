# claudehome — Open Questions

## claudehome-folder-tree-v1 — 2026-05-08
- [ ] OQ-1: When the folder-vs-project heuristic classifies a `.git`-only directory as a folder, should we add a special-case override (".git as the only child → project")? — Why it matters: would silently break drilling into solo-git repos. Spec says "revisit if it produces surprises"; defer to first user report.
- [x] OQ-2 (RESOLVED 2026-05-08, iter 2): `head -z -n 2000` portability across macOS BSD `head`. Resolution: BSD `head` rejects `-z` outright (`head: invalid option -- z`). Plan now uses `awk -v RS='\0' -v ORS='\0' 'NR<=2000'` everywhere, portable across macOS bash 3.2 / GNU / BSD. The bare `awk 'NR<=2000'` form is also wrong (default `RS='\n'` consumes the entire NUL-stream as one record), so the explicit `-v RS='\0' -v ORS='\0'` flags are mandatory. No longer blocks Phase 1.
