# claudehome

**Persistent Claude Code sessions on your Mac mini, accessible from any device.**

A Mac mini runs 24/7 as an always-on dev server. `claudehome` on your MacBook picks a project, attaches to a persistent `claude` session running in tmux, and feels identical to running Claude Code locally. Close the laptop, reopen it hours later, reconnect — the session is still there, complete with scrollback and in-flight work.

## How it works

```
┌──────────┐   ssh over    ┌──────────┐   tmux   ┌────────┐
│ MacBook  │ ─ Tailscale ─▶│ Mac mini │ ───────▶ │ claude │
└──────────┘               └──────────┘          └────────┘
     ▲                           │
     └───── same session resumes on reconnect ─┘
```

- **Tailscale** solves "where is the Mac mini" — no static IP, no port forwarding.
- **tmux** keeps each project's `claude` session alive across disconnects.
- **claudehome** is a ~100-line bash script: pick a project, `ssh -t` into the right tmux session.

Each project gets its own tmux session named `claudehome-<project>`. Sessions are **eternal** — they live until you kill them — and **outlive the `claude` process** inside them, so if `claude` exits you drop to a shell prompt and can relaunch in place.

## Setup

There are **two roles**: the **server** (Mac mini, always on) and the **client** (MacBook or other device you connect from). The `install.sh` script lives on the **client side only** — the Mac mini doesn't need this repo installed. The Mac mini just needs standard tools (`tmux`, `claude`) and SSH enabled.

### Mac mini — server (do this **once**)

Steps 1–2 need physical access to the mini (GUI). Everything after that can run **either** on the mini in Terminal **or** remotely via `ssh gene-mini '…'` from any client — both produce the same result. The commands below show the remote form; drop the `ssh gene-mini '…'` wrapper if you're sitting at the mini.

**1. [At the mini, GUI] Install Tailscale and log in.**
Download from https://tailscale.com/download, open the app, log in to the same account your clients use. Confirm the mini appears in [the Tailscale admin console](https://login.tailscale.com/admin/machines). Enable **MagicDNS** under the DNS tab so `ssh gene-mini` resolves without typing the full `.ts.net` suffix. If the mini's Tailscale name isn't `gene-mini`, rename it on the admin page (or set `CLAUDEHOME_HOST=<actual-name>` on your clients later).

**2. [At the mini, GUI] Enable SSH.**
System Settings → General → Sharing → **Remote Login: on**.

**3. [From your client] Authorize your key and sanity-check.**

If your **client username** (the name in your MacBook prompt, `echo $USER`) differs from your **mini account name** (e.g. `gene` on the laptop but `genehan` on the mini), you **must** pass the mini user explicitly to `ssh-copy-id`. Otherwise your key gets authorized for the wrong remote account and `claudehome` will fail later with `Permission denied` under BatchMode even though `ssh gene-mini` appears to work (because it silently falls back to password auth).

```sh
ssh-copy-id genehan@gene-mini                        # replace genehan with your mini user
ssh -o BatchMode=yes genehan@gene-mini echo ok       # expect: ok, no password prompt
```

If usernames match, `ssh-copy-id gene-mini` is enough.

Once BatchMode SSH returns `ok`, every remaining step works over SSH — you do not need to walk back to the mini.

**4. Install tmux.**

```sh
ssh gene-mini 'brew install tmux'
```

**5. Install Claude Code on the mini** (skip if `claude` is already there).

```sh
ssh gene-mini 'curl -fsSL https://claude.ai/install.sh | bash'
```

**6. Put Homebrew and `claude` on the SSH (non-interactive) PATH.**
macOS SSH sessions load `~/.zshenv` but **not** `~/.zshrc`, so Homebrew and `~/.local/bin` typically aren't visible over SSH by default. Without this step, `ssh gene-mini 'claude'` returns `command not found` even though claude works fine when you open Terminal on the mini.

Apple Silicon:

```sh
echo 'export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"' \
  | ssh gene-mini 'cat >> ~/.zshenv'
```

Intel Macs:

```sh
echo 'export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"' \
  | ssh gene-mini 'cat >> ~/.zshenv'
```

Verify both tools now resolve over SSH:

```sh
ssh gene-mini 'which claude tmux'     # both paths should print
```

**7. Create the projects root.**

```sh
ssh gene-mini 'mkdir -p ~/projects/claudecode'
```

**8. Log Claude Code in on the mini (first time only).**
A fresh `claude` install has no Anthropic credentials. The OAuth login needs a real TTY, which requires `ssh -t`:

```sh
ssh -t genehan@gene-mini claude     # replace genehan with your mini user
```

Claude prints a login URL on first launch. Paste it into a browser on any device, complete the Anthropic sign-in, and paste the returned code back into the SSH session. Credentials save to `~/.claude/` on the mini and persist across reboots — you only do this once per mini. After that, sessions launched by `claudehome` use the stored login automatically.

That's it — no `git clone`, no `install.sh`, no `claudehome` binary on the Mac mini. The mini only needs `tmux` + logged-in `claude` + SSH. The `claudehome` CLI lives on the client side.

### Mac client — MacBook (or any Mac you connect from)

Do this **once per client device**.

```sh
# 1. Tailscale (same tailnet as the mini)
brew install --cask tailscale
# Or download: https://tailscale.com/download

# 2. fzf — optional, much nicer picker
brew install fzf

# 3. Clone this repo and install the CLI
git clone git@github.com:sr-gene/claudehome.git ~/projects/claudehome
cd ~/projects/claudehome
./install.sh                 # symlinks bin/claudehome into ~/.local/bin
# or: ./install.sh --system  # symlinks into /usr/local/bin (requires sudo)
```

If `install.sh` warns that `~/.local/bin` is not in your `PATH`, add it to your shell rc and re-source:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Use `~/.bashrc` instead of `~/.zshrc` if you run bash. Verify with `which claudehome` — it should print `~/.local/bin/claudehome`.

**If your client's `$USER` doesn't match your mini account**, tell `claudehome` the correct remote user. Otherwise it defaults to the client's `$USER` and SSH rejects the auth (you'll see `cannot reach $USER@gene-mini over SSH` even after the mini is fully set up):

```sh
echo 'export CLAUDEHOME_USER=genehan' >> ~/.zshrc   # replace genehan with your mini user
source ~/.zshrc
```

Same applies to the Tailscale hostname if your mini isn't called `gene-mini` — set `CLAUDEHOME_HOST=<your-tailscale-name>` the same way.

### PC — Windows (not yet)

The PowerShell client is a deferred v2. Meanwhile you can SSH in manually from Windows' built-in OpenSSH:

```powershell
ssh gene-mini
tmux new-session -A -s claudehome-my-project -c ~/projects/claudecode/my-project 'claude; exec $SHELL'
```

When `claudehome.ps1` ships, the above collapses to a single `claudehome` command.

### iPhone (not yet)

Deferred. Near-term workflow is **Blink Shell** + the same manual SSH/tmux command above. A scripted `claudehome` for iOS ships later.

## Run

```sh
claudehome
```

You'll see a picker of every directory under `~/projects/claudecode` on the Mac mini, each annotated with live session state:

```
▸ my-api-project  [active 2h ago]
  landing-page    [active 1d ago]
  side-tool       [idle]
```

Pick one and you're in. Detach with tmux's standard `Ctrl-b d`; your session keeps running on the Mac mini.

## Configuration

All configuration is via environment variables. There is no config file in v1.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDEHOME_HOST` | `gene-mini` | Tailscale hostname of the Mac mini |
| `CLAUDEHOME_USER` | `$USER` on the client | SSH user on the Mac mini |
| `CLAUDEHOME_PROJECTS_DIR` | `~/projects/claudecode` | Projects root **on the Mac mini** |

`CLAUDEHOME_PROJECTS_DIR` is a path on the Mac mini. If you use a leading tilde, set it with single quotes so your client shell does not expand the tilde locally:

```sh
export CLAUDEHOME_PROJECTS_DIR='~/other/root'
```

**Allowed characters.** To keep the remote SSH command safe to construct as a string, `claudehome` only accepts a conservative character set:

| Variable | Allowed characters |
| --- | --- |
| `CLAUDEHOME_HOST`, `CLAUDEHOME_USER` | letters, digits, `.`, `_`, `-` |
| `CLAUDEHOME_PROJECTS_DIR` | letters, digits, `.`, `_`, `/`, `~`, `-` |
| Project directory names | letters, digits, `.`, `_`, `-` |

Project directory names with spaces, quotes, or other shell-special characters are rejected with a clear message. Rename the directory on the Mac mini if you see one.

## Usage notes

- **Picker** shows every direct subdirectory of the projects root, with `[active …]` if a `claudehome-<name>` tmux session exists, `[idle]` otherwise. `[active …]` includes the last-activity timestamp (e.g. `2h ago`).
- **Attach** creates the tmux session if it doesn't exist, launches `claude` inside it, and drops you into the live pane. Subsequent attaches resume the same session.
- **Detach**: `Ctrl-b d` — same as vanilla tmux. Session keeps running on the Mac mini.
- **Exit claude**: `/exit` (or `Ctrl-D`) inside Claude Code drops to a shell prompt in the same tmux session. The session stays alive; run `claude` again to resume in place.
- **Disconnect** (close lid, Tailscale drops, terminal killed): nothing on the Mac mini changes. Reconnect later with `claudehome` and pick the same project.

## Troubleshooting

- **`cannot reach gene-mini via SSH`**
  Check `tailscale status` on both devices — both should show the other as connected. Make sure Mac mini's Remote Login is on. Test with a plain `ssh gene-mini echo ok`.

- **`no projects found in ~/projects/claudecode`**
  Create the directory and a first project on the Mac mini:
  ```sh
  ssh gene-mini 'mkdir -p ~/projects/claudecode/my-first-project'
  ```

- **Picker falls back to numbered menu instead of arrow keys**
  `fzf` is not installed on your client. `brew install fzf` and it takes over automatically.

- **`tmux: command not found`** in the error output
  `brew install tmux` on the Mac mini.

- **`claude: command not found`** inside an attached session
  The SSH non-interactive shell can't find claude. Add the directory containing `claude` to `PATH` in `~/.zshenv` (or `~/.bash_profile`) on the Mac mini, not just `~/.zshrc`.

- **Cleaning up orphaned sessions.** If you delete a project directory from `~/projects/claudecode`, its tmux session lingers. Remove it with:
  ```
  ssh gene-mini 'tmux kill-session -t claudehome-<project-name>'
  ```

## Non-goals (v1)

- Web UI, native mobile app
- Windows / PC client (PowerShell version is planned)
- iPhone client (planned — likely via Blink or mosh + tmux)
- Project scaffolding (`claudehome new`) — create directories manually
- Session management subcommands (`ls`, `kill`, `attach <name>`)
- Session TTL / automatic cleanup of orphans
- Multi-user or shared Mac mini

See `.omc/specs/deep-interview-claudehome-v1.md` for the full scope and rationale.

## License

MIT.
