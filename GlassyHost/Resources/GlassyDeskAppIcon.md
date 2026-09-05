# Glassy Desk for Mac icon

The production source is [`GlassyDeskAppIcon.icon`](GlassyDeskAppIcon.icon): an Icon Composer document containing one opaque, unmasked 1024 × 1024 PNG. The centered white monitor and blue palette carry over from the previous icon. The artwork extends to every canvas edge so macOS can apply its own mask and presentation.

Apple's [app icon guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons) call for square, unmasked layers and an opaque background that fills the canvas. The previous pre-rounded PNG and standalone ICNS could receive an additional compatibility plate in the macOS 26 Dock, producing the white border reported in version 0.2.7.

## Build and compatibility

Both `script/build_and_run.sh` and `script/package_host_release.sh` run [`script/compile_host_icon.sh`](../../script/compile_host_icon.sh) before signing. The helper uses the selected Xcode 26+ `actool` to compile the `.icon` document into:

- `Assets.car`, containing the macOS 26 icon stack and flattened compatibility representations.
- `GlassyDeskAppIcon.icns`, the compiler-generated fallback also used for the DMG volume icon.

`CFBundleIconName` and `CFBundleIconFile` both name `GlassyDeskAppIcon`. The helper checks those values against the compiler's generated metadata and requires both compiled resources. Keep fallback generation enabled for macOS 14 and 15. The PNG, document, and build scripts are committed; compiled resources are regenerated for each bundle.

Apple describes the document and app-icon configuration in [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) and [Configuring your app icon](https://developer.apple.com/documentation/xcode/configuring-your-app-icon). The document can be maintained as source and compiled from the command line; release setup does not depend on opening the Icon Composer GUI.

To inspect an assembled bundle, check its icon metadata and catalog, then launch a local preview and examine the actual Dock icon:

```sh
./script/build_and_run.sh --preview
plutil -p 'dist/Glassy Desk.app/Contents/Info.plist'
xcrun assetutil --info 'dist/Glassy Desk.app/Contents/Resources/Assets.car'
```

## Artwork provenance

Edited with the built-in image generation tool using the prior Mac PNG as the target, then resized to 1024 × 1024 with native `sips`. The master is fully opaque. The document disables extra layer glass, shadows, and specular effects to preserve the monitor artwork while the system supplies the outer shape.

Edit prompt:

> Edit the Glassy Desk macOS app icon source. Produce a square production app icon master. Change only the outer blue background: extend its existing calm blue gradient seamlessly to all four straight canvas edges and all four corners so the image is completely opaque and full-bleed. Remove the pre-rounded tile boundary, the outer rim/bevel/glow, the transparent padding and stray cyan alpha pixels outside the tile. Preserve the single centered white/frosted desktop monitor and pedestal, their position, scale, silhouette, screen colors, and blue palette. The whole canvas must be solid blue-gradient artwork. No border, outer drop shadow, rounded corners, transparency, white/gray matte, or checkerboard. This is an unmasked app icon input that Apple's compiler will mask. Do not redesign the monitor or add symbols, text, badges, or decorations.
