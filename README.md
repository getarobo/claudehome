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

Three sections, in order:

1. **Install software** — at each device directly.
2. **Tailscale admin console** — register devices, name them, enable MagicDNS.
3. **SSH key setup** — generate keys on clients, authorize them on the mini.

> **Before you start:** Know your mini's account name — it may differ from what you expect. At the mini's Terminal: `echo $USER`. Use that value wherever you see `<mini-user>` below.

---

### 1. Install software

#### 1a. Mac mini (server)

Run all of the following at the mini directly (Terminal.app):

**Install Tailscale** — download from https://tailscale.com/download, open the app, log in to the tailnet you'll share with your clients. (Naming the device + enabling MagicDNS is §2.)

**Enable SSH** — System Settings → General → Sharing → **Remote Login: on**.

**Install tmux:**
```sh
brew install tmux
```

**Install Claude Code** (skip if `claude` is already installed):
```sh
curl -fsSL https://claude.ai/install.sh | bash
```

**Fix the SSH PATH.** macOS SSH sessions load `~/.zshenv` but **not** `~/.zshrc`, so Homebrew-installed tools are invisible to the non-interactive SSH commands `claudehome` issues from clients. Without this step, the client returns `tmux: command not found` on first attach.

Apple Silicon:
```sh
echo 'export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"' >> ~/.zshenv
```

Intel Mac:
```sh
echo 'export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"' >> ~/.zshenv
```

Verify (in a fresh shell):
```sh
which claude tmux   # both paths should print
```

**Create the projects root:**
```sh
mkdir -p ~/projects/claudehome-projects
```

**Log Claude Code in (one-time OAuth):**
```sh
claude
```
Claude prints a login URL. Open it in any browser, complete sign-in, paste the code back. Credentials save to `~/.claude/` on the mini and persist across reboots.

#### 1b. Mac client

```sh
brew install --cask tailscale
git clone git@github.com:getarobo/claudehome.git ~/projects/claudehome
cd ~/projects/claudehome
./install_client.sh
```

The installer wizard:

- Checks Tailscale is running (links to download if not)
- Prompts for your mini's hostname and SSH username
- Installs `fzf` via Homebrew if available (enables arrow-key picker)
- Appends `~/.local/bin` to your PATH in `~/.zshrc` if needed
- Saves config to `~/.claudehomerc`

The wizard does **not** set up your SSH key — that's §3.

Re-running `./install_client.sh` is safe — prompts are skipped for values already configured.

#### 1c. Windows client — PowerShell 7+

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

The installer wizard:

- Checks Tailscale is running (links to download if not)
- Prompts for your mini's hostname and SSH username
- Installs `fzf` via winget if available (enables arrow-key picker)
- Adds `<repo>\bin` to your user PATH
- Saves config to `~/.claudehomerc`

The wizard does **not** set up your SSH key — that's §3.

Open a **new** PowerShell window after install, then run `claudehome`.

Re-running `.\install_client.ps1` is safe — prompts are skipped for values already configured.

> **Note:** If you downloaded the repo as a ZIP instead of cloning, run `Unblock-File .\install_client.ps1` before executing. `git clone` doesn't require this.

**Terminal tip:** Use WezTerm or Windows Terminal for best rendering. The `.cmd` shim also works from `cmd.exe`.

#### 1d. iPhone

The iPhone client is **any iOS SSH app** + Tailscale + the `claudehome` CLI installed on the mini in *local mode* (so SSH'ing in and typing `claudehome` gives you the same picker as on desktop, without a loopback SSH).

**Install Tailscale on iPhone** — App Store → "Tailscale" → log in with the same account as the mini → toggle on.

**Install an SSH client.** Recommended:

- **Termius** (free tier is enough) — polished UI, real tmux support. Free tier limitation: no iCloud key sync, but you only have one phone.
- **Blink Shell** ($, ~\$20/yr) — adds Mosh (resilient over flaky cellular), custom on-screen keyboards. Worth it if you'll use this every day.
- *Skip iSH* — local Linux emulator on the phone, not an SSH client. Wrong tool for this.

**Install claudehome on the mini in local mode** (one-time, at the mini's Terminal):

```sh
cd /path/to/claudehome
./install_server.sh
```

This symlinks the `claudehome` CLI into your PATH on the mini and writes `CLAUDEHOME_LOCAL=1`. SSH'ing in from Termius and typing `claudehome` opens the picker locally — no loopback SSH.

After §3 sets up your SSH key, add a host entry in Termius (*Vaults → Hosts → + →* Hostname `<mini-host>`, Username `<mini-user>`, Key = your generated key) and tap to connect. At the mini's prompt, type `claudehome` — same picker, same `[new project]` flow. Detach with `Ctrl-b d` (Termius and Blink both make `Ctrl` a one-tap key on the on-screen bar).

---

### 2. Tailscale admin console

After installing Tailscale on every device (§1) and logging each into the same tailnet, open the admin console at https://login.tailscale.com/admin/machines.

- **Confirm every device appears** in the device list.
- **Rename each device** for cleaner hostnames — e.g., `mini`, `macbook`, `desktop`, `iphone`. Whatever you name the mini becomes its `<mini-host>` in `~/.claudehomerc`.
- **DNS tab → toggle MagicDNS on** so devices can reach each other by name instead of IP.

![Tailscale admin console — devices listed and named](docs/images/tailscale-admin.png)

---

### 3. SSH key setup

Generate a key on each client and authorize it on the mini.

#### 3a. Generate the key

**Mac client:**
```sh
ssh-keygen -t ed25519 -C "$(hostname)"   # press Enter twice for no passphrase
```

**Windows client:**
```powershell
ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519 -C $env:COMPUTERNAME
```

**iPhone (Termius):** *Vaults → Keys → + → Generate* (Ed25519). Use the share button to copy the public key string.

#### 3b. Authorize the key on the mini

Copy each client's public key (`~/.ssh/id_ed25519.pub` on Mac/PC, or the share-copied string from Termius). At the mini's Terminal:

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAA...your key line...' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Repeat the `echo` line for each client.

#### 3c. Verify

From each client:
```sh
ssh -o BatchMode=yes <mini-user>@<mini-host> echo ok   # must print: ok
```

If it prompts for a password instead of returning `ok`, the key wasn't authorized correctly — check that you pasted the entire key line (`ssh-ed25519 AAAA...comment`) onto its own line in the mini's `~/.ssh/authorized_keys`.

---

## Usage

```sh
claudehome
```

A picker shows every project under `~/projects/claudehome-projects` on the mini, annotated with session state. Active sessions are ordered by recency (most-recently-used at top); idle projects sit below them alphabetically; the `[new project]` option is always the last row:

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

Connect, then navigate to `projects/claudehome-projects/<project>/`.

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
# CLAUDEHOME_PROJECTS_DIR=~/projects/claudehome-projects
```

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDEHOME_HOST` | none — required | Tailscale hostname of the Mac mini |
| `CLAUDEHOME_USER` | local `$USER` / `$env:USERNAME` | SSH username on the Mac mini |
| `CLAUDEHOME_PROJECTS_DIR` | `~/projects/claudehome-projects` | Projects root on the Mac mini |

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
The SSH non-interactive shell can't find `claude`. Add its directory to `PATH` in `~/.zshenv` on the mini (not `~/.zshrc` — SSH doesn't load it). See §1a → *Fix the SSH PATH*.

**Orphaned tmux sessions**
If you delete a project directory, its session lingers. Remove it:
```sh
ssh <mini-host> 'tmux kill-session -t claudehome-<project-name>'
```

---

## Non-goals (v1)

- Web UI or native mobile app (iPhone access is solved via Termius/Blink + Tailscale + local-mode CLI on the mini — see §1d)
- `claudehome new <name>` subcommand — use the `[new project]` picker option instead (no extra CLI surface added)
- Session management subcommands (`ls`, `kill`, `attach <name>`)
- Automatic cleanup of orphaned sessions
- Multi-user or shared Mac mini
- Server-side bootstrap script (mini setup is manual per §1a)

---

## License

MIT.
