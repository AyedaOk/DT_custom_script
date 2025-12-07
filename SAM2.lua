local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("7.0.0", "SAM2")

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
local mE = {}
mE.widgets = {}
mE.event_registered = false
mE.module_installed = false

-- Preferences module name
local mod = "module_SAM2_tools"

GUI = {}

-----------------------------------------------------------------------
-- Helper: export PNG
-----------------------------------------------------------------------
local function export_to_temp_png(img, size)
  local base = img.filename:match("(.+)%..+$")
  local temp_file = dt.configuration.tmp_dir .. "/" .. base .. ".png"
  local png_exporter = dt.new_format("png")
  png_exporter.max_width = size
  png_exporter.max_height = size
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

local sam2_save_button = dt.new_widget("button"){
  label = _("Save"),
  clicked_callback = function()
    dt.preferences.write(mod, "sam2_bin", "string", sam2_path_picker.value)
    GUI.stack.active = 1
    dt.print(_("SAM2 executable path updated"))
  end
}

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

  -- Retrieve saved SAM2 executable
  local sam2_bin = dt.preferences.read(mod, "sam2_bin", "string") or "sam2-tools"
  if sam2_bin == "" then
    dt.print(_("Please set the SAM2 executable path in Settings"))
    GUI.stack.active = 2
    return
  end

  for _, img in ipairs(images) do
    local png_path = export_to_temp_png(img, sld_size.value)
    local tmp_dir = dt.configuration.tmp_dir
    local out_dir = img.path

    local model = cbb_model.value
    local mode = cbb_mode.value
    local nb_mask = math.tointeger(sld_nb_mask.value)

    local model_id =
      (model == "sam2.1_hiera_large"      and 1) or
      (model == "sam2.1_hiera_base_plus"  and 2) or
      (model == "sam2.1_hiera_small"      and 3) or
      (model == "sam2.1_hiera_tiny"       and 4)

    local mode_flag = ""
    if mode == "Auto" then mode_flag = " --auto"
    elseif mode == "Points" then mode_flag = " --points"
    end

    local command = string.format(
      '"%s" -i "%s" -o "%s" -m %s -n %s --pfm%s',
      sam2_bin, png_path, tmp_dir, model_id, nb_mask, mode_flag
    )

    dt.print_log("Running: " .. command)
    local h = io.popen(command)
    local out = h:read("*a")
    h:close()

    -- Move masks to same directory as image
    for file in io.popen('ls "' .. tmp_dir .. '"'):lines() do
      if file:match("_mask") then
        local src = tmp_dir .. "/" .. file
        local dst = out_dir .. "/" .. file
        os.execute(string.format('mv "%s" "%s"', src, dst))
        dt.print_log("Mask saved: " .. dst)
      end
    end

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
local function install_module()
  if not mE.module_installed then
    dt.register_lib(
      "SAM2",
      _("SAM2"),
      true,
      false,
      {[dt.gui.views.darkroom] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      dt.new_widget("box") {
        orientation = "vertical",
        GUI.stack
      },
      nil, nil
    )
    mE.module_installed = true
  end
end

local function destroy()
  dt.gui.libs["SAM2"].visible = false
end

local function restart()
  dt.gui.libs["SAM2"].visible = true
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
