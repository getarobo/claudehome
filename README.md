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

> **Before you start:** Know your mini's account name. It may differ from what you expect.
> Run this from any client that can already SSH in (or type it at the mini's Terminal):
> ```sh
> echo $USER
> ```
> Use that value wherever you see `<mini-user>` below.

---

### 1. Mac mini — server (one-time)

**Steps 1–2 require physical access (GUI). Everything after can run remotely.**

#### 1a. Install Tailscale

Download from https://tailscale.com/download, open the app, log in to the **same Tailscale account** your clients use.

- In the [Tailscale admin console](https://login.tailscale.com/admin/machines), confirm the mini appears.
- Under the **DNS** tab, enable **MagicDNS** so clients can reach it by name (e.g. `gene-mini`).
- If the mini's Tailscale hostname isn't `gene-mini`, rename it on the admin page or set `CLAUDEHOME_HOST` on your clients later.

#### 1b. Enable SSH

**System Settings → General → Sharing → Remote Login: on**

#### 1c. Authorize your SSH key

From your client, copy your key to the mini using the mini's actual account name:

```sh
ssh-copy-id <mini-user>@gene-mini
```

Verify it works without a password prompt:

```sh
ssh -o BatchMode=yes <mini-user>@gene-mini echo ok   # must print: ok
```

Once this returns `ok`, every remaining step can run remotely — no need to return to the mini.

#### 1d. Install tmux

```sh
ssh gene-mini 'brew install tmux'
```

#### 1e. Install Claude Code

Skip if `claude` is already installed on the mini.

```sh
ssh gene-mini 'curl -fsSL https://claude.ai/install.sh | bash'
```

#### 1f. Fix the SSH PATH

macOS SSH sessions load `~/.zshenv` but **not** `~/.zshrc`, so tools installed via Homebrew are invisible over SSH by default. Without this step, `ssh gene-mini 'claude'` returns `command not found`.

Apple Silicon:
```sh
echo 'export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"' \
  | ssh gene-mini 'cat >> ~/.zshenv'
```

Intel Mac:
```sh
echo 'export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"' \
  | ssh gene-mini 'cat >> ~/.zshenv'
```

Verify:
```sh
ssh gene-mini 'which claude tmux'   # both paths should print
```

#### 1g. Create the projects root

```sh
ssh gene-mini 'mkdir -p ~/projects/claudecode'
```

#### 1h. Log Claude Code in (first time only)

A fresh `claude` needs OAuth credentials. This requires an interactive TTY:

```sh
ssh -t <mini-user>@gene-mini claude
```

Claude prints a login URL. Open it in any browser, complete sign-in, paste the code back. Credentials save to `~/.claude/` on the mini and persist across reboots.

---

### 2. Mac client (one-time per Mac)

```sh
# Install Tailscale (same tailnet as the mini)
brew install --cask tailscale

# Install fzf (optional — enables arrow-key picker)
brew install fzf

# Clone and install
git clone git@github.com:getarobo/claudehome.git ~/projects/claudehome
cd ~/projects/claudehome
./install.sh
```

If `install.sh` warns that `~/.local/bin` isn't in your `PATH`:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Verify: `which claudehome` should print `~/.local/bin/claudehome`.

**Username mismatch?** If `echo $USER` on your Mac differs from `<mini-user>`, add an SSH config entry:

```sh
echo -e "\nHost gene-mini\n  User <mini-user>" >> ~/.ssh/config
```

Or set the env var:
```sh
echo 'export CLAUDEHOME_USER=<mini-user>' >> ~/.zshrc && source ~/.zshrc
```

---

### 3. Windows client — PowerShell 7+ (one-time per PC)

#### 3a. Install prerequisites

```powershell
winget install Microsoft.PowerShell    # PowerShell 7 (if not already present)
winget install Tailscale.Tailscale     # same tailnet as the mini
winget install junegunn.fzf            # optional — arrow-key picker
where.exe ssh                          # verify OpenSSH is present
```

#### 3b. Generate and authorize an SSH key

Check for an existing key:
```powershell
Test-Path "$HOME\.ssh\id_ed25519.pub"   # true = already have one
```

If missing, generate one:
```powershell
ssh-keygen -t ed25519 -C "my-pc"
```

Copy the key to the mini:
```powershell
ssh-copy-id <mini-user>@gene-mini
```

If `ssh-copy-id` isn't available, do it manually:
```powershell
$pub = Get-Content "$HOME\.ssh\id_ed25519.pub"
ssh <mini-user>@gene-mini "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Verify:
```powershell
ssh -o BatchMode=yes <mini-user>@gene-mini echo ok   # must print: ok
```

#### 3c. Install the CLI

```powershell
git clone git@github.com:getarobo/claudehome.git $HOME\projects\claudehome
Set-Location $HOME\projects\claudehome
.\install.ps1
```

Open a **new** PowerShell window, then run `claudehome`.

**Username mismatch?** If `$env:USERNAME` on your PC differs from `<mini-user>`, add an SSH config entry (recommended):

```powershell
Add-Content "$HOME\.ssh\config" "`nHost gene-mini`n  User <mini-user>`n"
```

Or set the env var permanently:
```powershell
[Environment]::SetEnvironmentVariable('CLAUDEHOME_USER', '<mini-user>', 'User')
# Open a new shell after setting — takes effect in new sessions only
```

> **Note:** If you downloaded the repo as a ZIP instead of cloning, run `Unblock-File .\install.ps1` before executing. `git clone` doesn't require this.

**Terminal tip:** Use WezTerm or Windows Terminal for best rendering. The `.cmd` shim also works from `cmd.exe`.

---

### 4. iPhone (not yet)

Deferred. Near-term: use **Blink Shell** with a manual `ssh -t <mini-user>@gene-mini tmux new-session -A -s myproject` command. A scripted `claudehome` for iOS ships later.

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

All configuration is via environment variables. No config file.

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDEHOME_HOST` | `gene-mini` | Tailscale hostname of the Mac mini |
| `CLAUDEHOME_USER` | local `$USER` | SSH username on the Mac mini |
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

**`Permission denied (publickey)`**
The SSH key isn't in the right user's `authorized_keys`. Confirm the mini's account name, then re-authorize:
```sh
ssh-copy-id <mini-user>@gene-mini
ssh -o BatchMode=yes <mini-user>@gene-mini echo ok   # must print: ok
```
Also verify permissions on the mini: `~/.ssh` must be `700`, `~/.ssh/authorized_keys` must be `600`.

**`cannot reach gene-mini via SSH`**
Run `tailscale status` on both devices — both should list the other as connected. Confirm Remote Login is on in System Settings. Test with `ssh gene-mini echo ok`.

**`no projects found in ~/projects/claudecode`**
Create a project on the mini:
```sh
ssh gene-mini 'mkdir -p ~/projects/claudecode/my-first-project'
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
ssh gene-mini 'tmux kill-session -t claudehome-<project-name>'
```

---

## Non-goals (v1)

- Web UI or native mobile app
- iPhone client (planned — Blink Shell in the meantime)
- Project scaffolding (`claudehome new`) — create directories manually
- Session management subcommands (`ls`, `kill`, `attach <name>`)
- Automatic cleanup of orphaned sessions
- Multi-user or shared Mac mini

---

## License

MIT.
