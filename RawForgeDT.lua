-- RawForgeAI.lua
-- Todos:
-- - Marche pas quand j'exporte en DNG. Juste le tiff qui marche. Voir ce qu'on peut faire.
-- - Travailler sur le UI. Combobox pour les models.
-- - Overlappé les tiles

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
du.check_min_api_version("9.4.0", "RawForge")

local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end

-----------------------------------------------------------------------
-- Script metadata
-----------------------------------------------------------------------
local script_data = {}
script_data.metadata = {
  name = "RawForge DT",
  purpose = _("RAW denoise with RawForge ONNX via darktable.ai"),
  author = "Ayeda Okambawa",
}

-----------------------------------------------------------------------
-- Module state
-----------------------------------------------------------------------
local mE = {}
mE.widgets = {}
mE.event_registered = false
mE.module_installed = false

local MODULE_ID = "RawForgeDT"
local MODULE_NAME = _("RawForge")
local TILE_SIZE = 256

local MODEL_IDS = {
  TreeNetDenoise = "rawdenoise-rawforge-shadowweightedl1",
  TreeNetDenoiseLight = "rawdenoise-rawforge-shadowweightedl1-light",
  TreeNetDenoiseSuperLight = "rawdenoise-rawforge-shadowweightedl1-super-light",
  TreeNetDenoiseHeavy = "rawdenoise-rawforge-shadowweightedl1-heavy",
  Deblur = "rawdenoise-rawforge-realblur-gamma-140",
  DeepSharpen = "rawdenoise-rawforge-deblur-deep-24",
  TreeNetDenoiseXTrans = "rawdenoise-rawforge-xtrans",
  RestormerXTrans = "rawdenoise-rawforge-restormer-xtrans",
}

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

local function path_sep()
  return package.config:sub(1, 1) == "\\" and "\\" or "/"
end

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

local function quote_path(path)
  return string.format('"%s"', tostring(path):gsub('"', '\\"'))
end

local function run_command(command)
  dt.print_log("Running: " .. command)
  local h = io.popen(command)
  local out = ""
  if h then
    out = h:read("*a") or ""
    h:close()
  end
  dt.print_log(out)
end

local function copy_exif(exif_bin, src_file, dst_file)
  if not exif_bin or exif_bin == "" then
    return
  end

  local command
  if is_windows() then
    command = string.format(
      'cmd /c ""%s" -overwrite_original -TagsFromFile %s -all:all -Orientation#=1 %s"',
      exif_bin, quote_path(src_file), quote_path(dst_file)
    )
  else
    command = string.format(
      '%s -overwrite_original -TagsFromFile %s -all:all -Orientation#=1 %s',
      quote_path(exif_bin), quote_path(src_file), quote_path(dst_file)
    )
  end

  run_command(command)
end

local function copy_darktable_metadata(src, dst)
  if not dst then
    return
  end

  pcall(function() dst:group_with(src) end)
  pcall(function() dst.rating = src.rating end)
  pcall(function() dst.exif_datetime_taken = src.exif_datetime_taken end)

  pcall(function()
    for _, tag in ipairs(src:get_tags()) do
      dst:attach_tag(tag)
    end
  end)
end

local function build_unique_output_path(dir_path, base_name, sep)
  local candidate = string.format("%s%s%s-rawforge.tif", dir_path, sep, base_name)
  if not file_exists(candidate) then
    return candidate
  end

  local index = 1
  while true do
    candidate = string.format("%s%s%s-rawforge_%d.tif", dir_path, sep, base_name, index)
    if not file_exists(candidate) then
      return candidate
    end
    index = index + 1
  end
end

local function image_iso(img)
  local iso = tonumber(img.exif_iso) or 100
  if iso <= 0 then iso = 100 end
  return iso
end

local function create_condition_tensor(iso)
  local cond = dt.ai.create_tensor({1, 1})
  cond:set({0, 0}, iso / 6400.0)
  return cond
end

local function tensor_shape_string(t)
  local shape = t:shape()
  local parts = {}
  for i, v in ipairs(shape) do
    parts[i] = tostring(v)
  end
  return table.concat(parts, "x")
end

local function round_up(value, multiple)
  return math.floor((value + multiple - 1) / multiple) * multiple
end

local function run_tiled(ctx, input, cond, tile_size, use_cond)
  local shape = input:shape()
  local h = shape[3]
  local w = shape[4]
  local padded_h = round_up(h, tile_size)
  local padded_w = round_up(w, tile_size)

  local padded_input = dt.ai.create_tensor({1, 3, padded_h, padded_w})
  padded_input:fill(0.0)
  padded_input:paste(input, 0, 0)

  local padded_output = dt.ai.create_tensor({1, 3, padded_h, padded_w})
  padded_output:fill(0.0)

  local total_tiles = (padded_h / tile_size) * (padded_w / tile_size)
  local tile_index = 0

  for y = 0, padded_h - tile_size, tile_size do
    for x = 0, padded_w - tile_size, tile_size do
      tile_index = tile_index + 1
      dt.print_log(string.format(
        "RawForge: tile %d/%d at y=%d x=%d",
        tile_index, total_tiles, y, x))

      local tile = padded_input:crop(y, x, tile_size, tile_size)
      local tile_out
      if use_cond then
        tile_out = ctx:run(tile, cond)
      else
        tile_out = ctx:run(tile)
      end
      padded_output:paste(tile_out, y, x)
    end
  end

  return padded_output:crop(0, 0, h, w)
end

-----------------------------------------------------------------------
-- UI Widgets
-----------------------------------------------------------------------
local lbl_rawforge = dt.new_widget("section_label") { label = _("RawForge AI") }

local cbb_models = dt.new_widget("combobox"){
  label = _("Model"),
  tooltip = _("Select RawForge AI model"),
  selected = 1,
  "TreeNetDenoise",
  "TreeNetDenoiseLight",
  "TreeNetDenoiseSuperLight",
  "TreeNetDenoiseHeavy",
  "Deblur",
  "DeepSharpen",
  "TreeNetDenoiseXTrans",
  "RestormerXTrans",
}

-----------------------------------------------------------------------
-- Main processing function
-----------------------------------------------------------------------
local function denoise_one(ctx, img, use_cond)
  local sep = path_sep()
  local input_file = img.path .. sep .. img.filename
  local base = img.filename:match("(.+)%.[^%.]+$") or img.filename
  local out_file = build_unique_output_path(img.path, base, sep)
  local iso = image_iso(img)

  dt.print_log(string.format("RawForge: loading image %s", input_file))
  local input = dt.ai.load_image(img)
  local cond = create_condition_tensor(iso)

  dt.print_log(string.format(
    "RawForge: input=%s iso=%.0f cond=%.6f",
    tensor_shape_string(input), iso, iso / 6400.0))

  local output = run_tiled(ctx, input, cond, TILE_SIZE, use_cond)
  dt.print_log("RawForge AI: output=" .. tensor_shape_string(output))

  output:save_tiff(out_file, 16, img)
  local exif_bin = df.check_if_bin_exists("exiftool")
  if exif_bin then
    copy_exif(exif_bin, input_file, out_file)
  else
    dt.print(_("exiftool not found; TIFF imported without copied EXIF metadata"))
  end

  local imported = dt.database.import(out_file)
  copy_darktable_metadata(img, imported)
  dt.print(_("RawForge done for ") .. img.filename)
end

local function do_denoise()
  local images = dt.gui.selection()
  if #images < 1 then
    dt.print(_("Select at least one image"))
    return
  end

  local model_name = cbb_models.value
  local model_id = MODEL_IDS[model_name] or MODEL_ID
  local use_cond = model_name ~= "RestormerXTrans"

  dt.print(_("Starting RawForge"))

  local ok, err = pcall(function()
    local ctx = dt.ai.load_model(model_id)
    for _, img in ipairs(images) do
      local one_ok, one_err = pcall(denoise_one, ctx, img, use_cond)
      if not one_ok then
        dt.print_error(string.format("RawForge failed for %s: %s", img.filename, tostring(one_err)))
      end
    end
    ctx:close()
  end)

  if not ok then
    dt.print_error("RawForge failed: " .. tostring(err))
  end
end

local denoise_button = dt.new_widget("button") {
  label = _("Denoise"),
  clicked_callback = function(_) do_denoise() end,
}

mE.widgets = {
  lbl_rawforge,
  cbb_models,
  denoise_button,
}

-----------------------------------------------------------------------
-- Module registration
-----------------------------------------------------------------------
local function install_module()
  if not mE.module_installed then
    dt.register_lib(
      MODULE_ID,
      MODULE_NAME,
      true,
      false,
      {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      dt.new_widget("box") { orientation = "vertical", table.unpack(mE.widgets) },
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

if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  if not mE.event_registered then
    dt.register_event(MODULE_ID, "view-changed",
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
