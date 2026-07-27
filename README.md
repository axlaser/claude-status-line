<div align="center">

# claude-statusline

**A rich, color-coded custom status line for [Claude Code](https://claude.ai/code) showing context usage, git state, costs, rate limits, and more**

[![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](#macos)
[![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)](#linux)
[![Windows](https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white)](#windows)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)](#macos)
[![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](#windows)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](#license)

---

Replaces Claude Code's default status bar with a detailed, color-coded dashboard
showing context usage, git state, costs, rate limits, and more — all inside a clean box frame.

![screenshot](assets/screenshot.png)

</div>

## Features

| Row | What it shows |
|-----|---------------|
| **repo** | Working directory (shortened relative to `$HOME`) and git branch with `↑ahead` / `↓behind` remote tracking, `+insertions` / `-deletions` / `~untracked`, and `⊟stash` count |
| **agent** | Agent name with compact context % and in/out tokens (when running with `--agent` flag); each active subagent also gets its own `agent` row with context bar, `used/window` tokens, model, reasoning effort (only when explicitly set), task title, and `○ working` / `✓ done` status |
| **model** | Active model (e.g. `Opus 4.7`), reasoning effort level, and ready/working indicator |
| **context** | Color-coded context bar with percentage and token count (green < 60%, yellow < 85%, red 85%+) |
| **tokens** | Cumulative session breakdown — `in` (fresh input), `cache↑` (cache writes), `cache↓` (cache reads), `out` (output) |
| **cost** | Session cost in USD, message count, wall-clock duration, and 5-hour/7-day rate limit usage with burn-rate arrows (`⇡` over pace / `⇣` under pace) and time until reset |
| **notifications** | Sound alerts and native OS toast popups for permission requests, task completion, context compaction, rate limit warnings, and context window warnings (enable during install) |

All rows are dynamic — empty rows are automatically hidden.

---

## Highlights

### Context awareness at a glance
The context bar changes color as your conversation grows — **green** when you have plenty of room, **yellow** as you approach 85%, and **red** when you're close to the limit. No more surprise context resets mid-task.

### Burn-rate arrows on rate limits
The rate-limit segments on the cost row don't just show usage — they show **pace**. An `⇡` arrow means you're burning tokens faster than the reset rate (slow down), while `⇣` means you're under pace with time until reset. Plan your session around real data instead of guessing.

### Live working indicator
The model row shows a real-time status — `● ready` when idle, or `○ working` while Claude is generating. You always know if the model is still thinking or waiting for you.

### Compact agent view
When running with `--agent`, the agent row shows context usage as a percentage and cumulative in/out tokens in a compact inline format — all the essentials without taking up extra rows.

### Per-subagent context tracking
Every active subagent gets its own row — context bar, `used/window` tokens, model, the task's title (e.g. `Apply README review fixes`; the agent type shows when no title is available), and live status (`○ working` while active, `✓ done` for 30 seconds after completion, then the row disappears). Long titles are truncated to 39 characters plus an ellipsis. Percentages are measured against each subagent's **real** context window — fed live by Claude Code or learned per model — so a 1M-window subagent isn't judged against a 200K bar.

**Reasoning effort** shows on a subagent row only when that agent was dispatched with an explicit effort — from an agent definition's `effort:` frontmatter, for example. It uses the same wording and colours as the model row, so `low effort` on an agent row reads the same as it does above. An agent that set no effort of its own shows **no** effort segment, and that's deliberate: Claude Code reports the field only when there's an override, so absence means "this agent set nothing of its own" rather than "unknown". What it actually runs at is Claude Code's business — the status line never displays a level it wasn't told, and never guesses one.

Absence is not proof the agent set nothing, though. The segment is also missing when the live feed has gone stale and the row is rebuilt from the subagent transcript, which carries no effort — so a still-running agent can lose its segment. The **Upgrading** note below covers one more case.

> **Upgrading:** this feature spans two scripts — the status line and the subagent feed handler — so re-run the install command for your platform to pick it up. Updating only `statusline.*` leaves the handler filtering the field out, and the row then looks exactly like the no-override case.

### Never miss a prompt
Sound alerts and native OS toast notifications fire on permission requests, task completion, context compaction, and rate limit warnings. Each event and channel (sound vs. visual) is independently toggleable — get pinged when Claude needs you, stay quiet when it doesn't.

---

## Installation

> **Note:** The installer will ask before overwriting any existing `statusLine` or `subagentStatusLine` configuration.
> Restart Claude Code after installing or updating.
>
> The git status segment requires git >= 2.15 (2017, when `git status --show-stash` and its porcelain `# stash` header were added). On older git the status line still works — it just renders no git segment.

---

<h3 id="macos"><img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS" height="40"></h3>

**Install:**

```bash
curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/macos/install.sh | bash
```

The installer checks for `jq` and offers to install it via Homebrew if missing.

**Update:**

Re-run the install command above — your other settings are preserved.

**Uninstall:**

```bash
curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/macos/uninstall.sh | bash
```

<details>
<summary><strong>Manual install</strong></summary>

1. **Install jq** (if you don't have it):
   ```bash
   brew install jq
   ```

2. **Download the scripts** to your Claude config directory:
   ```bash
   mkdir -p ~/.claude
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/macos/statusline.sh -o ~/.claude/statusline.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/macos/notify.sh -o ~/.claude/notify.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/macos/git-refresh.sh -o ~/.claude/git-refresh.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/macos/subagent-statusline.sh -o ~/.claude/subagent-statusline.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/assets/claude-icon.png -o ~/.claude/claude-icon.png
   chmod +x ~/.claude/statusline.sh ~/.claude/notify.sh ~/.claude/git-refresh.sh ~/.claude/subagent-statusline.sh
   ```

3. **Install terminal-notifier** (optional — for visual toast notifications):
   ```bash
   brew install terminal-notifier
   ```

4. **Create the notification config** — save as `~/.claude/notify-config.json`:
   ```json
   {
     "permission":        { "sound": true, "visual": true },
     "stop":              { "sound": true, "visual": true },
     "rate_limit":        { "sound": true, "visual": true, "threshold": 80 },
     "context_high":      { "sound": false, "visual": true, "threshold": 70 },
     "compaction_start":  { "sound": true, "visual": true },
     "compaction_done":   { "sound": true, "visual": true }
   }
   ```

5. **Add to your Claude Code settings** — edit `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "refreshInterval": 2
     },
     "subagentStatusLine": {
       "type": "command",
       "command": "~/.claude/subagent-statusline.sh"
     },
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit|Bash|NotebookEdit",
           "hooks": [{ "type": "command", "command": "~/.claude/git-refresh.sh", "async": true }]
         }
       ],
       "PermissionRequest": [
         {
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh permission", "async": true }]
         }
       ],
       "Stop": [
         {
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh stop", "async": true }]
         }
       ],
       "PreCompact": [
         {
           "matcher": "*",
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh compaction_start", "async": true }]
         }
       ],
       "PostCompact": [
         {
           "matcher": "*",
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh compaction_done", "async": true }]
         }
       ]
     }
   }
   ```

6. **Restart Claude Code** — the status line and notifications are now active.

</details>

---

<h3 id="linux"><img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux" height="40"></h3>

**Install:**

```bash
curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/linux/install.sh | bash
```

The installer detects your package manager (apt, dnf, pacman, zypper, apk) and offers to install `jq` if missing.

**Update:**

Re-run the install command above — your other settings are preserved.

**Uninstall:**

```bash
curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/linux/uninstall.sh | bash
```

<details>
<summary><strong>Manual install</strong></summary>

1. **Install jq** (if you don't have it):
   ```bash
   sudo apt install jq        # Debian/Ubuntu
   sudo dnf install jq        # Fedora/RHEL
   sudo pacman -S jq          # Arch
   ```

2. **Download the scripts** to your Claude config directory:
   ```bash
   mkdir -p ~/.claude
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/linux/statusline.sh -o ~/.claude/statusline.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/linux/notify.sh -o ~/.claude/notify.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/linux/git-refresh.sh -o ~/.claude/git-refresh.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/linux/subagent-statusline.sh -o ~/.claude/subagent-statusline.sh
   curl -fsSL https://raw.githubusercontent.com/axlaser/claude-statusline/master/assets/claude-icon.png -o ~/.claude/claude-icon.png
   chmod +x ~/.claude/statusline.sh ~/.claude/notify.sh ~/.claude/git-refresh.sh ~/.claude/subagent-statusline.sh
   ```

3. **Install libnotify** (optional — for visual toast notifications):
   ```bash
   sudo apt install libnotify-bin    # Debian/Ubuntu
   sudo dnf install libnotify        # Fedora/RHEL
   sudo pacman -S libnotify          # Arch
   ```

4. **Create the notification config** — save as `~/.claude/notify-config.json`:
   ```json
   {
     "permission":        { "sound": true, "visual": true },
     "stop":              { "sound": true, "visual": true },
     "rate_limit":        { "sound": true, "visual": true, "threshold": 80 },
     "context_high":      { "sound": false, "visual": true, "threshold": 70 },
     "compaction_start":  { "sound": true, "visual": true },
     "compaction_done":   { "sound": true, "visual": true }
   }
   ```

5. **Add to your Claude Code settings** — edit `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "refreshInterval": 2
     },
     "subagentStatusLine": {
       "type": "command",
       "command": "~/.claude/subagent-statusline.sh"
     },
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit|Bash|NotebookEdit",
           "hooks": [{ "type": "command", "command": "~/.claude/git-refresh.sh", "async": true }]
         }
       ],
       "PermissionRequest": [
         {
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh permission", "async": true }]
         }
       ],
       "Stop": [
         {
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh stop", "async": true }]
         }
       ],
       "PreCompact": [
         {
           "matcher": "*",
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh compaction_start", "async": true }]
         }
       ],
       "PostCompact": [
         {
           "matcher": "*",
           "hooks": [{ "type": "command", "command": "~/.claude/notify.sh compaction_done", "async": true }]
         }
       ]
     }
   }
   ```

6. **Restart Claude Code** — the status line and notifications are now active.

</details>

---

<h3 id="windows"><img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows" height="40"></h3>

**Install:**

```powershell
irm https://raw.githubusercontent.com/axlaser/claude-statusline/master/windows/install.ps1 | iex
```

No additional dependencies required — uses built-in PowerShell.

**Update:**

Re-run the install command above — your other settings are preserved.

**Uninstall:**

```powershell
irm https://raw.githubusercontent.com/axlaser/claude-statusline/master/windows/uninstall.ps1 | iex
```

<details>
<summary><strong>Manual install</strong></summary>

1. **Download the scripts** to your Claude config directory:
   ```powershell
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/axlaser/claude-statusline/master/windows/statusline.ps1" -OutFile "$env:USERPROFILE\.claude\statusline.ps1"
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/axlaser/claude-statusline/master/windows/notify.ps1" -OutFile "$env:USERPROFILE\.claude\notify.ps1"
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/axlaser/claude-statusline/master/windows/git-refresh.ps1" -OutFile "$env:USERPROFILE\.claude\git-refresh.ps1"
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/axlaser/claude-statusline/master/windows/subagent-statusline.ps1" -OutFile "$env:USERPROFILE\.claude\subagent-statusline.ps1"
   Invoke-WebRequest -Uri "https://raw.githubusercontent.com/axlaser/claude-statusline/master/assets/claude-icon.png" -OutFile "$env:USERPROFILE\.claude\claude-icon.png"
   ```

2. **Install BurntToast** (optional — for visual toast notifications):
   ```powershell
   Install-Module -Name BurntToast -Scope CurrentUser
   ```

3. **Create the notification config** — save as `%USERPROFILE%\.claude\notify-config.json`:
   ```json
   {
     "permission":        { "sound": true, "visual": true },
     "stop":              { "sound": true, "visual": true },
     "rate_limit":        { "sound": true, "visual": true, "threshold": 80 },
     "context_high":      { "sound": false, "visual": true, "threshold": 70 },
     "compaction_start":  { "sound": true, "visual": true },
     "compaction_done":   { "sound": true, "visual": true }
   }
   ```

4. **Add to your Claude Code settings** — edit `%USERPROFILE%\.claude\settings.json`:

   Replace `YOUR_USERNAME` with your Windows username in all paths below.

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell -NoProfile -File C:/Users/YOUR_USERNAME/.claude/statusline.ps1",
       "refreshInterval": 2
     },
     "subagentStatusLine": {
       "type": "command",
       "command": "powershell -NoProfile -File C:/Users/YOUR_USERNAME/.claude/subagent-statusline.ps1"
     },
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit|Bash|NotebookEdit",
           "hooks": [{ "type": "command", "command": "powershell -NoProfile -File C:/Users/YOUR_USERNAME/.claude/git-refresh.ps1", "async": true }]
         }
       ],
       "PermissionRequest": [
         {
           "hooks": [{ "type": "command", "command": "powershell -NoProfile -File C:/Users/YOUR_USERNAME/.claude/notify.ps1 permission", "async": true }]
         }
       ],
       "Stop": [
         {
           "hooks": [{ "type": "command", "command": "powershell -NoProfile -File C:/Users/YOUR_USERNAME/.claude/notify.ps1 stop", "async": true }]
         }
       ],
       "PreCompact": [
         {
           "matcher": "*",
           "hooks": [{ "type": "command", "command": "powershell -NoProfile -File C:/Users/YOUR_USERNAME/.claude/notify.ps1 compaction_start", "async": true }]
         }
       ],
       "PostCompact": [
         {
           "matcher": "*",
           "hooks": [{ "type": "command", "command": "powershell -NoProfile -File C:/Users/YOUR_USERNAME/.claude/notify.ps1 compaction_done", "async": true }]
         }
       ]
     }
   }
   ```

5. **Restart Claude Code** — the status line and notifications are now active.

</details>

---

### From a cloned repo

```bash
git clone https://github.com/axlaser/claude-statusline.git
cd claude-statusline
bash macos/install.sh      # macOS
bash linux/install.sh      # Linux
.\windows\install.ps1      # Windows
```

To update, `git pull` and re-run the install script. To uninstall, run the uninstall script for your platform.

### Without piping to a shell

Piping a URL into `bash` or `iex` runs code you have not read. If you would rather
not, download the installer first, read it, then run it:

```bash
curl -fsSL -O https://raw.githubusercontent.com/axlaser/claude-statusline/master/install/install.sh
less install.sh          # read it
bash install.sh
```

```powershell
Invoke-WebRequest -UseBasicParsing -OutFile install.ps1 `
  -Uri https://raw.githubusercontent.com/axlaser/claude-statusline/master/install/install.ps1
Get-Content install.ps1  # read it
.\install.ps1
```

The installer downloads a prebuilt binary, verifies its SHA-256 against the
`checksums.txt` published with the release, and only then places it and sets the
execute bit. A checksum that cannot be fetched or computed stops the install —
there is no path that skips verification.

If the [GitHub CLI](https://cli.github.com) is installed, the installer also
verifies the release's build-provenance attestation. That check is skipped when
`gh` is absent, and you can demand it instead:

```bash
bash install.sh --require-attestation
```

To verify by hand at any time:

```bash
gh attestation verify ~/.claude/bin/claude-statusline \
  --repo axlaser/claude-statusline \
  --signer-workflow axlaser/claude-statusline/.github/workflows/release.yml
```

To install a specific release rather than the latest, set
`CLAUDE_STATUSLINE_VERSION` to its tag.

---

## Customization

### Refresh Interval

By default the status line updates after each assistant message. To also refresh on a timer (useful for keeping the clock and git status current), add `refreshInterval` to your settings. The installer sets this to `2` on every platform:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "refreshInterval": 2
  }
}
```

This refreshes every 2 seconds. On **Windows**, `refreshInterval: 2` is required — PowerShell's startup overhead makes 1-second intervals unreliable. On **macOS/Linux** you can lower it to `1` (the minimum) for faster updates, at the cost of spawning the script twice as often.

### Padding

Add horizontal spacing around the status line:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2
  }
}
```

### Debug Logging

Both scripts write debug logs to help troubleshoot issues:

| Platform | Log location |
|----------|-------------|
| macOS / Linux | `~/.claude/statusline-debug.log` |
| Windows | `%USERPROFILE%\.claude\statusline-debug.log` |

### Notifications

The installer can configure both **sound** and **visual** (native OS toast) notifications. Each channel is independently toggleable per event type.

#### Events

| Event | Trigger |
|-------|---------|
| Permission request | Claude shows a permission dialog |
| Task complete | Claude finishes responding |
| Compaction start | Context compaction begins |
| Compaction done | Context compaction completes |
| Context high | Context window usage >= 70% (configurable) |
| Rate limit | Rate limit usage >= 80% (configurable) |

#### Sound

Platform-native sounds — no additional software needed:

| Platform | Permission / Compaction start | Complete / Compaction done | Warning (rate limit / context) | Player |
|----------|-------------------------------|----------------------------|-------------------------------|--------|
| macOS | Tink | Glass | Sosumi | `afplay` |
| Linux | freedesktop bell | freedesktop complete | freedesktop dialog-warning | `paplay` / `aplay` |
| Windows | System Exclamation | System Asterisk | System Hand | Built-in (`SystemSounds`) |

#### Visual (toast notifications)

| Platform | Tool | Install |
|----------|------|---------|
| macOS | [terminal-notifier](https://github.com/julienXX/terminal-notifier) | `brew install terminal-notifier` |
| Linux | notify-send | `sudo apt install libnotify-bin` (or equivalent for your distro) |
| Windows | [BurntToast](https://github.com/Windos/BurntToast) | `Install-Module -Name BurntToast -Scope CurrentUser` |

The installer offers to install these automatically. If the visual tool is missing, sound notifications still work — visual silently degrades.

Toast notifications display the Claude icon ([source](https://commons.wikimedia.org/wiki/File:Claude_AI_symbol.svg), public domain). The installer copies it to `~/.claude/claude-icon.png` automatically.

#### Configuration

Notification settings are stored in `~/.claude/notify-config.json`:

```json
{
  "permission":        { "sound": true, "visual": true },
  "stop":              { "sound": true, "visual": true },
  "rate_limit":        { "sound": true, "visual": true, "threshold": 80 },
  "context_high":      { "sound": false, "visual": true, "threshold": 70 },
  "compaction_start":  { "sound": true, "visual": true },
  "compaction_done":   { "sound": true, "visual": true }
}
```

Edit this file directly to toggle individual channels or adjust thresholds. The installer creates it with defaults on first run.

To enable after initial install, re-run the installer and answer **y** to the notification prompts. To disable, run the uninstaller — it removes notification hooks while preserving your other settings.

---

## Troubleshooting

<details>
<summary><strong>Status line not appearing</strong></summary>

- Verify the script path in `settings.json` is correct
- macOS/Linux: confirm the script is executable (`chmod +x ~/.claude/statusline.sh`)
- Restart Claude Code after changing settings
- Check the debug log for errors

</details>

<details>
<summary><strong>jq: command not found</strong></summary>

Install jq for your platform:
```bash
brew install jq              # macOS (Homebrew)
sudo apt install jq          # Debian/Ubuntu
sudo dnf install jq          # Fedora/RHEL
sudo pacman -S jq            # Arch
```
Or download from [jqlang.github.io/jq](https://jqlang.github.io/jq/download/).

</details>

<details>
<summary><strong>Context percentage shows 0% on first message</strong></summary>

This is normal. Claude Code doesn't report context usage until after the first API response. The bar will populate on the second refresh.

</details>

<details>
<summary><strong>Rate limits not showing</strong></summary>

Rate limit data is only available for Claude.ai Pro and Max subscribers. API users (Anthropic Console) won't see rate limit data on the cost row. The data also only appears after the first API response in a session.

</details>

<details>
<summary><strong>Notification sounds not playing</strong></summary>

- Verify the script exists and is executable: `ls -la ~/.claude/notify.sh`
- Test directly: `~/.claude/notify.sh permission` (should play a sound)
- Check hooks are configured: `jq '.hooks' ~/.claude/settings.json`
- Linux: ensure PulseAudio/PipeWire is running (`paplay` requires it) or ALSA is available (`aplay`)
- Windows: verify `%USERPROFILE%\.claude\notify.ps1` exists, test with `powershell -File ~\.claude\notify.ps1 permission`
- Restart Claude Code after installation — hooks are loaded at startup

</details>

<details>
<summary><strong>Visual toast notifications not appearing</strong></summary>

**macOS:** terminal-notifier posts notifications under its own bundle ID, which macOS may silence by default. Go to **System Settings > Notifications > terminal-notifier** and enable **Allow Notifications**. If terminal-notifier doesn't appear in the list, run `terminal-notifier -title "Test" -message "Hello"` once to register it, then check again.

**Linux:** Ensure your desktop environment supports notifications (GNOME, KDE, XFCE, etc.). Test with `notify-send "Test" "Hello"`. Wayland compositors may require additional configuration.

**Windows:** BurntToast requires the Windows notification center. Test with `New-BurntToastNotification -Text "Test", "Hello"`. If notifications are suppressed, check **Settings > System > Notifications** and ensure notifications are enabled for PowerShell.

**All platforms:** Set `STATUSLINE_DEBUG=1` and check `~/.claude/statusline-debug.log` for `notify:` entries to confirm the script is running and whether the visual tool was found.

</details>

<details>
<summary><strong>Script errors in the debug log</strong></summary>

Check `~/.claude/statusline-debug.log` for `READ/PARSE FAILED` or `UNHANDLED` entries. Common causes:
- Claude Code passed unexpected JSON (check `stdin head:` in the log)
- Permission issues writing to the temp directory

</details>

---

## How It Works

Claude Code pipes a JSON object to the script's stdin on each update. The JSON contains session data — model info, context window usage, cost, rate limits, transcript path, and more. The script parses this data, optionally reads the conversation transcript for additional metrics (message count, token breakdown, idle/working state), and outputs ANSI-colored text that Claude Code renders as the status bar.

Git status is cached for up to 5 seconds and invalidated as soon as `.git/index` changes (or immediately by the git-refresh hook after file-modifying tools), so it stays effectively real-time without re-running git on every refresh. Transcript data is cached by file mtime to keep refresh times fast even in large repositories.

Subagent rows are fed by Claude Code's `subagentStatusLine` feature. The installer registers a small handler (`subagent-statusline.sh` / `.ps1`, installed to `~/.claude/`) that receives the live tasks payload — each subagent's model, context window size, status, token count, and task description — and tees it to a session-scoped state file in the OS temp directory (`statusline-tasks-<session-id>.json`). The handler prints nothing, so Claude Code's own agent panel keeps its default rendering. Per-task `model` and `contextWindowSize` require Claude Code >= v2.1.205; on older versions (or before the feed delivers data), the status line falls back to parsing subagent transcripts. Task titles come from the feed's `description` field, so they require the handler to be up to date as well — with an older installed handler, rows gracefully fall back to showing the agent type.

On the transcript fallback path, each subagent's context window is resolved by checking the session's own model first, then a learned map, then a seed table, then a 200K default. A subagent running the same model as the session inherits that session's window directly — matched on the base model id, so a variant spelling like `claude-opus-5[1m]` and a bare `claude-opus-5` count as the same model. That makes a newly released model correct on a subagent's first appearance, with no prior observation. Beyond that, the status line records each main session's model → window pair to `~/.claude/statusline-model-windows.json`, so it learns real, plan-accurate context windows automatically — new models are picked up without any repo update. The seed table covers current documented models (1M for Fable 5, Opus 4.6+, Sonnet 5, and Sonnet 4.6; 200K for Haiku 4.5, Sonnet 4.5, and Opus 4.5). The uninstaller removes the handler registration, the handler script, and the learned map.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
