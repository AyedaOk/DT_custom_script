# Darktable Lua Scripts Collection

A collection of enhanced Darktable Lua plugins, including improved focus stacking tools, AI utilities, and SAM2 segmentation support.

## Table of Contents
- SAM2 Segmentation Plugin  
- Enfuse Simple  
- Enfuse Advanced  
- AI Toolbox  

---

# SAM2 AI Masking Plugin
## Description
A Darktable plugin that uses **Meta AI’s SAM2 image segmentation model** to generate masks directly from Darktable.

- Linux install video → https://youtu.be/C98gejXkQqI  

---

# Enfuse Simple
## Description
A simplified focus stacking and HDR plugin using `enfuse` and `align_image_stack`.

Differences from Enfuse Advanced:
• Simplier  
• Fully cross‑platform (Linux, macOS, Windows)

Install video → https://youtu.be/dcHRvXXtQOY

---

# Enfuse Advanced
## Description
An improved version of Darktable’s original `enfuseAdvanced` script.

**Problem:** Darktable's `image_table` does not sort input file names, causing `align_image_stack` to receive them in the wrong order.

**Solution:**  
The script now sorts the extracted file names before running the stacking command.

### Key Change
```lua
for image in images_to_align:gmatch("%S+") do
    table.insert(image_list, image)
end
table.sort(image_list)
images_to_align = table.concat(image_list, " ")
```

---

# AI Toolbox
## Description
A collection of AI-powered helpers for Darktable.

- Requires **Ollama**.  
- Can be installed via Docker or natively.

- Docker install video → https://youtu.be/dGwhvTCIbT8  
- Native install video → https://youtu.be/If6PUnd4zO0  
- Toolbox demo → https://youtu.be/bGFSdvZCsN0

---



