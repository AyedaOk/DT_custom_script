local dt = require "darktable"
local du = require "lib/dtutils"
du.check_min_api_version("7.0.0", "moduleExample")
local gettext = dt.gettext.gettext
local function _(msgid) return gettext(msgid) end
local script_data = {}
script_data.metadata = {
  name = "AI Tollbox",
  purpose = _("Use AI to tag and rate pictures"),
  author = "Ayéda Okambawa",
}
local mE = {}
mE.widgets = {}
mE.event_registered = false
mE.module_installed = false

-----------------------------------------------------------------------
-- Helper function: translate host path to docker /tmp path
-----------------------------------------------------------------------
local function host_to_docker_path(host_path)
  local temp_dir = dt.configuration.tmp_dir
  local osname = dt.configuration.running_os

  if osname == "windows" then
    -- Normalize Windows path: replace backslashes with slashes
    local norm = host_path:gsub("\\", "/")
    -- Try to strip off host temp dir and remap into /tmp
    local subpath = norm:match(".-[Tt]emp/(.+)$")
    if subpath then
      return "/tmp/" .. subpath
    else
      return subpath -- fallback if regex fails
    end
  else
    -- On Linux, /tmp is already correct
    return host_path
  end
end

-----------------------------------------------------------------------
-- UI Widgets
-----------------------------------------------------------------------
local cbb_tag = dt.new_widget("combobox") {
  label = _("Nb of tags"),
  value = 1,
  "1","2","3","4","5"
}
local cbb_model = dt.new_widget("combobox") {
  label = _("Model"),
  value = 2,
  "gemma3:27b","gemma3:12b","gemma3:4b","minicpm-v:8b","llava:7b"
}
local cbb_lvl = dt.new_widget("combobox") {
  label = _("Strictness"),
  value = 1,
  "Clement","Moderate","Rigorous"
}
local cbb_crt = dt.new_widget("combobox") {
  label = _("Criteria"),
  value = 1,
  "Balance","Sharpness","Composition","Color","Light","Emotion"
}
local sld_quality = dt.new_widget("slider") {
  label = _("Temporary JPG quality "),
  soft_min = 0, soft_max = 100, hard_min = 0, hard_max = 100,
  step = 1, digits = 0, value = 95
}
local sld_size = dt.new_widget("slider") {
  label = _("Temporary JPG size"),
  soft_min = 0, soft_max = 4096, hard_min = 0, hard_max = 4096,
  step = 1, digits = 0, value = 0
}
local cbt_clear = dt.new_widget("check_button"){label = _("Clear tags first"), value = true}
local separator1 = dt.new_widget("separator"){}

-----------------------------------------------------------------------
-- Export helper
-----------------------------------------------------------------------
local function export_to_temp_jpeg(img)
  local temp_file = os.tmpname() .. ".jpg"
  local jpeg_exporter = dt.new_format("jpeg")
  jpeg_exporter.quality = sld_quality.value
  jpeg_exporter.max_width = sld_size.value
  jpeg_exporter.max_height = sld_size.value
  jpeg_exporter:write_image(img, temp_file, true)
  dt.print_log(string.format("Exported %s to temp file %s", img.filename, temp_file))
  return temp_file
end

-----------------------------------------------------------------------
-- Tagging
-----------------------------------------------------------------------
local function tag_button()
  local images = dt.gui.selection()
  if #images == 0 then
    dt.print("No image selected") return
  end
  local selected_model = cbb_model.value
  local nb_tag = cbb_tag.value

  for _, img in ipairs(images) do
    local full_path = img.path .. "/" .. img.filename
    if cbt_clear.value == true then
      local current_tags = dt.tags.get_tags(img)
      for _, tag in ipairs(current_tags) do
        dt.tags.detach(tag, img)
      end
    end
    dt.print("Processing: " .. full_path)
    local jpeg_path = export_to_temp_jpeg(img)
	--print(jpeg_path)
    local docker_path = host_to_docker_path(jpeg_path)
	--print(docker_path)

    local prompt = "You are an expert in photo editing and darktable tag generation. " ..
                   "I will give you a description of an image. Based on the description, " ..
                   "provide a list of exactly " .. nb_tag ..
                   " darktable tags. " ..
                   "Only put the most pertinent tags. Do not include any introductory phrases. Only the tags separated with comas."

    local command = string.format(
      'docker exec ollama ollama run "%s" "%s" "%s"',
      selected_model, prompt, docker_path
    )
    print(command)

    local handle = io.popen(command)
    local output = handle:read("*a")
    handle:close()

    dt.print("Ollama output for " .. img.filename .. ": " .. output)

    for tag in string.gmatch(output, '([^,]+)') do
      local cleaned_tag = tag:match("^%s*(.-)%s*$")
      if cleaned_tag ~= "" then
        local tag_obj = dt.tags.create(cleaned_tag)
        dt.tags.attach(tag_obj, img)
        print("Added tag: " .. cleaned_tag)
      end
    end

    os.remove(jpeg_path)
  end
  dt.print("Tagging complete for " .. #images .. " image(s).")
end

-----------------------------------------------------------------------
-- Rating
-----------------------------------------------------------------------
local function btt_rating()
  local images = dt.gui.selection()
  if #images == 0 then
    dt.print("No image selected") return
  end
  local selected_model = cbb_model.value
  local strictness = cbb_lvl.value

  for _, img in ipairs(images) do
    local full_path = img.path .. "/" .. img.filename
    dt.print("Processing: " .. full_path)
    local jpeg_path = export_to_temp_jpeg(img)
	--print(jpeg_path)
    local docker_path = host_to_docker_path(jpeg_path)
	--print(docker_path)

    local prompt = "You are " .. strictness .. " professional photography evaluator. " ..
                   "I will provide an image. Assess its potential after editing. " ..
                   "Respond only with a single number, using this scale: -1 Reject, 1 Very Bad, 2 Bad, 3 Okay, 4 Good, 5 Very Good"

    local command = string.format(
      'docker exec ollama ollama run "%s" "%s" "%s"',
      selected_model, prompt, docker_path
    )
    print(command)

    local handle = io.popen(command)
    local output = handle:read("*a")
    handle:close()

    local rating = tonumber(output:match("(-?%d+)"))
    if rating then
      if rating < -1 then rating = -1 end
      if rating > 5 then rating = 5 end
      img.rating = rating
      print("Set rating for " .. img.filename .. " to " .. rating)
    else
      print("No valid rating found for " .. img.filename)
    end
    os.remove(jpeg_path)
  end
  dt.print("Rating complete for " .. #images .. " image(s).")
end

-----------------------------------------------------------------------
-- Select Best Image
-----------------------------------------------------------------------
local function btt_select_best()
  local images = dt.gui.selection()
  if #images < 2 then
    dt.print("Select at least two images") return
  end

  local selected_model = cbb_model.value
  local criteria = cbb_crt.value
  local prompt = "I am giving you multiple images. Select ONLY the best one (the one with the highest potential for photography). " ..
                 "Focus on " .. criteria .. ". Respond ONLY with the index number."

  local docker_paths = {}          -- to hold paths for the command
  local tempfile_paths = {}        -- to clean up later

  for idx, img in ipairs(images) do
    local jpeg_path = export_to_temp_jpeg(img)
    if not jpeg_path then
      dt.print("Export failed for " .. img.filename)
      return
    end

    local docker_path = host_to_docker_path(jpeg_path)
    table.insert(docker_paths, '"' .. docker_path .. '"')  -- quote each path
    table.insert(tempfile_paths, { img = img, path = jpeg_path })
  end

  -- Combine prompt and image paths into final docker command
  local command = string.format(
    'docker exec ollama ollama run "%s" "%s" %s',
    selected_model, prompt, table.concat(docker_paths, " ")
  )

  print("Running command:\n" .. command)
  local handle = io.popen(command)
  local output = handle:read("*a")
  handle:close()

  dt.print("Ollama output: " .. output)
  print("Model output: " .. output)

  local chosen_index = tonumber(output:match("(%d+)"))
  if not chosen_index or chosen_index < 1 or chosen_index > #images then
    dt.print("Could not determine best image index")
    for _, t in ipairs(tempfile_paths) do os.remove(t.path) end
    return
  end

  for idx, t in ipairs(tempfile_paths) do
    if idx ~= chosen_index then
      t.img.rating = -1
      print("Rejected: " .. t.img.filename)
    else
      t.img.rating = 0
      print("Best image kept: " .. t.img.filename)
    end
    os.remove(t.path)
  end

  dt.print("Best image kept. Others rejected.")
end


-----------------------------------------------------------------------
-- GUI / Module lifecycle
-----------------------------------------------------------------------
local function install_module()
  if not mE.module_installed then
    dt.register_lib(
      "AIToolbox",
      _("AI Toolbox"),
      true,
      false,
      {[dt.gui.views.lighttable] = {"DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100}},
      dt.new_widget("box") { orientation = "vertical", table.unpack(mE.widgets) },
      nil,nil
    )
    mE.module_installed = true
  end
end
local function destroy() dt.gui.libs["AIToolbox"].visible = false end
local function restart() dt.gui.libs["AIToolbox"].visible = true end

-- Labels
local lbl_tag = dt.new_widget("section_label"); lbl_tag.label = _("AI Tag Assistant")
local lbl_rating = dt.new_widget("section_label"); lbl_rating.label = _("AI Rating")
local lbl_setting = dt.new_widget("section_label"); lbl_setting.label = _("Settings")
local lbl_reject = dt.new_widget("section_label"); lbl_reject.label = _("AI's Top Pick'")

-- Buttons
local generate_button = dt.new_widget("button") {label=_("Generate"), clicked_callback=function(_) tag_button() end}
local rating_button = dt.new_widget("button") {label=_("Generate"), clicked_callback=function(_) btt_rating() end}
local reject_button = dt.new_widget("button") {label=_("Generate"), clicked_callback=function(_) btt_select_best() end}

mE.widgets = {
  lbl_tag, cbt_clear, cbb_tag, separator1, generate_button,
  lbl_rating, cbb_lvl, rating_button,
  lbl_reject, cbb_crt, reject_button,
  lbl_setting, cbb_model, sld_quality, sld_size
}

if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  if not mE.event_registered then
    dt.register_event("AIToolbox", "view-changed", function(event, old_view, new_view)
      if new_view.id == "lighttable" then install_module() end
    end)
    mE.event_registered = true
  end
end

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart
return script_data
