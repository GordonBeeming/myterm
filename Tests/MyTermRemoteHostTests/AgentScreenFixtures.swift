import Foundation

/// What the three screen-only commands draw, read off a real terminal.
///
/// Captured from Claude Code 2.1.258 driven through a PTY at 100 columns by 30 rows, as
/// `visibleRows` reads it: trailing blanks already dropped from every row. Names, paths and
/// identifiers are replaced with stand-ins of the same shape. Every one of the three closed on a
/// single Escape.
enum AgentScreenFixtures {
    /// `/usage`. The dialog is taller than the terminal: the CLI scrolls it, so the
    /// banner is cut off the top and a "↓" in the bottom corner says there is more below. No
    /// "Esc to cancel" is on screen for this one, though Escape closes it all the same.
    static let usage: [String] = """
  ▝▝ ▝▝    /…/someone/projects/myterm

▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   Settings  Status   Config   Usage   Stats

   Session

   Total cost:            $0.0000
   Total duration (API):  0s
   Total duration (wall): 11s
   Total code changes:    0 lines added, 0 lines removed
   Usage:                 0 input, 0 output, 0 cache read, 0 cache write

   Current session
   ██████████▌                                        21% used
   Resets 5:40pm (Australia/Brisbane)

   Current week (all models)
   ███████████████████████████████████████████        86% used
   Resets Sep 12 at 3pm (Australia/Brisbane)
   +50% weekly limits promo through Sep 13 · clau.de/cc-50-promo

   Current week (Fable)
   ██████████████████████████████████████████████████ 100% used
   Resets Sep 12 at 3pm (Australia/Brisbane)

   What's contributing to your limits usage?
   Approximate, based on local sessions on this machine — does not include other devices or
   claude.ai
                                                                                                  ↓
""".components(separatedBy: "\n")

    /// `/status`. The banner stays; the dialog names the session, the working directory and the
    /// account, and ends with "Esc to cancel". (The real working directory wrapped over three rows;
    /// the stand-in fits on one.)
    static let status: [String] = """

 ▐▛███▛█   Claude Code v2.1.258
▝▜██████▀  Opus 5 (1M context) with high effort · Claude Max
  ▝▝ ▝▝    /…/someone/projects/myterm





▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   Settings  Status   Config   Usage   Stats

   Version:                 2.1.258
   Session name:            /rename to add a name
   Session ID:              3f2b1c9e-6d54-4a0b-9e21-7c8d5a4b3e10
   Session kind:            interactive
   Peer address:            uds:/tmp/cc-socks/48213.sock
   cwd:                     /Users/someone/projects/myterm
   Login method:            Claude Max account
   Organization:            someone@example.com's Organization
   Email:                   someone@example.com
   Claude Code on the web:  GitHub connected

   Model:                   opus[1m] (claude-opus-5[1m])
   MCP servers:             3 connected, 4 need auth, 1 pending, 1 disabled, 2 failed · /mcp
   Setting sources:         User settings

   Esc to cancel
""".components(separatedBy: "\n")

    /// `/help`. A three-column table of shortcuts, and "Esc to cancel".
    static let help: [String] = """

 ▐▛███▛█   Claude Code v2.1.258
▝▜██████▀  Opus 5 (1M context) with high effort · Claude Max
  ▝▝ ▝▝    /…/someone/projects/myterm









▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   Help  General   Commands   Custom commands

   Claude understands your codebase, makes edits with your permission, and executes commands —
   right from your terminal.
   Shortcuts
   ! for shell mode          double tap esc to clear input        ctrl + shift + _ to undo
   / for commands            shift + tab to auto-accept edits     ctrl + z to suspend
   @ for file paths          ctrl + o for verbose output          ctrl + v to paste images
   /btw for side question    ctrl + t to toggle tasks             opt + p to switch model
                             \\⏎ for newline                       ctrl + s to stash prompt
                                                                  ctrl + g to edit in $EDITOR
                                                                  /keybindings to customize

   For more help: https://code.claude.com/docs/en/overview

   Esc to cancel
""".components(separatedBy: "\n")

    /// The screen each dialog leaves behind once Escape closes it: the banner, the empty prompt and
    /// the status line. (`/usage` leaves a usage warning in place of the effort line.)
    static let prompt: [String] = """

 ▐▛███▛█   Claude Code v2.1.258
▝▜██████▀  Opus 5 (1M context) with high effort · Claude Max
  ▝▝ ▝▝    /…/someone/projects/myterm




















                                                                                  ● high · /effort
────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────
  📁 projects/myterm | 🤖 Opus 5 (1M context) | 🔥 high | Est. usage: $0.00                /rc
  ⏸ manual mode on · ← for agents
""".components(separatedBy: "\n")
}
