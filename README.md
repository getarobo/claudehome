Version 1.0.2.1 — 2026-04-30

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

From your client, copy your public key to the mini using the mini's actual account name.

**Mac client:**
```sh
ssh-copy-id <mini-user>@<mini-host>
```

**Windows client** (no `ssh-copy-id` in OpenSSH for Windows — append manually with password auth):
```powershell
# Generate a key first if you don't have one (press Enter twice for no passphrase):
ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519 -C $env:COMPUTERNAME

$pub = (Get-Content $HOME\.ssh\id_ed25519.pub -Raw).Trim()
ssh <mini-user>@<mini-host> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
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
./install_client.sh
```

The installer wizard handles the rest:

- Checks Tailscale is running (links to download if not)
- Prompts for your mini's hostname and SSH username
- Installs `fzf` via Homebrew if available (enables arrow-key picker)
- Appends `~/.local/bin` to your PATH in `~/.zshrc` if needed
- Saves config to `~/.claudehomerc`

The wizard does **not** generate or copy your SSH key. After install, follow §1c above to authorize your key on the mini, then verify with `ssh -o BatchMode=yes <mini-user>@<mini-host> echo ok`. The wizard prints the exact command to run.

Re-running `./install_client.sh` is safe — prompts are skipped for values already configured.

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
.\install_client.ps1
```

The installer wizard handles the rest:

- Checks Tailscale is running (links to download if not)
- Prompts for your mini's hostname and SSH username
- Installs `fzf` via winget if available (enables arrow-key picker)
- Adds `<repo>\bin` to your user PATH
- Saves config to `~/.claudehomerc`

The wizard does **not** generate or copy your SSH key — Windows OpenSSH lacks `ssh-copy-id` and key handling is brittle to automate. After install, follow §1c above to authorize your key on the mini, then verify with `ssh -o BatchMode=yes <mini-user>@<mini-host> echo ok`. The wizard prints the exact command to run.

Open a **new** PowerShell window after install, then run `claudehome`.

Re-running `.\install_client.ps1` is safe — prompts are skipped for values already configured.

> **Note:** If you downloaded the repo as a ZIP instead of cloning, run `Unblock-File .\install_client.ps1` before executing. `git clone` doesn't require this.

**Terminal tip:** Use WezTerm or Windows Terminal for best rendering. The `.cmd` shim also works from `cmd.exe`.

---

### 4. iPhone

The iPhone client is **any iOS SSH app** + Tailscale + the `claudehome` CLI installed on the mini in *local mode* (so SSH'ing in and typing `claudehome` gives you the same picker as on the desktop, without a loopback SSH).

**1. Install Tailscale on iPhone** — App Store → "Tailscale" → log in with the same account as the mini → toggle on.

**2. Install an SSH client.** Recommended:

- **Termius** (free tier is enough) — polished UI, real tmux support. Free tier limitation: no iCloud key sync, but you only have one phone.
- **Blink Shell** ($, ~\$20/yr) — adds Mosh (resilient over flaky cellular), custom on-screen keyboards. Worth it if you'll use this every day.
- *Skip iSH* — it's a local Linux emulator on the phone, not an SSH client. Wrong tool for this.

**3. Generate an SSH key in the app and authorize it on the mini.** In Termius: *Vaults → Keys → + → Generate* (Ed25519). Share/copy the public key, then on any machine that already has SSH access:

```sh
echo '<paste ssh-ed25519 AAAA... line>' | ssh <mini-host> 'cat >> ~/.ssh/authorized_keys'
```

**4. Add a host entry.** In Termius: *Vaults → Hosts → + →* Hostname `<mini-host>`, Username `<mini-user>`, Key = the one you just made.

**5. Install claudehome on the mini in local mode** (one-time, on the mini itself):

```sh
cd /path/to/claudehome
./install_server.sh
```

This symlinks the `claudehome` CLI into your PATH on the mini and writes `CLAUDEHOME_LOCAL=1`. Now SSH'ing in and typing `claudehome` opens the picker locally — no loopback SSH.

**6. Connect.** Tap the host in Termius. At the mini's prompt, type `claudehome`. Same picker, same `[new project]` flow. Detach with `Ctrl-b d` (Termius and Blink both make `Ctrl` a one-tap key on the on-screen bar).

---

## Usage

```sh
claudehome
```

A picker shows every project under `~/projects/claudecode` on the mini, annotated with session state. Active sessions are ordered by recency (most-recently-used at top); idle projects sit below them alphabetically; the `[new project]` option is always the last row:

```
▸ my-api-project  [active 2h ago]
  landing-page    [active 1d ago]
  side-tool       [idle]
  [new project]
```

Pick an existing project and you're in. Pick `[new project]` and you're prompted for a name — `claudehome` creates the directory on the mini and starts a fresh session there. Names use the same allowlist as env vars (letters, digits, `.` `_` `-`); duplicates are refused with a retry, empty input cancels.

### Key bindings

| Action | Keys |
|---|---|
| Detach (leave session running) | `Ctrl-b` then `d` |
| Exit Claude Code | `/exit` or `Ctrl-D` |
| Scroll up/down | `Ctrl-b` then `[`, then arrow keys or Page Up/Down. Press `q` to exit. |

> `Ctrl-b` is the tmux prefix — two separate keystrokes: hold `Ctrl+b` together, release, then press the next key.

**Enable mouse scrolling** (recommended — add once on the Mac mini):

```sh
echo 'set -g mouse on' >> ~/.tmux.conf && tmux source ~/.tmux.conf
```

After this, mouse wheel scrolls directly inside tmux without needing scroll mode.

**Disconnect** (close lid, kill terminal, lose Tailscale): nothing on the mini changes. Reconnect later with `claudehome` and pick the same project.

---

## Sending files

`claudehome` is a session-attach tool — it doesn't transfer files. For that, use any SFTP client. Your existing Tailscale hostname and SSH key already work; nothing new to configure.

> Tailscale doesn't replace SFTP — it's a network layer underneath. To an SFTP client, your Mac mini is just a regular hostname reachable over SSH on port 22. There's no Tailscale-specific setting inside the SFTP client.

| Platform | Recommended client | Where |
|---|---|---|
| Mac | **Cyberduck** | https://cyberduck.io |
| Windows | **WinSCP** | https://winscp.net |
| Cross-platform | **FileZilla** | https://filezilla-project.org |

**Cyberduck (Mac)** — *Open Connection* → **SFTP (SSH File Transfer Protocol)**:

- Server: your `CLAUDEHOME_HOST` value (Tailscale hostname)
- Username: your `CLAUDEHOME_USER` value
- SSH Private Key: `~/.ssh/id_ed25519`

Connect, then navigate to `projects/claudecode/<project>/`.

**WinSCP (Windows)** — *New Site* → File protocol: **SFTP**:

- Host name: your Tailscale hostname
- User name: your mini SSH user
- *Advanced → SSH → Authentication →* Private key file: `~/.ssh/id_ed25519`

Modern WinSCP reads OpenSSH keys directly; older versions prompt to convert to `.ppk` once.

Files dropped into a project folder are visible in the next `claudehome` attach to that project. If Tailscale drops on the client, the SFTP connection drops too — same as `claudehome`. Reconnect Tailscale and retry.

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
Run the installer (`./install_client.sh` or `.\install_client.ps1`) to configure, or set the variable manually:
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

- Web UI or native mobile app (iPhone access is solved via Termius/Blink + Tailscale + local-mode CLI on the mini — see Section 4)
- `claudehome new <name>` subcommand — use the `[new project]` picker option instead (no extra CLI surface added)
- Session management subcommands (`ls`, `kill`, `attach <name>`)
- Automatic cleanup of orphaned sessions
- Multi-user or shared Mac mini
- Server-side bootstrap script (mini setup is manual per Section 1)

---

## License

MIT.
