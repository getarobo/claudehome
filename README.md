# claudehome

**Persistent Claude Code sessions on your Mac mini, accessible from any device.**

A Mac mini runs 24/7 as an always-on dev server. `claudehome` on any client picks a project, attaches to a persistent `claude` session running in tmux, and feels identical to running Claude Code locally. Close the laptop, reopen it hours later — the session is still there, complete with scrollback and in-flight work.

## How it works

```
┌──────────┐   ssh over    ┌──────────┐   tmux   ┌────────┐
│  client  │ ─ Tailscale ─▶│ Mac mini │ ───────▶ │ claude │
└──────────┘               └──────────┘          └────────┘
     ▲                           │
     └───── same session resumes on reconnect ────┘
```

- **Tailscale** — connects your devices without static IPs or port forwarding
- **tmux** — keeps each project's `claude` session alive across disconnects
- **claudehome** — a ~150-line script: pick a project, `ssh -t` into the right tmux session

Each project gets its own tmux session named `claudehome-<project>`. Sessions outlive the `claude` process — if `claude` exits you drop to a shell and can relaunch in place.

---

## Setup

Two roles: **server** (Mac mini, always on) and **client** (any device you connect from).

The Mac mini needs only `tmux`, a logged-in `claude`, and SSH enabled — it never needs this repo installed. The `claudehome` CLI lives on the client.

> **Before you start:** Know your mini's account name — it may differ from what you expect.
> At the mini's Terminal (or over SSH if you can already connect): `echo $USER`
> Use that value wherever you see `<mini-user>` below.

---

### 1. Mac mini — server (one-time)

**Steps 1a–1b require physical access (GUI). Everything after runs remotely.**

#### 1a. Install Tailscale

Download from https://tailscale.com/download, open the app, log in to the **same Tailscale account** your clients use.

- Confirm the mini appears in the [Tailscale admin console](https://login.tailscale.com/admin/machines).
- Under the **DNS** tab, enable **MagicDNS** so clients can reach it by name (e.g. `<mini-host>`).
- If the mini's Tailscale hostname isn't what you want, rename it on the admin page or set `CLAUDEHOME_HOST` on your clients later.

#### 1b. Enable SSH

**System Settings → General → Sharing → Remote Login: on**

#### 1c. Authorize your SSH key

From your client, copy your key to the mini using the mini's actual account name:

```sh
ssh-copy-id <mini-user>@<mini-host>
```

Verify it works without a password prompt:

```sh
ssh -o BatchMode=yes <mini-user>@<mini-host> echo ok   # must print: ok
```

Once this returns `ok`, every remaining step can run remotely — no need to return to the mini.

#### 1d. Install tmux

```sh
ssh <mini-host> 'brew install tmux'
```

#### 1e. Install Claude Code

Skip if `claude` is already installed on the mini.

```sh
ssh <mini-host> 'curl -fsSL https://claude.ai/install.sh | bash'
```

#### 1f. Fix the SSH PATH

macOS SSH sessions load `~/.zshenv` but **not** `~/.zshrc`, so tools installed via Homebrew are invisible over SSH by default. Without this step, `ssh <mini-host> 'claude'` returns `command not found`.

Apple Silicon:
```sh
echo 'export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"' \
  | ssh <mini-host> 'cat >> ~/.zshenv'
```

Intel Mac:
```sh
echo 'export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"' \
  | ssh <mini-host> 'cat >> ~/.zshenv'
```

Verify:
```sh
ssh <mini-host> 'which claude tmux'   # both paths should print
```

#### 1g. Create the projects root

```sh
ssh <mini-host> 'mkdir -p ~/projects/claudecode'
```

#### 1h. Log Claude Code in (first time only)

A fresh `claude` needs OAuth credentials. This requires an interactive TTY:

```sh
ssh -t <mini-user>@<mini-host> claude
```

Claude prints a login URL. Open it in any browser, complete sign-in, paste the code back. Credentials save to `~/.claude/` on the mini and persist across reboots.

---

### 2. Mac client (one-time per Mac)

```sh
# Install Tailscale (same tailnet as the mini)
brew install --cask tailscale

# Clone and install
git clone git@github.com:getarobo/claudehome.git ~/projects/claudehome
cd ~/projects/claudehome
./install.sh
```

The installer wizard handles the rest:

- Checks Tailscale is running (links to download if not)
- Prompts for your mini's hostname and SSH username
- Generates an SSH key if you don't have one, then copies it to the mini
- Installs `fzf` via Homebrew if available (enables arrow-key picker)
- Appends `~/.local/bin` to your PATH in `~/.zshrc` if needed
- Saves config to `~/.claudehomerc`

Re-running `./install.sh` is safe — prompts are skipped for values already configured.

---

### 3. Windows client — PowerShell 7+ (one-time per PC)

Install prerequisites first (if not already present):

```powershell
winget install Microsoft.PowerShell    # PowerShell 7
winget install Tailscale.Tailscale     # same tailnet as the mini
where.exe ssh                          # verify OpenSSH is present (pre-installed on Windows 10 1803+)
```

Then clone and install:

```powershell
git clone git@github.com:getarobo/claudehome.git $HOME\projects\claudehome
Set-Location $HOME\projects\claudehome
.\install.ps1
```

The installer wizard handles the rest:

- Checks Tailscale is running (links to download if not)
- Prompts for your mini's hostname and SSH username
- Generates an SSH key if you don't have one, then copies it to the mini
- Installs `fzf` via winget if available (enables arrow-key picker)
- Adds `<repo>\bin` to your user PATH
- Saves config to `~/.claudehomerc`

Open a **new** PowerShell window after install, then run `claudehome`.

Re-running `.\install.ps1` is safe — prompts are skipped for values already configured.

> **Note:** If you downloaded the repo as a ZIP instead of cloning, run `Unblock-File .\install.ps1` before executing. `git clone` doesn't require this.

**Terminal tip:** Use WezTerm or Windows Terminal for best rendering. The `.cmd` shim also works from `cmd.exe`.

---

### 4. iPhone (not yet)

Deferred. Near-term: use **Blink Shell** with a manual `ssh -t <mini-user>@<mini-host> tmux new-session -A -s myproject` command. A scripted `claudehome` for iOS ships later.

---

## Usage

```sh
claudehome
```

A picker shows every project under `~/projects/claudecode` on the mini, annotated with session state:

```
▸ my-api-project  [active 2h ago]
  landing-page    [active 1d ago]
  side-tool       [idle]
```

Pick one and you're in.

### Key bindings

| Action | Keys |
|---|---|
| Detach (leave session running) | `Ctrl-b` then `d` |
| Exit Claude Code | `/exit` or `Ctrl-D` |

> `Ctrl-b d` is **two separate keystrokes**: hold `Ctrl+b` together, release, then press `d`.

**Disconnect** (close lid, kill terminal, lose Tailscale): nothing on the mini changes. Reconnect later with `claudehome` and pick the same project.

---

## Configuration

Config is read from `~/.claudehomerc` (written by the installer), then overridden by environment variables. No other config files.

`~/.claudehomerc` format — plain `KEY=VALUE`, `#` comments allowed:

```
# claudehome config
CLAUDEHOME_HOST=my-mini
CLAUDEHOME_USER=myuser
# CLAUDEHOME_PROJECTS_DIR=~/projects/claudecode
```

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDEHOME_HOST` | none — required | Tailscale hostname of the Mac mini |
| `CLAUDEHOME_USER` | local `$USER` / `$env:USERNAME` | SSH username on the Mac mini |
| `CLAUDEHOME_PROJECTS_DIR` | `~/projects/claudecode` | Projects root on the Mac mini |

Set `CLAUDEHOME_PROJECTS_DIR` with single quotes to prevent local tilde expansion:
```sh
export CLAUDEHOME_PROJECTS_DIR='~/other/root'
```

**Allowed characters** (to keep the remote SSH command safe):

| Variable | Allowed |
|---|---|
| `CLAUDEHOME_HOST`, `CLAUDEHOME_USER` | letters, digits, `.` `_` `-` |
| `CLAUDEHOME_PROJECTS_DIR` | letters, digits, `.` `_` `/` `~` `-` |
| Project directory names | letters, digits, `.` `_` `-` |

Project directories with spaces or shell-special characters are rejected with a clear error. Rename the directory on the mini if you see one.

---

## Troubleshooting

**`CLAUDEHOME_HOST is not set`**
Run the installer (`./install.sh` or `.\install.ps1`) to configure, or set the variable manually:
```sh
export CLAUDEHOME_HOST=<mini-host>    # Mac/Linux
$env:CLAUDEHOME_HOST = '<mini-host>'  # Windows
```

**`Permission denied (publickey)`**
The SSH key isn't in the right user's `authorized_keys`. Confirm the mini's account name (`ssh <mini-host> 'echo $USER'`), then re-authorize:
```sh
ssh-copy-id <mini-user>@<mini-host>
ssh -o BatchMode=yes <mini-user>@<mini-host> echo ok   # must print: ok
```
Also verify permissions on the mini: `~/.ssh` must be `700`, `~/.ssh/authorized_keys` must be `600`.

**`cannot reach <mini-host> via SSH`**
Run `tailscale status` on both devices — both should list the other as connected. Confirm Remote Login is on in System Settings. Test with `ssh <mini-host> echo ok`.

**`no projects found in ~/projects/claudecode`**
Create a project on the mini:
```sh
ssh <mini-host> 'mkdir -p ~/projects/claudecode/my-first-project'
```

**Picker shows a numbered menu instead of arrow keys**
`fzf` isn't installed on your client. Install it (`brew install fzf` / `winget install junegunn.fzf`) and it takes over automatically.

**`tmux: command not found`**
Run `brew install tmux` on the Mac mini.

**`claude: command not found` inside a session**
The SSH non-interactive shell can't find `claude`. Add its directory to `PATH` in `~/.zshenv` on the mini (not `~/.zshrc` — SSH doesn't load it). See step 1f above.

**Orphaned tmux sessions**
If you delete a project directory, its session lingers. Remove it:
```sh
ssh <mini-host> 'tmux kill-session -t claudehome-<project-name>'
```

---

## Non-goals (v1)

- Web UI or native mobile app
- iPhone client (planned — Blink Shell in the meantime)
- Project scaffolding (`claudehome new`) — create directories manually
- Session management subcommands (`ls`, `kill`, `attach <name>`)
- Automatic cleanup of orphaned sessions
- Multi-user or shared Mac mini
- Server-side bootstrap script (mini setup is manual per Section 1)

---

## License

MIT.
