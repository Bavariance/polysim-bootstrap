# VS Code terminal clipboard over Remote-SSH (zellij panes)

**Symptom.** In a zellij pane inside VS Code's integrated terminal on a remote host,
`Ctrl+V` does nothing and `Ctrl+Shift+V` reaches Claude Code as an *image*-paste
prompt. Right-click → Paste is the only thing that works.

**Cause.** VS Code *forwards* the keystroke to the shell instead of handling it as a
paste, so the application inside the terminal sees the raw key and VS Code never
pastes. It is not a zellij problem: this config sets `keybinds clear-defaults=true`
and never binds `Ctrl+V`, and with no `copy_command` set zellij uses **OSC 52**,
which is the correct mechanism for getting a remote selection into your *local*
clipboard.

**Fix — two halves, because they live on different machines.**

| Half | Where it lives | File |
|---|---|---|
| Settings | the **remote** host | `~/.vscode-server/data/Machine/settings.json` |
| Keybindings | your **laptop** | `keybindings.json` (client-side, cannot be set remotely) |

1. **Remote (already applied on globus, and versioned here):**
   `remote-machine-settings.json` → `~/.vscode-server/data/Machine/settings.json`.
   The load-bearing line is `"terminal.integrated.sendKeybindingsToShell": false`.
   Machine-scoped, so it covers every remote workspace on that host, not one repo.

2. **Local (you must do this once per laptop):** open
   `Preferences: Open Keyboard Shortcuts (JSON)` and add the three entries from
   `keybindings.json`. Copy them from the editor tab, not the terminal.

**Reload the window** after both (`Developer: Reload Window`).

**Verify:** focus a zellij pane, `Ctrl+V` pastes; select text and `Ctrl+Shift+C`
copies to your *local* clipboard via OSC 52; `Ctrl+C` still interrupts.

**Note:** `Ctrl+G` locks zellij's keybindings, which is useful when an application
inside a pane wants keys zellij would otherwise capture. It is not needed for paste
once the above is in place.
