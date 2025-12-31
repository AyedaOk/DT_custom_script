# Darktable Lua Scripts Collection

A collection of enhanced Darktable Lua plugins, including improved focus stacking tools and AI utilities.

## Table of Contents
- SAM3 Segmentation Plugin  
- SAM2 Segmentation Plugin  
- Enfuse Simple  
- Enfuse Advanced  
- AI Toolbox  

---

# SAM3 AI Masking Plugin
## Description
A Darktable plugin that uses **Meta AI’s SAM3 image segmentation model** to generate masks directly from Darktable.

- Installation video → https://youtu.be/i08ccYK93Sg  

---

# SAM2 AI Masking Plugin
## Description
A Darktable plugin that uses **Meta AI’s SAM2 image segmentation model** to generate masks directly from Darktable.

- Installation video → https://youtu.be/eEfsPIzWtTQ  

---

# Enfuse Simple
## Description
A simplified focus stacking and HDR plugin using `enfuse` and `align_image_stack`.

- Simplier than Enfuse Advanced  
- Fully cross‑platform (Linux, macOS, Windows)
- Instalationl video → https://youtu.be/dcHRvXXtQOY

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



