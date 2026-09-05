# Glassy Desk for Mac icon

`GlassyDeskAppIcon.png` is the 1024 × 1024 production source, with transparency outside the blue tile. `GlassyDeskAppIcon.icns` contains the standard 16–512 point representations at 1× and 2×. Both the development and release bundles use this icon.

The design uses one centered monitor silhouette, generous empty space, and a restrained blue glass finish. Wireless arcs, perspective tilt, detailed wallpaper, and bright reflections were removed to improve recognition in the Dock. The result was visually checked at 32 and 64 pixels.

Generated with the built-in image generation tool, using the previous Mac icon as the edit target and the iOS light icon as a palette reference. Native `sips` resizing and `iconutil` packaging produced the final resources.

Design prompt:

> Redesign the macOS app icon for Glassy Desk to be dramatically simpler and recognizable at 32 and 64 pixels. Use one bold, centered, straight-on desktop monitor: a softly frosted white/cyan screen outline and a short simple pedestal. Use a calm blue rounded-square tile, a quiet blue screen, restrained depth, and generous negative space. Remove wireless arcs, rays, lens flares, extra panels, text, badges, perspective tilt, detailed reflections, multiple borders, and neon glow. Produce one finished app icon with transparent corners.

Final background extraction prompt:

> Change only the background outside the rounded blue icon tile: remove the painted gray-and-white checkerboard completely and produce an actual transparent PNG with an alpha channel. Preserve the blue square and centered white monitor, including their colors, scale, shape, and position. Keep rounded edges antialiased and corners transparent, without a checkerboard or matte.
