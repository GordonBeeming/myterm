# Keyboard shortcuts

MyTerm exposes its shortcuts through native macOS menus. Pane and navigation keys follow cmux where that makes sense. The selected content decides how zoom behaves: a browser tab changes its own page zoom, while a terminal tab changes the active workspace's persisted font-size override.

## Workspaces

| Action | Shortcut |
| --- | --- |
| New workspace | <kbd>⌘N</kbd> |
| New folder | <kbd>⇧⌘N</kbd> |
| Rename workspace | <kbd>⇧⌘R</kbd> |
| Zoom out browser / decrease terminal font size | <kbd>⌘-</kbd> |
| Zoom in browser / increase terminal font size | <kbd>⌘=</kbd> |
| Close workspace | <kbd>⇧⌘W</kbd> |
| Previous / next workspace | <kbd>⌃⌘[</kbd> / <kbd>⌃⌘]</kbd> |
| Select workspace 1–9 | <kbd>⌘1</kbd> … <kbd>⌘9</kbd> |
| Toggle sidebar | <kbd>⌘B</kbd> |

## Tabs

| Action | Shortcut |
| --- | --- |
| New terminal tab | <kbd>⌘T</kbd> |
| New browser tab | <kbd>⇧⌘L</kbd> |
| Rename selected tab | <kbd>⌥⌘R</kbd> |
| Previous / next tab in the focused pane | <kbd>⌃⇧Tab</kbd> / <kbd>⌃Tab</kbd> |
| Select tab 1–9 | <kbd>⌃1</kbd> … <kbd>⌃9</kbd> |

## Browser

These commands apply only when the focused pane's selected tab is a browser. They do not intercept the same keystrokes while a terminal is selected.

| Action | Shortcut |
| --- | --- |
| Reload | <kbd>⌘R</kbd> |
| Focus and select the address | <kbd>⌘L</kbd> |
| Back / forward | <kbd>⌘[</kbd> / <kbd>⌘]</kbd> |
| Find on page | <kbd>⌘F</kbd> |
| Zoom out / in | <kbd>⌘-</kbd> / <kbd>⌘=</kbd> |
| Reset page zoom | <kbd>⌘0</kbd> |

**Reload From Origin** and **Stop Loading** remain available in the Browser menu. They intentionally have no global shortcut, so browser commands do not steal the existing rename shortcut or Escape's native cancel behavior.

## Panes

| Action | Shortcut |
| --- | --- |
| Split right | <kbd>⌘D</kbd> |
| Split below | <kbd>⇧⌘D</kbd> |
| Close focused pane or tab | <kbd>⌘W</kbd> |
| Focus pane left / right | <kbd>⌥⌘←</kbd> / <kbd>⌥⌘→</kbd> |
| Focus pane up / down | <kbd>⌥⌘↑</kbd> / <kbd>⌥⌘↓</kbd> |
| Move selected tab to previous / next pane | <kbd>⇧⌥⌘←</kbd> / <kbd>⇧⌥⌘→</kbd> |

Closing a pane, tab, or workspace asks for confirmation when it would terminate a foreground process. Quitting with <kbd>⌘Q</kbd> checks every terminal in the app; idle shells do not trigger the warning.

When a terminal pane has focus, MyTerm also handles the text-editing keys below. Apps that enable the Kitty keyboard protocol keep their enhanced key reporting.

| Action | Shortcut |
| --- | --- |
| Insert a newline without submitting | <kbd>⇧↩</kbd> |
| Delete to the start of the line | <kbd>⌘⌫</kbd> |
| Move to the start / end of the line | <kbd>⌘←</kbd> / <kbd>⌘→</kbd> |
| Move to the start / end of the editable text | <kbd>⌘↑</kbd> / <kbd>⌘↓</kbd> |

Folder colors and workspace emoji prefixes, background colors, pinning, moving, renaming, and closing are available from the relevant sidebar context menu. Returning to a workspace restores keyboard focus to the pane that was focused there most recently. Dragging a divider changes the local pane proportions and MyTerm restores those proportions with the workspace.
