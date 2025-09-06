#Enfuse Advanced 

## Description

This script is a modified version of the `enfuseAdvanced` script found in the darktable repository. The  modification fix an issue when handling input file names for focus stacking.

**Problem:** The `image_table` provided by Darktable does not sort the images by name, which means that the "align_image_stack" command will not retrieve files in alphabetical order.

**Solution:** This modification alters the `UpdateAISargs` to make is sort images by name.

## Change Log

This modification introduces the following changes to the original script:

* **Line 308:**  A local table `image_list` is initialized to store the extracted file names.
* **Lines 324-328:**
```lua
     for image in images_to_align:gmatch("%S+") do  -- %S+ captures non-whitespace sequences
        table.insert(image_list, image)
    end

    table.sort(image_list)
    images_to_align = table.concat(image_list, " ")
```
#AI Toolbox

## Description

This script is requires installing ollama as a docker container. You can wantch this video for a demonstration of what the script does --> https://youtu.be/bGFSdvZCsN0

Also, you can watch this video if you want to know how to install it --> https://youtu.be/dGwhvTCIbT8
