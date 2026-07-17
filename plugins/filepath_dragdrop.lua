-- mod-version:3
--
-- filepath_dragdrop.lua
--
-- Drag a file from the built-in TreeView and drop it into an open
-- document to insert its path at the cursor(s), instead of opening it.
-- While dragging, a small floating label (with the file's tree icon)
-- follows the pointer showing exactly what will be inserted.
--
-- https://github.com/<your-username>/filepath-dragdrop
--
-- Licensed under the MIT license. See LICENSE for details.

local core     = require "core"
local common   = require "core.common"
local config   = require "core.config"
local command  = require "core.command"
local style    = require "core.style"
local RootView = require "core.rootview"
local DocView  = require "core.docview"
local TreeView = require "plugins.treeview"
local keymap   = require "core.keymap"

-- ---------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------

config.plugins.filepath_dragdrop = common.merge({
  -- Currently only "project" is supported: paths are computed relative
  -- to the current project root.
  relative_to = "project",

  -- Prepended to every generated path. Common values: "./", "", "/".
  prefix = "./",

  -- Wrap the generated path in double quotes.
  quote = false,

  -- Whether to keep the file extension in the generated path.
  include_extension = true,

  -- Whether the drag-to-insert-path behavior is active at all. Can be
  -- toggled at runtime with the "filepath-dragdrop:toggle" command.
  enabled = true,

  -- Minimum pointer movement (in pixels) before a press-in-treeview is
  -- treated as a drag rather than a plain click.
  drag_threshold = 6,

  -- Visual drag preview.
  show_preview      = true,
  show_preview_icon = true,
  preview_offset_x  = 14,
  preview_offset_y  = 14,

  -- Settings-GUI integration (consumed by the bundled "settings" plugin,
  -- if installed).
  config_spec = {
    name = "File Path Drag & Drop",
    {
      label = "Enabled",
      description = "Enable dragging files from the tree view into documents to insert their path.",
      path = "enabled",
      type = "toggle",
      default = true,
    },
    {
      label = "Show Drag Preview",
      description = "Show a floating label with the resolved path while dragging.",
      path = "show_preview",
      type = "toggle",
      default = true,
    },
    {
      label = "Show Icon In Preview",
      description = "Show the file's tree-view icon inside the floating drag label.",
      path = "show_preview_icon",
      type = "toggle",
      default = true,
    },
    {
      label = "Prefix",
      description = "Text prepended to every generated path (e.g. \"./\").",
      path = "prefix",
      type = "string",
      default = "./",
    },
    {
      label = "Quote Path",
      description = "Wrap the generated path in double quotes.",
      path = "quote",
      type = "toggle",
      default = false,
    },
    {
      label = "Include Extension",
      description = "Keep the file extension in the generated path.",
      path = "include_extension",
      type = "toggle",
      default = true,
    },
    {
      label = "Drag Threshold",
      description = "Pixels the pointer must move before a press is treated as a drag.",
      path = "drag_threshold",
      type = "number",
      default = 6,
      min = 1,
      max = 40,
    },
  },
}, config.plugins.filepath_dragdrop)


-- ---------------------------------------------------------------------
-- Internal state (module-local; nothing is written to _G)
-- ---------------------------------------------------------------------

local dragdrop = {}

-- Tracks an in-progress press-drag-release gesture that originated on a
-- file item inside the TreeView.
local drag_state = {
  active        = false, -- a candidate gesture is being tracked
  dragging      = false, -- movement has exceeded the configured threshold
  item          = nil,   -- the TreeView item (table with .type / .abs_filename)
  treeview      = nil,   -- the TreeView instance the press originated on
  start_x       = 0,
  start_y       = 0,
  last_x        = 0,
  last_y        = 0,
  preview_text  = nil,   -- computed once, when the drag starts
  preview_icon  = nil,   -- glyph string from TreeView:get_item_icon
  preview_font  = nil,
  preview_color = nil,
}
function keymap.on_key_press("escape")
  if drag_state.active and button == "left" then
    local item          = drag_state.item
    local was_dragging   = drag_state.dragging
    local origin_tree    = drag_state.treeview

    drag_state.active        = false
    drag_state.dragging      = false
    drag_state.item          = nil
    drag_state.treeview      = nil
    drag_state.preview_text  = nil
    drag_state.preview_icon  = nil
    drag_state.preview_font  = nil
    drag_state.preview_color = nil
    

-- ---------------------------------------------------------------------
-- Path helpers
-- ---------------------------------------------------------------------

local function get_project_dir()
  -- Different Lite XL releases have exposed the project root slightly
  -- differently (a plain core.project_dir string in most 2.x releases,
  -- vs. core.root_project() on builds with multi-directory project
  -- support). Handle both rather than assuming one exists.
  if core.project_dir then
    return core.project_dir
  end
  if core.root_project then
    local ok, root = pcall(core.root_project)
    if ok and root and root.path then
      return root.path
    end
  end
  return nil
end


local function to_forward_slashes(path)
  return (path:gsub("\\", "/"))
end


local function strip_extension(path)
  local dir, name = path:match("^(.*/)([^/]+)$")
  if not name then
    dir, name = "", path
  end
  local base = name:match("^(.+)%.[^./]+$")
  if base and base ~= "" then
    return dir .. base
  end
  return path
end


-- Computes the text that should be inserted for a given TreeView item,
-- honoring config.plugins.filepath_dragdrop.
function dragdrop.compute_path(abs_filename)
  local opts = config.plugins.filepath_dragdrop
  local project_dir = get_project_dir()
  if not project_dir then
    core.error("filepath_dragdrop: could not determine the project root")
    return nil
  end

  local rel = common.relative_path(project_dir, abs_filename)
  rel = to_forward_slashes(rel)

  if not opts.include_extension then
    rel = strip_extension(rel)
  end

  local text = (opts.prefix or "") .. rel
  if opts.quote then
    text = "\"" .. text .. "\""
  end
  return text
end


-- ---------------------------------------------------------------------
-- Insertion into the target document (multi-cursor aware)
-- ---------------------------------------------------------------------

function dragdrop.insert_path_into_view(view, item)
  if not (view and view.doc and item and item.abs_filename) then return end

  local path_text = dragdrop.compute_path(item.abs_filename)
  if not path_text then return end

  local doc = view.doc

  -- Snapshot every selection/cursor up front.
  local selections = {}
  for idx, l1, c1, l2, c2 in doc:get_selections(true) do
    selections[#selections + 1] = { idx = idx, l1 = l1, c1 = c1, l2 = l2, c2 = c2 }
  end

  -- Apply insertions from the last cursor to the first. Since document
  -- positions are stored as line/column pairs (not object references),
  -- editing at an earlier cursor can shift the coordinates of later ones
  -- on the same line; going in reverse avoids needing to recompute
  -- offsets for cursors we've already handled.
  for i = #selections, 1, -1 do
    local sel = selections[i]

    if sel.l1 ~= sel.l2 or sel.c1 ~= sel.c2 then
      doc:remove(sel.l1, sel.c1, sel.l2, sel.c2)
    end

    doc:insert(sel.l1, sel.c1, path_text)

    local new_col = sel.c1 + #path_text
    doc:set_selections(sel.idx, sel.l1, new_col, sel.l1, new_col)
  end

  core.set_active_view(view)
end


-- ---------------------------------------------------------------------
-- TreeView hook: capture the drag source instead of opening immediately
-- ---------------------------------------------------------------------

local TreeView_on_mouse_pressed = TreeView.on_mouse_pressed

function TreeView:on_mouse_pressed(button, x, y, clicks)
  local opts = config.plugins.filepath_dragdrop

  if opts.enabled and button == "left" and self.hovered_item
     and self.hovered_item.type ~= "dir" then

    -- Let the base View handle things like scrollbar interaction first.
    local caught = TreeView.super.on_mouse_pressed(self, button, x, y, clicks)
    if caught then
      drag_state.active = false
      return caught
    end

    -- Defer the "open file" decision to on_mouse_released: we don't yet
    -- know whether this press will turn into a drag.
    drag_state.active       = true
    drag_state.dragging     = false
    drag_state.item         = self.hovered_item
    drag_state.treeview     = self
    drag_state.start_x      = x
    drag_state.start_y      = y
    drag_state.last_x       = x
    drag_state.last_y       = y
    drag_state.preview_text = nil
    drag_state.preview_icon = nil
    return true
  end

  -- Directories (and clicks while the plugin is disabled) behave exactly
  -- as before: normal expand/collapse, no drag tracking.
  drag_state.active = false
  return TreeView_on_mouse_pressed(self, button, x, y, clicks)
end


-- ---------------------------------------------------------------------
-- RootView hooks: these see every mouse event regardless of which child
-- view is currently under the pointer, which is required to detect a
-- drop over a DocView after the gesture has left the TreeView's bounds.
-- ---------------------------------------------------------------------

local RootView_on_mouse_moved = RootView.on_mouse_moved

function RootView:on_mouse_moved(x, y, dx, dy, ...)
  RootView_on_mouse_moved(self, x, y, dx, dy, ...)

  if drag_state.active then
    drag_state.last_x, drag_state.last_y = x, y

    if not drag_state.dragging then
      local threshold = config.plugins.filepath_dragdrop.drag_threshold or 6
      local dist = math.sqrt((x - drag_state.start_x) ^ 2 + (y - drag_state.start_y) ^ 2)
      if dist >= threshold then
        drag_state.dragging = true

        -- Resolve the preview text and icon once, when the drag begins,
        -- rather than recomputing them every frame.
        if drag_state.item then
          drag_state.preview_text = dragdrop.compute_path(drag_state.item.abs_filename)

          if drag_state.treeview and drag_state.treeview.get_item_icon then
            local ok, icon, font, color = pcall(
              drag_state.treeview.get_item_icon,
              drag_state.treeview, drag_state.item, false, false
            )
            if ok then
              drag_state.preview_icon  = icon
              drag_state.preview_font  = font
              drag_state.preview_color = color
            end
          end
        end
      end
    end

    if drag_state.dragging then
      core.redraw = true -- keep repainting so the label tracks the cursor
    end
  end
end


local RootView_on_mouse_released = RootView.on_mouse_released

function RootView:on_mouse_released(button, x, y, ...)
  local result = RootView_on_mouse_released(self, button, x, y, ...)

  if drag_state.active and button == "left" then
    local item          = drag_state.item
    local was_dragging   = drag_state.dragging
    local origin_tree    = drag_state.treeview

    drag_state.active        = false
    drag_state.dragging      = false
    drag_state.item          = nil
    drag_state.treeview      = nil
    drag_state.preview_text  = nil
    drag_state.preview_icon  = nil
    drag_state.preview_font  = nil
    drag_state.preview_color = nil

    if was_dragging then
      -- Resolve the drop target from the current pointer position.
      local node = self.root_node:get_child_overlapping_point(x, y)
      local view = node and node.active_view

      if view and view ~= origin_tree and view:is(DocView) then
        dragdrop.insert_path_into_view(view, item)
      end
      -- Dropped somewhere that isn't a document (back on the tree,
      -- on a tab strip, on the status bar, etc.): the gesture is
      -- simply cancelled, matching how a failed drag would behave
      -- in a native application.

    else
      -- No meaningful movement: reproduce the original single-click
      -- "open file" behavior exactly.
      if item then
        core.try(function()
          local project_dir = get_project_dir()
          local doc_filename = project_dir
            and common.relative_path(project_dir, item.abs_filename)
            or item.abs_filename
          core.root_view:open_doc(core.open_doc(doc_filename))
        end)
      end
    end
  end

  return result
end


-- ---------------------------------------------------------------------
-- Visual drag preview (path label + tree icon)
-- ---------------------------------------------------------------------

local RootView_draw = RootView.draw

function RootView:draw()
  RootView_draw(self)

  local opts = config.plugins.filepath_dragdrop
  if not (opts.show_preview and drag_state.dragging and drag_state.preview_text) then
    return
  end

  local text_font = style.font
  local text = drag_state.preview_text
  local pad_x, pad_y = 8, 5
  local icon_gap = 6

  local show_icon = opts.show_preview_icon and drag_state.preview_icon and drag_state.preview_font
  local icon_w = show_icon and drag_state.preview_font:get_width(drag_state.preview_icon) or 0

  local tw = text_font:get_width(text)
  local th = math.max(text_font:get_height(), show_icon and drag_state.preview_font:get_height() or 0)

  local content_w = tw + (show_icon and (icon_w + icon_gap) or 0)

  local x = drag_state.last_x + (opts.preview_offset_x or 14)
  local y = drag_state.last_y + (opts.preview_offset_y or 14)

  local box_w, box_h = content_w + pad_x * 2, th + pad_y * 2

  -- Keep the label on-screen near the right/bottom edges.
  if x + box_w > self.size.x then x = self.size.x - box_w - 4 end
  if y + box_h > self.size.y then y = self.size.y - box_h - 4 end

  renderer.draw_rect(x, y, box_w, box_h, style.background3)
  renderer.draw_rect(x, y, box_w, 1, style.divider)

  local cursor_x = x + pad_x
  local center_y = y + box_h / 2

  if show_icon then
    renderer.draw_text(
      drag_state.preview_font, drag_state.preview_icon,
      cursor_x, center_y - drag_state.preview_font:get_height() / 2,
      drag_state.preview_color or style.text
    )
    cursor_x = cursor_x + icon_w + icon_gap
  end

  renderer.draw_text(
    text_font, text,
    cursor_x, center_y - text_font:get_height() / 2,
    style.text
  )
end


-- ---------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------

command.add(nil, {
  ["filepath-dragdrop:toggle"] = function()
    local opts = config.plugins.filepath_dragdrop
    opts.enabled = not opts.enabled
    core.log("File path drag & drop: %s", opts.enabled and "enabled" or "disabled")
  end,
})


return dragdrop
