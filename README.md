# filepath-dragdrop

A [Lite XL](https://lite-xl.com) plugin that lets you drag a file from the
built-in TreeView and drop it into an open document — instead of opening the
file, it inserts the file's **path** at your cursor.

While dragging, a small floating label follows your pointer and shows exactly
what will be inserted, including the file's tree-view icon.

```
my-project/
├── src/
│   └── User.php
└── index.php          <-- drag src/User.php here, drop it, get:
                            ./src/User.php
```

> **Plugin-only, no core patches.** Lite XL doesn't currently expose a native
> drag-and-drop API between internal views (see [How it works](#how-it-works)
> below for why), so this plugin emulates a press-drag-release gesture using
> only documented, existing hooks. No Lite XL source files are modified.

## Features

- Drag any file from the TreeView into any open document.
- Inserts a path relative to the project root — no manual path typing.
- Multi-cursor aware: dropping with several active cursors inserts the path
  at every cursor.
- Configurable prefix, quoting, and extension handling.
- Live floating preview while dragging, with the file's real tree-view icon
  (works with icon-set plugins like `nonicons`, since it reuses
  `TreeView:get_item_icon`).
- Plain clicks in the TreeView are completely unaffected — files still open
  normally, directories still expand/collapse normally.
- Toggle on/off at runtime with the `filepath-dragdrop:toggle` command.

## Requirements

- Lite XL 2.1 or newer (uses `mod-version:3`).
- No external dependencies, fonts, or libraries.

## Installation

### Manual (recommended)

**Linux / macOS**

```sh
mkdir -p ~/.config/lite-xl/plugins
curl -L -o ~/.config/lite-xl/plugins/filepath_dragdrop.lua \
  https://raw.githubusercontent.com/<your-username>/filepath-dragdrop/main/filepath_dragdrop.lua
```

**Windows (PowerShell)**

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\lite-xl\plugins"
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/<your-username>/filepath-dragdrop/main/filepath_dragdrop.lua" `
  -OutFile "$env:USERPROFILE\.config\lite-xl\plugins\filepath_dragdrop.lua"
```

Or just download [`filepath_dragdrop.lua`](./filepath_dragdrop.lua) from this
repo and copy it into your `plugins` folder by hand.

After copying the file, restart Lite XL (or run `core:restart` from the
command palette, <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd>) — plugins are
only scanned at startup.

### Via [lite-xl-plugin-manager (lpm)](https://github.com/lite-xl/lite-xl-plugin-manager)

If you maintain this repo with a `manifest.json` entry, users can install it
with:

```sh
lpm add https://github.com/<your-username>/filepath-dragdrop
lpm install filepath_dragdrop
```

A starter [`manifest.json`](./manifest.json) is included in this repo — update
the `remote` URL and commit hash for your fork/release before publishing.

## Usage

1. Open a project folder in Lite XL.
2. Click and hold on a **file** (not a folder) in the TreeView.
3. Drag it over an open document. A label showing the path to be inserted
   follows your cursor.
4. Release the mouse button over the document — the path is inserted at your
   cursor (or at every cursor, if you have multiple selections active).

Releasing without dragging (a normal click) still opens the file as usual.
Releasing over anything other than a document (the tree itself, a tab, the
status bar, etc.) simply cancels the drag — nothing is inserted or opened.

## Configuration

Add this to your `~/.config/lite-xl/init.lua` (create the file if it doesn't
exist yet — run `core:open-user-module` from the command palette):

```lua
local config = require "core.config"

config.plugins.filepath_dragdrop = {
  relative_to       = "project", -- currently the only supported mode
  prefix            = "./",
  quote             = false,
  include_extension = true,
  enabled           = true,
  drag_threshold    = 6,     -- pixels before a press counts as a drag
  show_preview      = true,  -- floating label while dragging
  show_preview_icon = true,  -- show the file's tree icon in the label
}
```

You can also change a single option without redefining the whole table:

```lua
config.plugins.filepath_dragdrop.quote = true
config.plugins.filepath_dragdrop.prefix = ""
```

If you have the bundled `settings` plugin installed, all of these options
also show up in the Settings GUI under **File Path Drag & Drop**.

### Option reference

| Option              | Type    | Default | Description                                             |
|---------------------|---------|---------|----------------------------------------------------------|
| `relative_to`       | string  | `"project"` | Path base. Only `"project"` is currently implemented. |
| `prefix`            | string  | `"./"`  | Text prepended to every generated path.                  |
| `quote`             | boolean | `false` | Wraps the generated path in double quotes.                |
| `include_extension` | boolean | `true`  | Keeps or strips the file extension.                       |
| `enabled`           | boolean | `true`  | Master on/off switch.                                     |
| `drag_threshold`    | number  | `6`     | Pixels of movement before a press becomes a drag.         |
| `show_preview`      | boolean | `true`  | Shows the floating path label while dragging.             |
| `show_preview_icon` | boolean | `true`  | Shows the file's tree icon inside the floating label.     |

### Examples

Given `src/User.php` dragged while `index.php` is open:

| Config                                   | Inserted text        |
|-------------------------------------------|----------------------|
| defaults                                  | `./src/User.php`     |
| `prefix = ""`                              | `src/User.php`       |
| `prefix = "/"`                             | `/src/User.php`      |
| `quote = true`                             | `"./src/User.php"`   |
| `include_extension = false`                | `./src/User`         |
| `quote = true, include_extension = false`  | `"./src/User"`       |

## How it works

Lite XL's TreeView, DocView, and RootView are all documented, public Lua
modules — but the plugin API has **no drag-and-drop lifecycle events**
(`on_drag_start` / `on_drop`, etc.) and **no generic mouse capture**: once
your pointer leaves the TreeView's screen area mid-press, TreeView itself
stops receiving any further events for that gesture. (Lite XL's `RootView`
hardcodes exactly two exceptions to this — divider resizing and tab
reordering — nothing else gets a capture.)

This plugin works around that, without touching any core file, by:

1. Overriding `TreeView:on_mouse_pressed` to record the pressed file item
   instead of immediately opening it (TreeView's default behavior opens a
   file on press, not on release).
2. Overriding `RootView:on_mouse_moved` — which *does* see every mouse event
   regardless of which child view is under the pointer — to detect once the
   press has moved far enough to count as a drag, and to compute the preview
   text/icon at that moment.
3. Overriding `RootView:on_mouse_released` to resolve the gesture: if there
   was no real movement, it reproduces the normal "open file" click; if there
   was, it looks up whatever view is currently under the pointer via
   `root_node:get_child_overlapping_point`, and if that's a `DocView`, inserts
   the path instead of opening the file.
4. Overriding `RootView:draw` to paint the floating preview label.

Every override calls the original implementation first, so scrollbar
dragging, divider resizing, tab switching, and normal TreeView navigation are
all left completely intact.

### Known limitations

- No OS-level drag cursor, ghost image, or drop-target highlighting outside
  of the floating label this plugin draws — Lite XL doesn't expose those to
  plugins.
- Only single-file drags are supported (no multi-select drag).
- `relative_to` currently only supports `"project"`.
- In multi-directory projects, paths are relative to the primary project
  root, not necessarily the specific added directory a file lives under.

### ~~One last thing~~
~~**This extension is entirely Claude-AI made, I am not proud of the thing at all, but at least it works.
As soon as I can, I'll do extra tests to confirm the overall functionality.~~
(AI didn't like this part)

### A note on how this was built

This plugin was built with Claude (Anthropic's AI), including researching
Lite XL's actual source to ground the implementation in real, existing APIs
rather than invented ones. It hasn't yet been tested against a live Lite XL
install — I'd treat it as a solid first draft rather than production-hardened.
If you hit issues, please open one; I'll be testing and refining this as I
get time.

## License

[MIT](./LICENSE)

## Contributing

Issues and pull requests are welcome. Please keep changes plugin-only (no
Lite XL core modifications) and avoid introducing global variables.
