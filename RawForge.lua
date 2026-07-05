-- RawForge.lua

local dt = require("darktable")
local du = require("lib/dtutils")
local df = require("lib/dtutils.file")
du.check_min_api_version("7.0.0", "RawForge")

local gettext = dt.gettext.gettext
local function _(msgid)
  return gettext(msgid)
end

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

if df.get_executable_path_preference("rawforge") == nil then
  df.set_executable_path_preference("rawforge", "")
end

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

local cbb_models = dt.new_widget("combobox")({
  label = _("Model"),
  tooltip = _("Select RawForge denoise model"),
  selected = 1,

  -- Bayer  models
  "TreeNetDenoise",
  "TreeNetDenoiseLight",
  "TreeNetDenoiseSuperLight",
  "TreeNetDenoiseHeavy",
  "Deblur",
  "DeepSharpen",

  -- X-Trans models
  "TreeNetDenoiseXTrans",
  "XFormerXTrans",
  "XFormerXTrans352",
  "RestormerXTrans",
})

local sld_lumi = dt.new_widget("slider")({
  label = _("Lumi"),
  tooltip = _("Luminance noise added back to output (0 to 1)"),
  soft_min = 0,
  soft_max = 1,
  hard_min = 0,
  hard_max = 1,
  step = 0.1,
  digits = 1,
  value = 0,
})

local sld_chroma = dt.new_widget("slider")({
  label = _("Chroma"),
  tooltip = _("Chroma noise added back to output (0 to 1)"),
  soft_min = 0,
  soft_max = 1,
  hard_min = 0,
  hard_max = 1,
  step = 0.1,
  digits = 1,
  value = 0,
})

local cbt_clip_highlights = dt.new_widget("check_button")({
  label = _("Preserve Clipped Highlights"),
  tooltip = _("Do not run model on clipped highlights"),
  value = false,
})

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
  local rawforge_bin = df.check_if_bin_exists("rawforge")

  if not rawforge_bin then
    dt.print(_("rawforge not found; install it or set its path in executable manager"))
    return
  end

  local is_windows = package.config:sub(1, 1) == "\\"
  local sep = is_windows and "\\" or "/"

  local model = cbb_models.value
  local lumi = tostring(sld_lumi.value):gsub(",", ".")
  local chroma = tostring(sld_chroma.value):gsub(",", ".")
  local is_refine_model = (model == "Deblur" or model == "DeepSharpen")
  local clip_flag = cbt_clip_highlights.value and "--clip_highlights" or ""

  for image_index, img in ipairs(images) do
    local input_file = img.path .. sep .. img.filename
    local base = img.filename:match("(.+)%.[^%.]+$") or img.filename
    local out_file = build_unique_output_path(img.path, base, sep)

    local command_rawforge
    if is_windows then
      if is_refine_model then
        command_rawforge = string.format('cmd /c ""%s" %s "%s" "%s""', rawforge_bin, model, input_file, out_file)
      else
        command_rawforge = string.format(
          'cmd /c ""%s" %s "%s" "%s" --cfa --lumi %s --chroma %s %s"',
          rawforge_bin,
          model,
          input_file,
          out_file,
          lumi,
          chroma,
          clip_flag
        )
      end
    else
      if is_refine_model then
        command_rawforge = string.format('"%s" %s "%s" "%s"', rawforge_bin, model, input_file, out_file)
      else
        command_rawforge = string.format(
          '"%s" %s "%s" "%s" --cfa --lumi %s --chroma %s %s',
          rawforge_bin,
          model,
          input_file,
          out_file,
          lumi,
          chroma,
          clip_flag
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

    dt.database.import(out_file)
    dt.print(_("RawForge done for ") .. img.filename)

    ::continue::
  end
end

local lbl_rawforge = dt.new_widget("section_label")({ label = _("RawForge") })

local denoise_button = dt.new_widget("button")({
  label = _("Denoise"),
  clicked_callback = function(_)
    do_denoise()
  end,
})

local options = dt.new_widget("box")({
  orientation = "vertical",
  lbl_rawforge,
  cbb_models,
  sld_lumi,
  sld_chroma,
  cbt_clip_highlights,
  denoise_button,
})

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
      { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
      dt.new_widget("box")({ orientation = "vertical", options }),
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
    dt.register_event("RawForge", "view-changed", function(event, old_view, new_view)
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
