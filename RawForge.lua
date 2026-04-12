-- RawForge.lua

local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("7.0.0", "RawForge")

local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end

-----------------------------------------------------------------------
-- Script metadata
-----------------------------------------------------------------------
local script_data = {}
script_data.metadata = {
  name = "RawForge",
  purpose = _("RAW denoise with RawForge"),
  author = "Ayeda Okambawa",
}

-----------------------------------------------------------------------
-- Module state
-----------------------------------------------------------------------
local mE = {}
mE.widgets = {}
mE.event_registered = false
mE.module_installed = false

local mod = "module_RawForge"
local GUI = {}

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function build_unique_output_path(dir_path, base_name, sep)
  local candidate = string.format("%s%s%s-rawforge.dng", dir_path, sep, base_name)
  if not file_exists(candidate) then
    return candidate
  end

  local index = 1
  while true do
    candidate = string.format("%s%s%s-rawforge_%d.dng", dir_path, sep, base_name, index)
    if not file_exists(candidate) then
      return candidate
    end
    index = index + 1
  end
end

-----------------------------------------------------------------------
-- UI Widgets (main page)
-----------------------------------------------------------------------
local cbb_menu = dt.new_widget("combobox"){
  label = _("Menu"),
  tooltip = _("Switch between RawForge and Settings views"),
  selected = 1,
  "RawForge",
  "Settings",
  changed_callback = function(self)
    dt.print_log("RawForge menu changed; GUI.stack=" .. tostring(GUI.stack))
    if GUI.stack then
      if self.selected == 1 then
        GUI.stack.active = 1
      elseif self.selected == 2 then
        GUI.stack.active = 2
      end
    else
      dt.print_log("RawForge: GUI.stack not ready; menu change ignored")
    end
  end
}

local cbb_models = dt.new_widget("combobox"){
  label = _("Model"),
  tooltip = _("Select RawForge denoise model"),
  selected = 1,
  "TreeNetDenoise",
  "TreeNetDenoiseLight",
  "TreeNetDenoiseHeavy",
  "TreeNetDenoiseSuperLight",
  "Deblur",
  "DeepSharpen",
}

local sld_lumi = dt.new_widget("slider") {
  label = _("Lumi"),
  tooltip = _("Luminance noise added back to output (0 to 1)"),
  soft_min = 0,
  soft_max = 1,
  hard_min = 0,
  hard_max = 1,
  step = 0.1,
  digits = 1,
  value = 0,
}

local sld_chroma = dt.new_widget("slider") {
  label = _("Chroma"),
  tooltip = _("Chroma noise added back to output (0 to 1)"),
  soft_min = 0,
  soft_max = 1,
  hard_min = 0,
  hard_max = 1,
  step = 0.1,
  digits = 1,
  value = 0,
}

-----------------------------------------------------------------------
-- Main processing function
-----------------------------------------------------------------------
local function do_denoise()
  local images = dt.gui.selection()
  if #images < 1 then
    dt.print(_("Select at least one image"))
    return
  end

  dt.print(_("Starting RawForge"))
  local rawforge_bin = dt.preferences.read(mod, "rawforge_bin", "string") or "rawforge"
  local exif_bin = dt.preferences.read(mod, "exif_bin", "string") or "exiftool"

  if rawforge_bin == "" or exif_bin == "" then
    dt.print(_("Please set executable paths in Settings"))
    return
  end

  local is_windows = package.config:sub(1, 1) == "\\"
  local sep = is_windows and "\\" or "/"

  local model = cbb_models.value
  local lumi = tostring(sld_lumi.value):gsub(",", ".")
  local chroma = tostring(sld_chroma.value):gsub(",", ".")
  local is_refine_model = (model == "Deblur" or model == "DeepSharpen")

  for image_index, img in ipairs(images) do
    local input_file = img.path .. sep .. img.filename
    local base = img.filename:match("(.+)%.[^%.]+$") or img.filename
    local out_file = build_unique_output_path(img.path, base, sep)

    local command_rawforge
    if is_windows then
      if is_refine_model then
        command_rawforge = string.format(
          'cmd /c ""%s" %s "%s" "%s""',
          rawforge_bin, model, input_file, out_file
        )
      else
        command_rawforge = string.format(
          'cmd /c ""%s" %s "%s" "%s" --cfa --lumi %s --chroma %s"',
          rawforge_bin, model, input_file, out_file, lumi, chroma
        )
      end
    else
      if is_refine_model then
        command_rawforge = string.format(
          '"%s" %s "%s" "%s"',
          rawforge_bin, model, input_file, out_file
        )
      else
        command_rawforge = string.format(
          '"%s" %s "%s" "%s" --cfa --lumi %s --chroma %s',
          rawforge_bin, model, input_file, out_file, lumi, chroma
        )
      end
    end

    dt.print_log("Running: " .. command_rawforge)
    local h = io.popen(command_rawforge)
    local rawforge_out = ""
    if h then
      rawforge_out = h:read("*a") or ""
      h:close()
    end
    dt.print_log(rawforge_out)

    if not file_exists(out_file) then
      dt.print(_("RawForge failed for ") .. img.filename)
      goto continue
    end

    local command_exif
    if is_windows then
      command_exif = string.format(
        'cmd /c ""%s" -overwrite_original -TagsFromFile "%s" -all:all -IFD0:CalibrationIlluminant1#=21 "%s""',
        exif_bin, input_file, out_file
      )
    else
        command_exif = string.format(
          '"%s" -overwrite_original -TagsFromFile "%s" -all:all -IFD0:CalibrationIlluminant1#=21 "%s"',
          exif_bin, input_file, out_file
        )
    end

    dt.print_log("Running: " .. command_exif)
    local h2 = io.popen(command_exif)
    local exif_out = ""
    if h2 then
      exif_out = h2:read("*a") or ""
      h2:close()
    end
    dt.print_log(exif_out)

    dt.database.import(out_file)
    dt.print(_("RawForge done for ") .. img.filename)

    ::continue::
  end
end

-----------------------------------------------------------------------
-- Executable path selection UI
-----------------------------------------------------------------------
dt.preferences.register(
  mod,
  "rawforge_bin",
  "string",
  _("RawForge binary path"),
  _("Path to the RawForge executable"),
  ""
)

dt.preferences.register(
  mod,
  "exif_bin",
  "string",
  _("ExifTool binary path"),
  _("Path to the exiftool executable"),
  ""
)

local exe_rawforge = dt.new_widget("file_chooser_button"){
  title = _("Select rawforge executable"),
  value = dt.preferences.read(mod, "rawforge_bin", "string") or "rawforge",
  is_directory = false,
  tooltip = _("Path to the rawforge executable"),
}

local exe_exif = dt.new_widget("file_chooser_button"){
  title = _("Select exiftool executable"),
  value = dt.preferences.read(mod, "exif_bin", "string") or "exiftool",
  is_directory = false,
  tooltip = _("Path to the exiftool executable"),
}

local exe_update = dt.new_widget("button"){
  label = _("Save paths"),
  clicked_callback = function()
    dt.preferences.write(mod, "rawforge_bin", "string", exe_rawforge.value)
    dt.preferences.write(mod, "exif_bin", "string", exe_exif.value)
    GUI.stack.active = 1
    dt.print(_("Executable paths updated"))
  end
}

-----------------------------------------------------------------------
-- Labels and buttons
-----------------------------------------------------------------------
local lbl_rawforge = dt.new_widget("section_label"){ label = _("RawForge") }

local denoise_button = dt.new_widget("button") {
  label = _("Denoise"),
  clicked_callback = function(_) do_denoise() end,
}

-----------------------------------------------------------------------
-- GUI layout assembly
-----------------------------------------------------------------------
GUI.options = dt.new_widget("box"){
  orientation = "vertical",
  lbl_rawforge,
  cbb_menu,
  cbb_models,
  sld_lumi,
  sld_chroma,
  denoise_button,
}

local exe_box = dt.new_widget("box"){
  orientation = "vertical",
  exe_rawforge,
  exe_exif,
  exe_update,
}

GUI.stack = dt.new_widget("stack"){ GUI.options, exe_box }

if (dt.preferences.read(mod, "rawforge_bin", "string") or "") == "" or
   (dt.preferences.read(mod, "exif_bin", "string") or "") == "" then
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
      "RawForge",
      _("RawForge"),
      true,
      false,
      {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      dt.new_widget("box"){ orientation = "vertical", GUI.stack },
      nil,
      nil
    )
    mE.module_installed = true
  end
end

local function destroy()
  if dt.gui.libs["RawForge"] then
    dt.gui.libs["RawForge"].visible = false
  end
end

local function restart()
  if dt.gui.libs["RawForge"] then
    dt.gui.libs["RawForge"].visible = true
  end
end

-----------------------------------------------------------------------
-- View handling
-----------------------------------------------------------------------
if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  if not mE.event_registered then
    dt.register_event("RawForge", "view-changed",
      function(event, old_view, new_view)
        if new_view.id == "lighttable" then
          install_module()
        end
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
