# claude-setup

One command to put my Claude Code CLI in a known state: the **Caveman** output style, **RTK**, or both.

Both tools are worth having and neither installs in one step: Caveman is a markdown file plus a
`settings.json` key, RTK is a binary plus a global hook. This repo does both, the same way, on macOS
and Windows, and can undo them.

## Install

**macOS / Linux**

```bash
# both
curl -fsSL https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.sh | sh

# caveman only
curl -fsSL https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.sh | sh -s -- caveman

# rtk only
curl -fsSL https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.sh | sh -s -- rtk
```

**Windows (PowerShell 5.1+)**

```powershell
# both
irm https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.ps1 | iex

# caveman only
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.ps1))) caveman

# rtk only
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.ps1))) rtk
```

`| iex` cannot pass arguments, hence the `scriptblock` form for the selective installs.

**Restart Claude Code afterwards** — neither the hook nor the output style applies to a running session.

## What it touches

| Path | Component | What happens |
|---|---|---|
| `~/.claude/output-styles/caveman.md` | caveman | written from `styles/caveman.md` in this repo |
| `~/.claude/settings.json` | caveman | `"outputStyle": "caveman"` added |
| `~/.claude/settings.json` | rtk | `PreToolUse` hook added by `rtk init -g` |
| `~/.claude/RTK.md`, `~/.claude/CLAUDE.md` | rtk | written by `rtk init -g` |
| `~/.claude/CLAUDE.md` | both | a block between `<!-- BEGIN claude-setup -->` / `<!-- END claude-setup -->` |

Set `CLAUDE_CONFIG_DIR` to target a different config directory.

Safety properties, all covered by the checks in [Verifying](#verifying):

- **Idempotent.** Re-running changes nothing and creates no new backups. The `settings.json`
  check compares the *parsed* value, not the bytes, because RTK reformats the file with its own
  serializer.
- **Non-destructive.** `settings.json` is edited through `jq`/`python3`/`node` (PowerShell:
  `ConvertFrom-Json`), never with `sed`, so `apiKeyHelper`, `env`, `statusLine` and any hooks
  survive. Every modified file is backed up to `<name>.bak.<timestamp>` first.
- **Scoped.** In `CLAUDE.md`, only the text between the two markers is ever rewritten. `@RTK.md`
  and your own notes are preserved.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.sh | sh -s -- all --uninstall
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Nelahia/claude-setup/main/install.ps1))) all -Uninstall
```

Removes the style file, the `outputStyle` key, the RTK hook and the managed block. The `rtk` binary
is left in place — remove it with `brew uninstall rtk` (macOS) or by deleting
`~\.local\bin\rtk.exe` (Windows).

## Notes

- **The Caveman style is vendored,** not fetched from upstream at install time. `styles/caveman.md`
  is a pinned copy of [carlosduplar/caveman-output-style-claude-code](https://github.com/carlosduplar/caveman-output-style-claude-code).
  Nothing lands in the system prompt without passing through this repo first. Updating it is a
  deliberate commit here.
- **`keep-coding-instructions: true`** in that file is what keeps Claude Code's coding behaviour
  intact while changing only the voice. Do not drop it.
- **RTK telemetry is disabled by default** and `rtk init -g --auto-patch` never prompts for it.
  Check with `rtk telemetry status`.
- **RTK only filters Bash tool calls.** The `Read`, `Grep` and `Glob` tools bypass the hook.
- **The managed `CLAUDE.md` block is loaded on every session,** so it costs input tokens for as long
  as it exists. It is kept to a handful of lines on purpose.

## Troubleshooting

**`cannot safely launch non-Node Windows command shim: ...\claude.CMD; install a native .exe`**

`claude` installed via `npm i -g` or `pnpm add -g` on Windows resolves to a `claude.cmd` shim, not
a real executable. Spawning a `.cmd` safely needs `cmd.exe /c` with `shell:true` — a known
Windows arg-injection surface — so anything that launches a nested `claude` process (background
agents, local-session spawning) refuses outright. `install.ps1` prints a warning when it detects
this. Fix:

```powershell
irm https://claude.ai/install.ps1 | iex
npm uninstall -g @anthropic-ai/claude-code    # and/or: pnpm remove -g @anthropic-ai/claude-code
```

Then confirm `Get-Command claude` resolves to `...\.local\bin\claude.exe`.

## Verifying

The scripts honour `CLAUDE_CONFIG_DIR`, and `CLAUDE_SETUP_SRC` makes them read `styles/` and
`claude/` from a local checkout, so everything can be exercised without touching a real config:

```bash
rm -rf /tmp/cs && CLAUDE_SETUP_SRC=. CLAUDE_CONFIG_DIR=/tmp/cs sh install.sh
cp -R /tmp/cs /tmp/cs-snap
CLAUDE_SETUP_SRC=. CLAUDE_CONFIG_DIR=/tmp/cs sh install.sh   # every line must say "="
diff -r /tmp/cs-snap /tmp/cs                                 # must be empty
```

`rtk init --show` reports the live RTK state.

## Status

`install.sh` is tested on macOS (both components, cold install, idempotence, uninstall, and against
a populated real-world `settings.json`).

**`install.ps1` is untested.** It was written against the same behaviour but no Windows machine was
available to run it. Treat the first Windows run as a test, and check the `.bak.*` files if
something looks wrong.

## License

MIT
