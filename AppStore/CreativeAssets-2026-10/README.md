# App Store creative assets — October 2026

The product page header and the search results image for Glassy Desk, in the same dark navy look as the screenshots in `../Screenshots-2026-10`.

| File | Size | Used for |
|---|---|---|
| `en-US/header.png` | 3840 × 1646 | Product page header |
| `en-US/search-results.png` | 3840 × 2560 | Search results asset |

Uploaded to the Asset Library on 13 October 2026 and assigned to the header and search results slots of version 3.1 in all seven locales: the same header everywhere, and each locale's own search results image. They have not been submitted for review.

## Design

Both follow Apple's [asset best practices](https://developer.apple.com/app-store/asset-best-practices/).

- **Header**: one idea, the brand. The two glass panes from the app icon sit above the name. iPhone shows only the middle of a header, with the status bar and the back and share buttons over the top, so everything that matters is centered and below the top quarter. The large faint panes at the sides are decoration and may be cropped.
- **Search results**: says what the app does at a glance. One line of copy, and the Mac desktop running on an iPad and an iPhone, using the real live-session captures.

## How they were made

- `creative.py` draws both. It reuses the background, device frames, fonts, and retouching from `../Screenshots-2026-10/compose.py`, and the captures in that folder's `raw/`, so the notes in that README about the mocked Mac and the removed free-session countdown apply here too.
- `art/pane-front.png` and `art/pane-back.png` are the light-appearance layers of the app icon (`dejaview/AppIcons/AppIcon.icon/Assets/front.svg` and `back.svg`), rendered to 2048 × 2048 PNG with `NSImage`. Render them again if the icon changes.

## Languages and copy

The search results headline lives in `copy.json`, one block per App Store locale. The header has no text to translate, so it is the same image in every locale.

```sh
python3 creative.py                  # en-US
python3 creative.py --locale de-DE   # one other locale
python3 creative.py --locale all     # every locale in copy.json
```

en-US is written to `en-US/` and committed. Every other locale is written to `build/<locale>/`, which git ignores.

Sizes and formats come from `asc asset-library specs`: the header must be exactly 3840 × 1646, the search results image 3:2 between 1920 and 3840 wide, both PNG without transparency.

## Uploading

Upload an image to the Asset Library, then assign it to a slot on a version localization. Localization IDs come from `asc localizations list --app 6787767486 --version 3.1`; the image ID is in the upload's output.

```sh
asc asset-library images upload --library-id 6787767486 --file en-US/header.png
asc localizations placements create --localization-id LOCALIZATION_ID --image-id IMAGE_ID --placement-type PRODUCT_PAGE_HEADER_ASSET
asc localizations placements create --localization-id LOCALIZATION_ID --image-id IMAGE_ID --placement-type APP_STORE_SEARCH_RESULTS_ASSET
```

A slot holds one asset. To replace one, use `asc localizations placements swap` with the old placement's ID. The library lists files by name, so the localized search images were uploaded as `search-results-<locale>.png`.
