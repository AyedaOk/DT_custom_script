-- EnfuseSimple.lua
-- Simple Enfuse HDR/Focus stacking integration for Darktable
-- Now with executable path selection similar to HDRMerge

local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("7.0.0", "EnfuseSimple")

local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end

-----------------------------------------------------------------------
-- Script metadata
-----------------------------------------------------------------------
local script_data = {}
script_data.metadata = {
  name    = "EnfuseSimple",
  purpose = _("HDR/Focus Stacking with Enfuse"),
  author  = "Ayéda Okambawa (GUI enhancements inspired by HDRMerge integration)",
}

-----------------------------------------------------------------------
-- Module state
-----------------------------------------------------------------------
local mE = {}
mE.widgets = {}
mE.event_registered = false
mE.module_installed = false

-- module name for preferences
local mod = "module_EnfuseSimple"
GUI = {}
-----------------------------------------------------------------------
-- UI Widgets (main page)
-----------------------------------------------------------------------
-- Combo box to switch between menus
local cbb_menu = dt.new_widget("combobox"){
  label = _("Menu"),
  tooltip = _("Switch between EnfuseSimple and Settings views"),
  selected = 1,                -- 1‑based index of text list below
  "EnfuseSimple",              -- item 1
  "Settings",                  -- item 2
  changed_callback = function(self)
    if self.selected == 1 then
      GUI.stack.active = 1     -- show main module
    elseif self.selected == 2 then
      GUI.stack.active = 2     -- show Settings page
    end
  end
}

local sld_exposure = dt.new_widget("slider") {
  label = _("Exposure Weight"),
  tooltip = _("Set to 1 for HDR, 0 for Focus Stack and 0.6 for Hybrid"),
  soft_min = 0, soft_max = 1, hard_min = 0, hard_max = 1,
  step = 0.1, digits = 1, value = 1
}
local sld_saturation = dt.new_widget("slider") {
  label = _("Saturation Weight"),
  tooltip = _("Set between 0 and 0.2 for HDR, 0 for Focus Stack and 0.2 for Hybrid"),
  soft_min = 0, soft_max = 1, hard_min = 0, hard_max = 1,
  step = 0.1, digits = 1, value = 1
}
local sld_contrast = dt.new_widget("slider") {
  label = _("Contrast Weight"),
  tooltip = _("Set to 0 for HDR, 1 for Focus Stack and 0.6 for Hybrid"),
  soft_min = 0, soft_max = 1, hard_min = 0, hard_max = 1,
  step = 0.1, digits = 1, value = 1
}
local cbt_hard = dt.new_widget("check_button"){
    label = _("Hard mask"),
    tooltip = _("Enable for Focus Stack and disable for HDR"),
    value = true
}
local cbt_align = dt.new_widget("check_button"){
    label = _("Align first"),
    tooltip = _("Enable if your pictures need alignment"),
    value = true
}

local cbb_preset = dt.new_widget("combobox"){
  label = _("Presets"),
  tooltip = _("Presets for HDR, Focus Stack or Hybrid"),
  selected = 1,                -- 1‑based index of text list below
  "HDR",                       -- item 1
  "Focus Stack",               -- item 2
  "Hybrid",                    -- item 3
  changed_callback = function(self)
    if self.selected == 1 then          -- HDR
      sld_exposure.value   = 1
      sld_saturation.value = 0.2
      sld_contrast.value   = 0
      cbt_hard.value       = false
    elseif self.selected == 2 then      -- Focus Stack
      sld_exposure.value   = 0
      sld_saturation.value = 0
      sld_contrast.value   = 1
      cbt_hard.value       = true
    elseif self.selected == 3 then      -- Hybrid
      sld_exposure.value   = 0.6
      sld_saturation.value = 0.2
      sld_contrast.value   = 0.6
      cbt_hard.value       = true
    end
  end
}

-----------------------------------------------------------------------
-- Export helper
-----------------------------------------------------------------------
local function export_to_temp_tif(img)
  local temp_file = os.tmpname() .. ".tif"
  local tiff_exporter = dt.new_format("tiff")
  tiff_exporter.max_width  = 0
  tiff_exporter.max_height = 0
  tiff_exporter:write_image(img, temp_file, true)
  dt.print_log(string.format("Exported %s to temp file %s", img.filename, temp_file))
  return temp_file
end

-----------------------------------------------------------------------
-- Main merge function
-----------------------------------------------------------------------
local function do_merge()
  local images = dt.gui.selection()
  if #images < 2 then
    dt.print(_("Select at least two images"))
    return
  end

  -- retrieve binaries from preferences
  local enfuse_bin = dt.preferences.read(mod, "enfuse_bin", "string") or "enfuse"
  local align_bin  = dt.preferences.read(mod, "align_bin", "string") or "align_image_stack"

  -- validate paths
  if enfuse_bin == "" or align_bin == "" then
    dt.print(_("Please set the executable paths in Settings"))
    return
  end

  -- get selected preset from combobox (numerical index)
  local preset_id = cbb_preset.selected
  local preset = ""

  if preset_id == 1 then
    preset = "hdr"
  elseif preset_id == 2 then
    preset = "focus"
  elseif preset_id == 3 then
    preset = "hybrid"
  end

  -- build output filename
  local out_dir = images[1].path
  local first_name = images[1].filename
  local base = first_name:match("(.+)%.[^%.]+$") or first_name
  local out_file = string.format("%s/%s-%s.tif", out_dir, base, preset)

  local exposurewt   = tostring(sld_exposure.value):gsub(",", ".")
  local saturationwt = tostring(sld_saturation.value):gsub(",", ".")
  local contrastwt   = tostring(sld_contrast.value):gsub(",", ".")
  local hardmask = cbt_hard.value and "--hard-mask" or ""

  -- Export temp tif files
  local img_paths = {}
  for _, img in ipairs(images) do
    local tif_path = export_to_temp_tif(img)
    if not tif_path then
      dt.print(_("Export failed for ") .. img.filename)
      return
    end
    table.insert(img_paths, tif_path)
  end

  -- Detect OS platform so we only add cmd /c on Windows
  local is_windows = package.config:sub(1,1) == "\\"   -- true if Windows path separator

  -- Align images
  local align_prefix
  local paths_for_enfuse = img_paths
  if cbt_align.value then
    local quoted_paths = {}
    for _, path in ipairs(img_paths) do
      table.insert(quoted_paths, string.format('"%s"', path))
    end
    align_prefix = os.tmpname():gsub(".tmp$", "_")

    local command_align
    if is_windows then
      command_align = string.format(
        'cmd /c ""%s" -m -v -a "%s" %s"',
        align_bin, align_prefix, table.concat(quoted_paths, " ")
      )
    else
      command_align = string.format(
        '"%s" -m -v -a "%s" %s',
        align_bin, align_prefix, table.concat(quoted_paths, " ")
      )
    end

    dt.print_log("Running: " .. command_align)
    local h = io.popen(command_align)
    local align_out = h:read("*a")
    h:close()
    dt.print(_("Align finished."))
    dt.print_log(align_out)

    paths_for_enfuse = {}
    for i = 0, #images - 1 do
      table.insert(paths_for_enfuse, string.format('"%s%04d.tif"', align_prefix, i))
    end
  end

  -- Enfuse
  local command_merge
  if is_windows then
    command_merge = string.format(
      'cmd /c ""%s" --exposure-weight=%s --saturation-weight=%s --contrast-weight=%s %s --output="%s" %s"',
      enfuse_bin,
      exposurewt, saturationwt, contrastwt, hardmask,
      out_file, table.concat(paths_for_enfuse, " ")
    )
  else
    command_merge = string.format(
      '"%s" --exposure-weight=%s --saturation-weight=%s --contrast-weight=%s %s --output="%s" %s',
      enfuse_bin,
      exposurewt, saturationwt, contrastwt, hardmask,
      out_file, table.concat(paths_for_enfuse, " ")
    )
  end

  dt.print_log("Running: " .. command_merge)
  local h2 = io.popen(command_merge)
  local out2 = h2:read("*a")
  h2:close()
  dt.print(_("Enfuse finished."))
  dt.print_log(out2)

  dt.database.import(out_file)

  -- cleanup
  local function unquote(p) return p:gsub('^"(.-)"$', "%1") end
  for _, p in ipairs(img_paths) do os.remove(unquote(p)) end
  if align_prefix then
    for i = 0, #images - 1 do
      os.remove(string.format("%s%04d.tif", align_prefix, i))
    end
  end
end

-----------------------------------------------------------------------
-- Executable path selection UI
-----------------------------------------------------------------------
local exe_enfuse = dt.new_widget("file_chooser_button"){
  title = _("Select enfuse executable"),
  value = dt.preferences.read(mod, "enfuse_bin", "string") or "enfuse",
  is_directory = false,
  tooltip = _("path to the enfuse executable")
}

local exe_align = dt.new_widget("file_chooser_button"){
  title = _("Select align_image_stack executable"),
  value = dt.preferences.read(mod, "align_bin", "string") or "align_image_stack",
  is_directory = false,
  tooltip = _("path to the align_image_stack executable")
}

local exe_update = dt.new_widget("button"){
  label = _("Save paths"),
  clicked_callback = function()
    dt.preferences.write(mod, "enfuse_bin", "string", exe_enfuse.value)
    dt.preferences.write(mod, "align_bin",  "string", exe_align.value)
    GUI.stack.active = 1
    dt.print(_("Executable paths updated"))
  end
}

-----------------------------------------------------------------------
-- Labels and buttons
-----------------------------------------------------------------------
local lbl_enfuse  = dt.new_widget("section_label"){ label = _("EnfuseSimple") }

local merge_button = dt.new_widget("button") {
  label = _("Merge"),
  clicked_callback = function(_) do_merge() end
}

-----------------------------------------------------------------------
-- GUI layout assembly
-----------------------------------------------------------------------


GUI.options = dt.new_widget("box"){
  orientation = "vertical",
  lbl_enfuse,
  cbb_menu,
  cbb_preset,
  sld_exposure, sld_saturation, sld_contrast,
  cbt_hard, cbt_align,
  merge_button
}

local exe_box = dt.new_widget("box"){
  orientation = "vertical",
  exe_enfuse,
  exe_align,
  exe_update
}

GUI.stack = dt.new_widget("stack"){ GUI.options, exe_box }

-- Default to appropriate view
if (dt.preferences.read(mod, "enfuse_bin", "string") or "") == "" or
   (dt.preferences.read(mod, "align_bin", "string") or "") == "" then
  GUI.stack.active = 2
else
  GUI.stack.active = 1
end

-----------------------------------------------------------------------
-- Module registration
-----------------------------------------------------------------------
local function install_module()
  if not mE.module_installed then
    dt.register_lib(
      "EnfuseSimple",
      _("EnfuseSimple"),
      true,
      false,
      {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      dt.new_widget("box"){ orientation = "vertical", GUI.stack },
      nil, nil
    )
    mE.module_installed = true
  end
end

local function destroy()
  if dt.gui.libs["EnfuseSimple"] then
    dt.gui.libs["EnfuseSimple"].visible = false
  end
end

local function restart()
  if dt.gui.libs["EnfuseSimple"] then
    dt.gui.libs["EnfuseSimple"].visible = true
  end
end

-----------------------------------------------------------------------
-- View handling
-----------------------------------------------------------------------
if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  if not mE.event_registered then
    dt.register_event("EnfuseSimple", "view-changed",
      function(event, old_view, new_view)
        if new_view.id == "lighttable" then install_module() end
      end)
    mE.event_registered = true
  end
end

-----------------------------------------------------------------------
-- API for Darktable script manager
-----------------------------------------------------------------------
script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart

return script_data
