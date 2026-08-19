# Importing workspaces

**Workspace → Import Workspaces…** reads a JSON document and adds the workspaces it describes to
the sidebar.

The import always **appends**. Existing workspaces are never modified or removed, every imported
identifier is generated during the import, and folders are matched to existing ones by title — so
running the same import twice gives you a second copy rather than a corrupted first one.

The format is deliberately looser than myterm's own `workspace-state.json`, which makes it practical
to write by hand or to generate from another terminal's session state.

## Minimal document

```json
{
  "workspaces": [
    { "title": "API", "tabs": [{ "directory": "~/code/api" }] }
  ]
}
```

## Full document

```json
{
  "version": 1,
  "folders": [
    { "title": "Projects", "color": "purple", "isExpanded": true }
  ],
  "workspaces": [
    {
      "title": "API",
      "emoji": "🚀",
      "color": "green",
      "folder": "Projects",
      "isPinned": false,
      "tabs": [
        { "directory": "~/code/api", "title": "server" },
        { "url": "https://localhost:3000" }
      ]
    },
    {
      "title": "Web",
      "folder": "Projects",
      "layout": {
        "orientation": "horizontal",
        "weights": [0.6, 0.4],
        "children": [
          { "tabs": [{ "directory": "~/code/web" }] },
          {
            "orientation": "vertical",
            "children": [
              { "tabs": [{ "directory": "~/code/web/api" }] },
              { "tabs": [{ "directory": "~/code/web/docs" }] }
            ]
          }
        ]
      }
    }
  ]
}
```

## Fields

### Document

| Field | Meaning |
|---|---|
| `version` | Format version. Defaults to `1`. A newer version than the app understands is rejected. |
| `folders` | Optional folder declarations. A folder may also be created implicitly by naming it on a workspace. |
| `workspaces` | The workspaces to add. At least one is required. |

### Folder

| Field | Meaning |
|---|---|
| `title` | Required. Matched case-insensitively against folders that already exist. |
| `color` | `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `indigo`, `purple`, `pink`, or `gray`. Defaults to `blue`. |
| `isExpanded` | Defaults to `true`. |

### Workspace

| Field | Meaning |
|---|---|
| `title` | Falls back to the first directory's folder name, then to `Workspace`. |
| `emoji`, `color` | Optional sidebar decoration. |
| `folder` | Folder title. A folder named here but not declared above is created. |
| `isPinned` | Defaults to `false`. |
| `tabs` | Shorthand for a workspace whose layout is a single pane group. |
| `layout` | A layout tree. Takes precedence over `tabs` when both are present. |

A workspace with neither `tabs` nor `layout` opens with one terminal, which is what a bare
`{"title": "Scratch"}` is expected to do.

### Layout

A node is either a **leaf** carrying `tabs`, or a **split** carrying `children`:

| Field | Meaning |
|---|---|
| `tabs` | Leaf node. The tabs in one pane group. |
| `children` | Split node. Nested layout nodes; may nest arbitrarily deep. |
| `orientation` | `horizontal` (side by side) or `vertical` (stacked). Defaults to `horizontal`. |
| `weights` | Optional proportions, one per child. Ignored with a warning if the count does not match. |

A split with a single child collapses into that child rather than being rejected.

### Tab

| Field | Meaning |
|---|---|
| `directory` | Terminal working directory. Accepts `~/x`, `/x`, or `file:///x`. |
| `url` | Makes the tab a browser tab. Takes precedence over `directory`. |
| `title` | Optional custom tab title. |

A directory that no longer exists is not an error: the terminal opens in the workspace's configured
new-session directory, exactly as it would when restoring saved state.

## When something is wrong

The import is forgiving by design, because a half-imported sidebar is more useful than a rejected
file:

- An entry that cannot be read at all — a string where an object belongs — is skipped, and the rest
  of the document still imports.
- A tab with an unreadable address or directory is skipped and reported.
- Mismatched split weights fall back to even proportions and are reported.

Anything skipped is counted in the summary shown when the import finishes. These are fatal, and
nothing is imported:

- The file is not valid JSON.
- `version` is newer than this version of myterm understands.
- The document contains no workspaces.
