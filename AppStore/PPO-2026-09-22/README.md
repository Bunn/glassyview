# Glassy Desk product page optimization experiment

Submitted 22 September 2026. Verified status: **WAITING_FOR_REVIEW**. The test is not yet running.

- Experiment: Short Headlines - Dark vs Light - Sep 2026
- Experiment ID: `2ab59e38-3caf-446a-b5b3-fddd0c12ed13`
- Review submission: `3695520a-fd71-4e30-bb23-a46fbb73434a`
- Allocation: 34% original, 33% dark, 33% light.
- Localization: en-US. Changed media: iPhone (APP_IPHONE_67), 1320 × 2868 PNG.
- Six new images: first three screenshots in each treatment. Screenshots 4–5 copied byte-for-byte from the live page. Each treatment has five images.
- iPad retains the original screenshots. This is an iOS experiment, not an enforced iPhone-only audience; use iPhone results when evaluating the creative change.

## Creative hypotheses

Both treatments use shorter marketing copy and large benefit headlines: “Your Mac. In your pocket.”, “Tap. Connect. Go.”, and “Your Mac. Your way.” The dark version uses midnight navy and electric blue; the light version uses pearl white and cobalt blue. Dark/light refers to marketing artwork, not a change to the app UI theme.

The first three live screenshots were the edit references. Generated with the built-in image_gen tool, then normalized with sips to the required upload dimensions. The paired treatments were visually checked. Image generation is not pixel-preserving: minor rendering differences remain, so treat this as a creative treatment comparison rather than a pure isolated color test.

## Evaluation

Compare each treatment's conversion rate and Apple's reported confidence with the original, then compare dark and light. Original-versus-treatment changes both copy and design, so it cannot identify the independent effect of shorter text. Avoid choosing a winner from small early differences; if Apple reports the result as inconclusive, retain the original and use a simpler follow-up test. Apple tests run for at most 90 days once started.

## Files

- `preview.html`: side-by-side comparison of all five images.
- `dark/en-US/iphone/`, `light/en-US/iphone/`: upload-ready images.
- `control/`: downloaded live English assets for reference.
- `prompts.json`: exact prompts for all six generated images.
- `experiment.json`: IDs, allocation, asset hashes, and processing states.
- `receipts/`: App Store Connect creation, upload/sync, and review responses. Final asset IDs are in the sync receipts; initial upload IDs were replaced during synchronization.

All ten final uploads completed successfully. Local format validation reported zero errors and zero warnings. The two retained screenshots match the originals byte-for-byte. App Store Connect accepted the experiment for review.

[App Store Connect](https://appstoreconnect.apple.com/apps/6787767486/distribution/optimization)
[Apple: create a test](https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/create-a-test)
[Apple: run a test](https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/run-a-test)

## Applied to version 3.0

9 October 2026: the dark treatment won, so its five iPhone images replaced the original iPhone set on version 3.0 (en-US; every other locale falls back to it). The replaced set was pixel-identical to `control/APP_IPHONE_67`. iPad is unchanged. The experiment itself is still running in App Store Connect. Receipt: `receipts/v3.0-dark-applied.json`.
