local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("7.0.0", "SAM3")

local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end

-----------------------------------------------------------------------
-- Script metadata
-----------------------------------------------------------------------
local script_data = {}
script_data.metadata = {
  name = "SAM3",
  purpose = _("AI masking using SAM3"),
  author = "Ayéda Okambawa",
}

-----------------------------------------------------------------------
-- Module state
-----------------------------------------------------------------------
_G.__SAM3_STATE = _G.__SAM3_STATE or { module_installed = false, event_registered = false }
local mE = _G.__SAM3_STATE


-- Preferences module name
local mod = "module_SAM3_tools"

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
-- Helper: POSIX shell quoting (for Linux/macOS)
-----------------------------------------------------------------------
local function shell_quote_posix(s)
  -- Wrap with single quotes and escape existing single quotes
  -- abc'def -> 'abc'"'"'def'
  return "'" .. tostring(s):gsub("'", [["'"'"']]) .. "'"
end

-----------------------------------------------------------------------
-- SETTINGS UI (sam3-tools executable path)
-----------------------------------------------------------------------
local sam3_path_picker = dt.new_widget("file_chooser_button"){
  title = _("Select sam3-tools executable"),
  value = dt.preferences.read(mod, "sam3_bin", "string") or "sam3-tools",
  is_directory = false,
  tooltip = _("Path to the sam3-tools executable"),
}

local sam3_save_button = dt.new_widget("button"){
  label = _("Save"),
  clicked_callback = function()
    dt.preferences.write(mod, "sam3_bin", "string", sam3_path_picker.value)
    GUI.stack.active = 1
    dt.print(_("SAM3 executable path updated"))
  end
}

-----------------------------------------------------------------------
-- MAIN SAM3 UI
-----------------------------------------------------------------------
local cbb_mode = dt.new_widget("combobox") {
  label = _("Mode"),
  value = 1,
  "Text","Box","Points","Auto",
}

local entry_prompt = dt.new_widget("entry"){
  text = "",
  placeholder = _("Enter your prompt here"),
  is_password = false,
  editable = true,
  tooltip = _("Used only in Text mode (Mode = Text)"),
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

-- Show prompt box only when Text mode is selected
entry_prompt.visible = (cbb_mode.value == "Text")
cbb_mode.changed_callback = function(self)
  entry_prompt.visible = (self.value == "Text")
end

-----------------------------------------------------------------------
-- MAIN BUTTON
-----------------------------------------------------------------------
local function btt_edit()
  local images = dt.gui.selection()
  if not images or #images == 0 then
    dt.print(_("No image available"))
    return
  end
  dt.print(_("Starting SAM3 mask generation..."))

  -- Retrieve saved SAM3 executable
  local sam3_bin = dt.preferences.read(mod, "sam3_bin", "string") or "sam3-tools"
  if sam3_bin == "" then
    dt.print(_("Please set the SAM3 executable path in Settings"))
    GUI.stack.active = 2
    return
  end

  for _, img in ipairs(images) do
    local is_windows = package.config:sub(1,1) == "\\"
    local png_path = export_to_temp_png(img, sld_size.value)
    local tmp_dir = dt.configuration.tmp_dir
    local out_dir = img.path

    local mode = cbb_mode.value
    local nb_mask = math.tointeger(sld_nb_mask.value)

    -- Build mode flag
    local mode_flag = ""
    if mode == "Auto" then
      mode_flag = " --auto"
    elseif mode == "Points" then
      mode_flag = " --points"
    elseif mode == "Text" then
      local prompt = entry_prompt.text or ""
      if prompt == "" then
        dt.print(_("Text mode selected but prompt is empty"))
        os.remove(png_path)
        return
      end

      if is_windows then
         prompt = tostring(prompt):gsub('"', "'")
        mode_flag = string.format(' --text "%s"', prompt)
      else
        mode_flag = " --text " .. shell_quote_posix(prompt)
      end
    end

    -- Build command
    local command
    if is_windows then
      command = string.format(
        'cmd /C ""%s" -i "%s" -o "%s" -n %s --pfm%s""',
        sam3_bin, png_path, tmp_dir, nb_mask, mode_flag
      )
    else
      command = string.format(
        '"%s" -i "%s" -o "%s" -n %s --pfm%s',
        sam3_bin, png_path, tmp_dir, nb_mask, mode_flag
      )
    end

    dt.print_log("Running: " .. command)
    local h = io.popen(command)
    local out = h:read("*a")
    h:close()
    dt.print_log(out or "")

    -- Move generated masks back to the image folder
    if is_windows then
      local list_cmd = string.format('cmd /C dir /b "%s"', tmp_dir)
      for file in io.popen(list_cmd):lines() do
        if file:match("_mask") then
          local src = tmp_dir .. "\\" .. file
          local dst = out_dir .. "\\" .. file
          local move_cmd = string.format('cmd /C move /Y "%s" "%s"', src, dst)
          os.execute(move_cmd)
          dt.print_log("Mask saved: " .. dst)
        end
      end
    else
      for file in io.popen('ls "' .. tmp_dir .. '"'):lines() do
        if file:match("_mask") then
          local src = tmp_dir .. "/" .. file
          local dst = out_dir .. "/" .. file
          os.execute(string.format('mv "%s" "%s"', src, dst))
          dt.print_log("Mask saved: " .. dst)
        end
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
  "SAM3",
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
  cbb_mode,
  entry_prompt,
  sld_size, sld_nb_mask,
  editor_button
}

GUI.settings_page = dt.new_widget("box"){
  orientation = "vertical",
  sam3_path_picker,
  sam3_save_button
}

GUI.stack = dt.new_widget("stack"){
  GUI.main_page,
  GUI.settings_page
}

-- If no executable configured → go to Settings first
local saved = dt.preferences.read(mod, "sam3_bin", "string") or ""
if saved == "" then
  GUI.stack.active = 2
else
  GUI.stack.active = 1
end

-----------------------------------------------------------------------
-- INSTALL MODULE
-----------------------------------------------------------------------
local function install_module()
  if mE.module_installed then return end
  dt.register_lib(
      "SAM3",
      _("SAM3"),
      true,
      false,
      {[dt.gui.views.darkroom] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      dt.new_widget("box") { orientation = "vertical", GUI.stack },
      nil, nil
    )
  mE.module_installed = true
end

local function destroy()
  local lib = dt.gui.libs["SAM3"]
  if lib then lib.visible = false end
end

local function restart()
  local lib = dt.gui.libs["SAM3"]
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
      "SAM3",
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
