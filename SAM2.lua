local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("7.0.0", "SAM2")
dt.print_log("SAM2 loaded")
local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end

-----------------------------------------------------------------------
-- Script metadata
-----------------------------------------------------------------------
local script_data = {}
script_data.metadata = {
  name = "SAM2",
  purpose = _("AI masking using SAM2"),
  author = "Ayéda Okambawa",
}

-----------------------------------------------------------------------
-- Module state
-----------------------------------------------------------------------
_G.__SAM2_STATE = _G.__SAM2_STATE or { module_installed = false, event_registered = false }
local mE = _G.__SAM2_STATE

local mod = "module_SAM2_tools"

local GUI = {}

-----------------------------------------------------------------------
-- Helper: export PNG
-----------------------------------------------------------------------
local function export_to_temp_png(img, size)
  local base = img.filename:match("(.+)%..+$")
  local temp_file = dt.configuration.tmp_dir .. "/" .. base .. ".png"
  local png_exporter = dt.new_format("png")
  local png_size = math.tointeger(size)
  if not png_size then
    png_size = math.floor(tonumber(size) or 0)
  end
  png_exporter.max_width = png_size
  png_exporter.max_height = png_size
  png_exporter:write_image(img, temp_file, true)
  dt.print_log(string.format("Exported %s to %s", img.filename, temp_file))
  return temp_file
end

-----------------------------------------------------------------------
-- SETTINGS UI (sam2-tools executable path)
-----------------------------------------------------------------------
local sam2_path_picker = dt.new_widget("file_chooser_button"){
  title = _("Select sam2-tools executable"),
  value = dt.preferences.read(mod, "sam2_bin", "string") or "sam2-tools",
  is_directory = false,
  tooltip = _("Path to the sam2-tools executable"),
}

local output_path = dt.new_widget("file_chooser_button"){
  title = _("Select mask output folder"),
  value = dt.preferences.read(mod, "sam2_out", "string"),
  is_directory = true,
  tooltip = _("Where to save generated masks. Leave empty to save next to the original image."),
}

local disable_modules_default = dt.preferences.read(mod, "sam2_disable_modules", "bool")
if disable_modules_default == nil then
  disable_modules_default = true
end

local disable_modules_toggle = dt.new_widget("check_button"){
  label = _("Disable modules during mask generation"),
  value = disable_modules_default,
  tooltip = _("Temporarily disable crop/flip/canvas/borders/lens while generating masks."),
}

local sam2_save_button = dt.new_widget("button"){
  label = _("Save"),
  clicked_callback = function()
    dt.preferences.write(mod, "sam2_bin", "string", sam2_path_picker.value)
    dt.preferences.write(mod, "sam2_out", "string", output_path.value)
    dt.preferences.write(mod, "sam2_disable_modules", "bool", disable_modules_toggle.value)
    if GUI.stack then GUI.stack.active = 1 end
    dt.print(_("SAM2 settings reset"))
  end
}

local reset_button = dt.new_widget("button"){
  label = _("Reset Mask folder"),
  clicked_callback = function()
    dt.preferences.write(mod, "sam2_out", "string", "")
    if GUI.stack then GUI.stack.active = 1 end
    dt.print(_("Output folder cleared. Masks will be saved next to the image."))
  end
}

dt.preferences.register(
  mod,
  "sam2_out",
  "directory",
  _("SAM2 Mask output folder"),
  _("Root folder where masks will be saved (empty = alongside original)"),
  ""
)

dt.preferences.register(
  mod,
  "sam2_bin",
  "directory",
  _("SAM2 binary path"),
  _("Binary path for SAM2 executable"),
  ""
)

dt.preferences.register(
  mod,
  "sam2_disable_modules",
  "bool",
  _("SAM2 disable modules"),
  _("Disable crop/flip/canvas/borders/lens during mask generation"),
  true
)


-----------------------------------------------------------------------
-- MAIN SAM2 UI
-----------------------------------------------------------------------
local cbb_model = dt.new_widget("combobox") {
  label = _("Model"),
  value = 1,
  "sam2.1_hiera_large","sam2.1_hiera_base_plus","sam2.1_hiera_small","sam2.1_hiera_tiny",
}

local cbb_mode = dt.new_widget("combobox") {
  label = _("Mode"),
  value = 1,
  "Box","Points","Auto",
}

local sld_size = dt.new_widget("slider") {
  label = _("Temporary png size"),
  soft_min = 0, soft_max = 4096, hard_min = 0, hard_max = 4096,
  step = 1, digits = 0, value = 1024
}

local sld_nb_mask = dt.new_widget("slider") {
  label = _("Number of masks"),
  soft_min = 1, soft_max = 10, hard_min = 1, hard_max = 4096,
  step = 1, digits = 0, value = 3
}

-----------------------------------------------------------------------
-- MAIN BUTTON
-----------------------------------------------------------------------
local function btt_edit()
  local images = dt.gui.selection()
  if not images or #images == 0 then
    dt.print(_("No image available"))
    return
  end
  dt.print(_("Starting SAM2 mask generation..."))

  -- Retrieve saved SAM2 executable
  local sam2_bin = dt.preferences.read(mod, "sam2_bin", "string") or "sam2-tools"
  if sam2_bin == "" then
    dt.print(_("Please set the SAM2 executable path in Settings"))
    GUI.stack.active = 2
    return
  end

  local disable_modules = dt.preferences.read(mod, "sam2_disable_modules", "bool")
  if disable_modules == nil then
    disable_modules = true
  end

  local crop_on = false
  if disable_modules and tonumber(dt.gui.action("iop/crop", "enable")) == 1 then
    dt.gui.action("iop/crop", 0, "enable", "off", 1.0)
    crop_on = true
    dt.print_log("Crop desactivated")
  end

  local flip_on = false
  if disable_modules and tonumber(dt.gui.action("iop/flip", "enable")) == 1 then
    dt.gui.action("iop/flip", 0, "enable", "off", 1.0)
    flip_on = true
    dt.print_log("Flip desactivated")
  end

  local canvas_on = false
  if disable_modules and tonumber(dt.gui.action("iop/enlargecanvas", "enable")) == 1 then
    dt.gui.action("iop/enlargecanvas", 0, "enable", "off", 1.0)
    canvas_on = true
    dt.print_log("Canvas desactivated")
  end

  local borders_on = false
  if disable_modules and tonumber(dt.gui.action("iop/borders", "enable")) == 1 then
    dt.gui.action("iop/borders", 0, "enable", "off", 1.0)
    borders_on = true
    dt.print_log("Borders desactivated")
  end

  local lens_on = false
  if disable_modules and tonumber(dt.gui.action("iop/lens", "enable")) == 1 then
    dt.gui.action("iop/lens", 0, "enable", "off", 1.0)
    lens_on = true
    dt.print_log("Lens desactivated")
  end

  local function restore_modules()
    if not disable_modules then
      return
    end
    if crop_on then
      dt.gui.action("iop/crop", 0, "enable", "on", 1.0)
      dt.print_log("Crop re-enable")
    end

    if flip_on then
      dt.gui.action("iop/flip", 0, "enable", "on", 1.0)
      dt.print_log("Flip re-enable")
    end

    if canvas_on then
      dt.gui.action("iop/enlargecanvas", 0, "enable", "on", 1.0)
      dt.print_log("Canvas re-enable")
    end

    if borders_on then
      dt.gui.action("iop/borders", 0, "enable", "on", 1.0)
      dt.print_log("Borders re-enable")
    end

    if lens_on then
      dt.gui.action("iop/lens", 0, "enable", "on", 1.0)
      dt.print_log("Lens re-enable")
    end
  end

  if disable_modules then
    dt.gui.views.darkroom.display_image()
  end

  local root_dir = dt.preferences.read(mod, "sam2_out", "directory")

  for image_index, img in ipairs(images) do
    local is_windows = package.config:sub(1,1) == "\\"
    local png_path = export_to_temp_png(img, sld_size.value)
    local tmp_dir = dt.configuration.tmp_dir
    local out_dir = img.path

    local model = cbb_model.value
    local mode = cbb_mode.value
    local nb_mask = math.tointeger(sld_nb_mask.value)
    if not nb_mask then
      nb_mask = math.floor(tonumber(sld_nb_mask.value) or 0)
    end

    local model_id =
      (model == "sam2.1_hiera_large"      and 1) or
      (model == "sam2.1_hiera_base_plus"  and 2) or
      (model == "sam2.1_hiera_small"      and 3) or
      (model == "sam2.1_hiera_tiny"       and 4)

    local mode_flag = ""
    if mode == "Auto" then mode_flag = " --auto"
    elseif mode == "Points" then mode_flag = " --points"
    end

    local command
    if is_windows then
      command = string.format(
        'cmd /C ""%s" -i "%s" -o "%s" -m %s -n %s --pfm%s""',
        sam2_bin, png_path, tmp_dir, model_id, nb_mask, mode_flag
      )
    else
      command = string.format(
        '"%s" -i "%s" -o "%s" -m %s -n %s --pfm%s',
        sam2_bin, png_path, tmp_dir, model_id, nb_mask, mode_flag
      )
    end

    dt.print_log("Running: " .. command)
    local h = io.popen(command)
    if not h then
      dt.print(_("SAM2 command failed or returned no output"))
      restore_modules()
      os.remove(png_path)
      return
    end
    local out = h:read("*a")
    h:close()
    dt.print_log(out or "")
    if not out or out == "" then
      dt.print(_("SAM2 command failed or returned no output"))
      restore_modules()
      os.remove(png_path)
      return
    end

    if is_windows then
      local list_cmd = string.format('cmd /C dir /b "%s"', tmp_dir)
      for file in io.popen(list_cmd):lines() do
        if file:match("_mask") then
          local src = tmp_dir .. "\\" .. file
          local dst
          root_dir = tostring(root_dir or "")
          if root_dir == "(null)" then root_dir = "" end
          if not root_dir or root_dir == "" then
            dst = out_dir .. "\\" .. file
          else
            dst = root_dir .. "\\" .. file
          end
          local move_cmd = string.format('cmd /C move /Y "%s" "%s"', src, dst)
          os.execute(move_cmd)
          dt.print_log("Mask saved: " .. dst)
          dt.print("Mask saved")
        end
      end
    else
      for file in io.popen('ls "' .. tmp_dir .. '"'):lines() do
        if file:match("_mask") then
          local src = tmp_dir .. "/" .. file
          local dst
          root_dir = tostring(root_dir or "")
          if root_dir == "(null)" then root_dir = "" end
          if not root_dir or root_dir == "" then
            dst = out_dir .. "/" .. file
          else
            dst = root_dir .. "/" .. file
          end
          os.execute(string.format('mv "%s" "%s"', src, dst))
          dt.print_log("Mask saved: " .. dst)
          dt.print("Mask saved")
        end
      end
    end

    restore_modules()

    os.remove(png_path)
  end
end

local editor_button = dt.new_widget("button") {
  label=_("Generate Mask"),
  clicked_callback=function(_) btt_edit() end
}

-----------------------------------------------------------------------
-- MENU SWITCHER (Main / Settings)
-----------------------------------------------------------------------
local cbb_menu = dt.new_widget("combobox"){
  label = _("Menu"),
  "SAM2",
  "Settings",
  selected = 1,
  changed_callback = function(self)
    GUI.stack.active = self.selected
  end
}

cbb_menu.changed_callback = function(w)
  if not GUI.stack then return end
  local idx = w.selected or 1
  if idx < 1 then idx = 1 end
  GUI.stack.active = idx
end

-----------------------------------------------------------------------
-- BUILD GUI STACK
-----------------------------------------------------------------------
GUI.main_page = dt.new_widget("box"){
  orientation = "vertical",
  cbb_menu,
  cbb_model, cbb_mode,
  sld_size, sld_nb_mask,
  editor_button
}

GUI.settings_page = dt.new_widget("box"){
  orientation = "vertical",
  sam2_path_picker,
  output_path,
  disable_modules_toggle,
  reset_button,
  sam2_save_button
}

GUI.stack = dt.new_widget("stack"){
  GUI.main_page,
  GUI.settings_page
}

-- If no executable configured → go to Settings first
local saved = dt.preferences.read(mod, "sam2_bin", "string") or ""
if saved == "" then
  GUI.stack.active = 2
else
  GUI.stack.active = 1
end

-----------------------------------------------------------------------
-- INSTALL MODULE
-----------------------------------------------------------------------
local function safe_get_lib(name)
  local ok, lib = pcall(function() return dt.gui.libs[name] end)
  if ok then return lib end
  return nil
end

local function install_module()
  if mE.module_installed then return end
  mE.module_installed = true
  if safe_get_lib("SAM2") then return end
  dt.register_lib(
    "SAM2",
    _("SAM2"),
    true,
    false,
    {[dt.gui.views.darkroom] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
    dt.new_widget("box"){ orientation = "vertical", GUI.stack },
    nil, nil
  )
  mE.module_installed = true
end

local function destroy()
  local lib = safe_get_lib("SAM2")
  if lib then lib.visible = false end
end

local function restart()
  local lib = safe_get_lib("SAM2")
  if lib then lib.visible = true end
end

-----------------------------------------------------------------------
-- VIEW HANDLING
-----------------------------------------------------------------------
if dt.gui.current_view().id == "darkroom" then
  install_module()
else
  if not mE.event_registered then
    dt.register_event(
      "SAM2",
      "view-changed",
      function(event, old_view, new_view)
        if new_view.id == "darkroom" then install_module() end
      end
    )
    mE.event_registered = true
  end
end

-----------------------------------------------------------------------
-- Darktable Script Manager API
-----------------------------------------------------------------------
script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart

return script_data
