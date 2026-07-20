-- ConvertToDNG.lua

local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("9.4.0", "ConvertToDNG")

local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end

------------------------------------------------------------------------
-- Script metadata
------------------------------------------------------------------------
local script_data = {}
script_data.metadata = {
  name = "Convert to DNG",
  purpose = _("Wrap RAW sensor data in a DNG file"),
  author = "Ayeda Okambawa",
}

------------------------------------------------------------------------
-- Module state
------------------------------------------------------------------------
local mE = {}
mE.event_registered = false
mE.module_installed = false

local MODULE_ID = "ConvertToDNG"
local MODULE_NAME = _("Convert to DNG")

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function file_exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function build_unique_output_path(image)
  local separator = package.config:sub(1, 1) == "\\" and "\\" or "/"
  local base = image.filename:match("(.+)%.[^%.]+$") or image.filename
  local candidate = string.format("%s%s%s-converted.dng", image.path, separator, base)
  local index = 1

  while file_exists(candidate) do
    candidate = string.format("%s%s%s-converted_%d.dng", image.path, separator, base, index)
    index = index + 1
  end

  return candidate
end

local function convert_image(image)
  local output_path = build_unique_output_path(image)
  local raw_tensor = dt.ai.load_raw(image)
  dt.ai.save_dng(raw_tensor, image, output_path)

  local imported = dt.database.import(output_path)
  if imported then
    imported:group_with(image)
  end

  dt.print(_("DNG created for ") .. image.filename)
end

------------------------------------------------------------------------
-- Main conversion function
------------------------------------------------------------------------
local function convert_selected_images()
  if not dt.ai or not dt.ai.load_raw or not dt.ai.save_dng then
    dt.print_error("Convert to DNG requires darktable AI support")
    dt.print(_("Convert to DNG requires a darktable build with AI support"))
    return
  end

  local images = dt.gui.selection()
  if #images < 1 then
    dt.print(_("Select at least one RAW image"))
    return
  end

  dt.print(_("Starting DNG conversion"))
  local succeeded = 0

  for _, image in ipairs(images) do
    local ok, err = pcall(convert_image, image)
    if ok then
      succeeded = succeeded + 1
    else
      dt.print_error(string.format("Convert to DNG failed for %s: %s", image.filename, tostring(err)))
      dt.print(_("DNG conversion failed for ") .. image.filename)
    end
  end

  dt.print(string.format(_("DNG conversion complete: %d of %d succeeded"), succeeded, #images))
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local label = dt.new_widget("section_label"){
  label = _("Convert RAW files to DNG")
}

local convert_button = dt.new_widget("button"){
  label = _("Convert to DNG"),
  tooltip = _("Wrap the selected RAW files' sensor data in DNG files"),
  clicked_callback = function(_) convert_selected_images() end,
}

local options = dt.new_widget("box"){
  orientation = "vertical",
  label,
  convert_button,
}

------------------------------------------------------------------------
-- Module registration
------------------------------------------------------------------------
local function install_module()
  if not mE.module_installed then
    dt.register_lib(
      MODULE_ID,
      MODULE_NAME,
      true,
      false,
      {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      options,
      nil,
      nil
    )
    mE.module_installed = true
  end
end

local function destroy()
  if dt.gui.libs[MODULE_ID] then
    dt.gui.libs[MODULE_ID].visible = false
  end
end

local function restart()
  if dt.gui.libs[MODULE_ID] then
    dt.gui.libs[MODULE_ID].visible = true
  end
end

------------------------------------------------------------------------
-- View handling
------------------------------------------------------------------------
if dt.gui.current_view().id == "lighttable" then
  install_module()
elseif not mE.event_registered then
  dt.register_event(MODULE_ID, "view-changed", function(_, _, new_view)
    if new_view.id == "lighttable" then
      install_module()
    end
  end)
  mE.event_registered = true
end

------------------------------------------------------------------------
-- API for darktable script manager
------------------------------------------------------------------------
script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart

return script_data
