# iPhone Duo adoption and validation

Audit date: 20 September 2026. This record distinguishes source review, automated checks, Simulator observations, and physical-device acceptance. A build or synthetic layout test alone does not establish fold-transition behavior.

## Toolchain and baseline

- Command-local developer directory: `/Applications/Xcode-beta.app/Contents/Developer`.
- Verified Xcode 27.1, build 27A9269; `iPhoneSimulator27.1.sdk`.
- Available Duo runtime: iOS 27.1, build 24A94401. Available iPhone Duo Simulator: `62F41AE8-A352-416C-ADE9-64AEFC73F392`.
- Existing minimum deployment target is iOS 26.0. The app targets iPhone and iPad; new APIs must remain guarded individually.
- Source configuration already provides a SwiftUI scene lifecycle, an external-display scene configuration, a generated launch screen, and indirect input support. There is no `UIRequiresFullScreen` opt-out.
- iPhone supports portrait and both landscape directions; iPad additionally supports upside-down portrait. Keep these existing orientation policies.
- The app does not configure a Mac Catalyst product. The separate SwiftPM Mac companion is outside the Duo UI change.

Built-product inspection confirmed `DTXcodeBuild=27A9269`, `DTSDKName=iphonesimulator27.1`, `MinimumOSVersion=26.0`, device families `[1, 2]`, a generated `UILaunchScreen`, indirect input enabled, the existing external-display scene manifest, and the original phone/iPad orientation arrays.

## Continuity constraints from the audit

`ContentView` owns VNC and Glassy Stream session objects above a stable `NavigationSplitView`. Keep that ownership and its selected section, search text, editing requests, and presented session independent of size-class or fold branches. `SessionView` owns the zoom, keyboard draft/focus, held modifiers, and free-session timer; moving controls must not replace that view or restart its timer.

Glassy Stream currently suspends on actual scene backgrounding and retains authenticated reconnect configuration. A transient inactive phase does not suspend the transport. Retain this distinction during display changes. If the system backgrounds the app during a transition, verify recovery in the same presented session.

The external display delegate intentionally accepts only `.windowExternalDisplayNonInteractive` and updates its window using that scene's `effectiveGeometry`. Duo's inner and outer displays must not be treated as external controller-mode screens. External VNC controller mode still requires a separate-display regression check.

The QR pairing scanner uses the system's `DataScannerViewController` and offers manual code entry. It has no app-owned camera discovery or capture-direction pipeline to replace. Camera scanning across display changes requires physical hardware; Simulator can cover the unavailable-camera fallback and surrounding form layout.

## Implementation

- `SessionArrangement` is the single owner of session pane geometry. Its stable `SessionPaneLayout` places the same desktop and controls children using frames from `SessionPaneGeometry`; it does not depend on the beta native overlay arrangement choosing opposite panes. The keyboard-aware outer reader and keyboard-ignoring background reader are consumed in the same layout pass, with no cached geometry state. Global reader origins are converted to local logical coordinates before clipping the panes. A horizontal division places the desktop above the controller; a vertical division places the desktop at logical leading and the controller at logical trailing. Queries and placement share SwiftUI's RTL mirroring.
- Division frames must cross the local container and leave two positive usable panes. Off-center divisions retain unequal panes; invalid, outside, edge-only, or partial bands do not invent a second pane. Intersecting active bands remain reserved even when they cannot form a split. When several usable divisions are reported, selection favors the greatest usable area in the smaller pane, then total area, with deterministic geometry tie-breaking. Each assigned pane avoids occlusions and all other active divisions within its own bounds and cannot move to the other side. SDK frames already contain their margins.
- `ReservedRegionContainer` remains the shared protection for other fixed content. It queries active divisions and occlusions in local geometry, filters intersections, and uses `ReservedRegionGeometry` to select a clear rectangle. Session desktop and controls no longer each choose their own largest side of a division.
- While a connected local session has separated panes, `SessionView` reuses `ExternalSessionControllerView` in its folded presentation. Its bottom/trailing pane contains a trackpad and software-keyboard responder; the external-display header and “Show Here” action are omitted. The desktop itself also accepts trackpad gestures, so pointer control remains available when the native keyboard covers the separate trackpad. The main desktop does not claim hardware-keyboard focus in this mode. The controller trackpad accepts hardware input while software focus is off, subject to the timer/paywall modal gate. External-display input behavior is unchanged.
- Folded software input starts hidden on entry and reconnect. The compact toolbar has three 44-point actions: Options, Show/Hide Software Keyboard, and Close. It prefers the controller pane and falls back to the desktop pane when the visible controller cannot fit its 156×56-point padded bounds. Placement is derived from the current pane calculation without retained geometry state. Additional session actions remain in Options, and the free-session timer appears below the toolbar. A 52-point native keyboard accessory presents the existing special-key/modifier strip with the folded software keyboard; those shortcuts are not duplicated in the folded trackpad pane. The default external-display controller has no new accessory.
- Fold detection uses unobscured local divisions/occlusions from the current layout pass; each assigned frame is intersected with the current visible local rectangle. Keyboard coverage alone therefore does not remove laptop mode. The parent owns folded keyboard focus, releases held modifiers when mode changes or software focus is lost (including UIKit-driven dismissal), and preserves the ordinary input field’s focus intent through reconnects. Restoration waits until the requested flat input field is visible again, including when the device unfolds while disconnected. Native keyboard/accessory placement is system-owned: a responder in the controller pane does **not** establish that the keyboard and its accessory stay entirely within that pane.
- Pointer eligibility is implemented through native hit testing and gesture routing, without changing `UIView.isUserInteractionEnabled`. The keyboard responder and its ancestors remain enabled even when a pane is fully covered. This separates pointer eligibility from responder resignation during SwiftUI updates. Session models, zoom, selected display, drafts, and timers remain with their existing owners.
- Without a usable division, desktop and controls share the largest rectangle clear of active reserved regions and keep the ordinary overlay/input-bar behavior. The measured input-bar height is reserved in the desktop; a protected desktop's fitting measurement restores only this app-owned inset. iOS 26 and ordinary iPhone/iPad windows receive no Duo divisions and retain this path. Separate-display VNC controller mode explicitly disables laptop separation, keeps its existing controller presentation, and treats active divisions as avoidance regions instead. Narrow control groups retain zoom/display/options actions in the menu.
- The remote viewport accepts a local fitting size instead of assuming the entire window. Pan/zoom anchors survive aspect changes, temporary empty bounds, and host resolution changes. Pointer mapping uses the rendered frame. Keyboard activation still reveals the cursor once when cursor following is enabled.
- Connected/reconnecting desktop content shares one subtree to retain its viewport during transient recovery. Session models, preferences, drafts, timers, navigation, and external-display ownership remain at their existing scope.
- Onboarding, host/history grids, pairing artwork/scanner/success views, setup actions, and the external trackpad adapt to local bounds. Fixed status messages can scroll in short panes. System toolbars use semantic labeled actions.
- Deployment target, scene configuration, existing iPad navigation, RevenueCat's intentional compact paywall configuration, and the standalone Mac companion remain unchanged.

## Automated validation record

Builds use the actual `GlassyDesk` scheme, including its widget and tests, with command-local Xcode beta selection. Test results below distinguish framework/decoder failures from layout coverage. All result bundles and screenshots are task-local under `/tmp`. The dated adoption, laptop, and clamshell checks are retained as history. They predate the current holistic follow-up and are not final verification of the latest source; that follow-up has a separate record at the end.

### Initial adoption checks — 20 September 2026, historical

| Check | Evidence | Result |
| --- | --- | --- |
| App + widget + tests | Xcode 27.1 / SDK 27.1, unchanged iOS 26 target | Build-for-testing passed |
| Built app metadata | Launch screen, phone/iPad orientations, scene manifest, indirect input, minimum OS | Verified |
| Reserved-region geometry | Both division axes, camera/overlapping regions, invalid inputs, nonzero origins, tiny/full obstruction, exhaustive independent oracle | All 13 passed, including actual Duo app-test execution |
| Remote viewport and cursor | Eight aspect ratios, local keyboard fit, host resizing, cropped pointer coordinates, repeated pan/zoom transitions | Passed on Duo and iPhone/iPad 26.1 |
| SwiftUI hosting integration | Hosted arrangement, retained panes through six sizes and RTL, touch delivery through blank controls, input insets 0→72→116→0, actual desktop fitting under measured input overlay | Included in the earlier focused runs below |
| Earlier focused Duo checks | `/tmp/glassydesk-duo-viewport-final.xcresult` | All 47 tests passed on Duo / iOS 27.1, including actual active camera-region behavior |
| Earlier focused standard iPhone checks | `/tmp/glassydesk-iphone26-viewport-final.xcresult` | All 47 tests passed on iPhone 17 Pro / iOS 26.1 |
| Earlier focused iPad checks | `/tmp/glassydesk-ipad26-viewport-final.xcresult` | All 47 tests passed on iPad Pro 13-inch / iOS 26.1 |
| Duo full suite | `/tmp/glassydesk-duo-tests.xcresult`; follow-up layout bundles | Existing decoder reset failure independently reproduced on unchanged baseline; original floating-point test comparison corrected and rerun |
| Standard iPhone full regression suite | `/tmp/glassydesk-iphone26-final.xcresult` | 196 of 198 passed; both decoder failures independently reproduced on unchanged baseline |
| iPad full suite | `/tmp/glassydesk-ipad26-tests.xcresult` | 194 of 195 passed; the same decoder initial-image failure reproduced on the iPhone baseline |

The layout tests explicitly do not simulate physical fold delivery. Hosting confirms stable identity, containment and touch behavior; pure geometry confirms avoidance math. The input-inset test independently checks the native view bounds, the SwiftUI geometry size, and safe-area metadata; it does not subtract an already-consumed inset a second time. A viewport equality assertion was corrected to allow subpixel floating-point rounding and then passed.

A further integration test hosts the actual `SessionRemoteContent` and desktop renderer with a deterministic remote-session fixture. It inserts a measured input overlay from an initial zero height and checks native view identity, stable desktop scale, and stationary-cursor visibility. This reproduced an active-camera-region fitting bug on Duo (the desktop shrank when the input row appeared), which was corrected by restoring only the applied app-owned inset to the fitting measurement. This fixture does not establish transport continuity or software-keyboard animation behavior.

### Laptop-mode follow-up — 20 September 2026, historical

The laptop follow-up replaces independent pane avoidance with shared partitioning and reuses the external controller's keyboard/trackpad presentation. `SessionPaneGeometryTests` covers both axes, off-center folds, camera occlusions limited to the assigned pane, multiple candidates, local nonzero origins, RTL coordinate assumptions, tiny positive panes, and rejected invalid/partial/edge-only divisions. These are supplied geometry cases; they do not prove that a physical fold delivers matching system regions.

| Check | Evidence | Result |
| --- | --- | --- |
| Initial laptop regression run, standard iPhone | `/tmp/glassydesk-laptop-iphone26-initial.xcresult` | All 76 tests in seven suites passed on iPhone 17 Pro / iOS 26.1; includes the 16 pane-geometry tests |
| Final laptop checks, Duo | `/tmp/glassydesk-laptop-duo-verified.xcresult` | All 82 tests in eight suites passed on Duo / iOS 27.1 |
| Final laptop checks, standard iPhone | `/tmp/glassydesk-laptop-iphone26-verified.xcresult` | All 82 tests in eight suites passed on iPhone 17 Pro / iOS 26.1 |
| Final laptop checks, iPad | `/tmp/glassydesk-laptop-ipad26-verified.xcresult` | All 82 tests in eight suites passed on iPad Pro 13-inch / iOS 26.1 |
| Actual half-fold and keyboard transitions | Device Hub pose automation remains blocked | Not verified; horizontal/vertical separation, open/close continuity, and native keyboard placement need an interactive run |

The first Duo follow-up run caught the transparent controls layer intercepting desktop touches after adding a rectangular content shape. Removing that shape restored touch delivery; the corrected source passed the entire focused set on all three destinations. The controls retain visual clipping. The initial hit-test guard for a fully obscured pane was subsequently removed; see the clamshell keyboard correction below.

The final regression set also hosts the actual folded controller at 700×300, 350×180, and 150×100. It checks native trackpad bounds and hit testing, retained trackpad/responder identity, direct keyboard forwarding, and releasing modifiers when their shortcut controls disappear. Four focus-state tests cover reconnects, delayed restoration after unfolding while disconnected, cancellation, and preventing repeated focus requests. Keyboard input lifecycle tests exercise real key-window ownership and deactivate pending responders.

Zoom remains subject to the valid minimum for the current pane. A temporary keyboard-only zoom below 100% can normalize to 100% when folding fits the desktop into a new pane; this change does not add timing-based restoration of that temporary scale. Normal zoom and pan continuity have hosted regression coverage.

The final app was installed and launched on Duo. Its inner-display Hosts screen was captured at `/tmp/glassydesk-laptop-inner-current.png`. Simulator tap automation reported success without entering the saved session, and Device Hub accessibility still timed out. This is launch/host-list evidence only, not live laptop-mode verification.

Passing these runs verifies supplied pane geometry and hosted behavior on the recorded OS versions. It does not verify real Duo posture delivery, system keyboard placement within a folded display, or a live remote transport during folding.

### Existing decoder failures

An isolated checkout of unchanged commit `5879f71dc91f84b81f973812cabf66916c0f5106`, built with the same Xcode, reproduced the failures without these changes:

- Duo: `decodedImageRemainsVisibleDuringRecovery()` fails at line 80 after decoder reset. Evidence: `/tmp/glassydesk-duo-baseline-recovery-targeted.xcresult`.
- Standard iPhone / iOS 26.1: the full baseline ran 173 tests, with 171 passing and the same two failures as the final branch run: `decodedImageRemainsVisibleDuringRecovery()` at line 48 (no initial image), and `retainedImageCannotHideMissingOrInvalidRecoveryFrame(invalidIDR: false)` at line 185 (`isDisplayingVideo` false). Evidence: `/tmp/glassydesk-iphone261-baseline-full.xcresult`.
- The isolated initial-image test also passed on both baseline and branch, indicating suite/timing sensitivity. The full-suite comparison used the same iPhone Simulator sequentially. No decoder code was changed.

At this stage, the full suite was not green; no new failures remained in the tested layout, viewport, cursor, or keyboard coverage. This does not substitute for validation of later changes.

There is no dedicated UI-test target or connected-session fixture in the baseline repository. `--uitesting` disables analytics; it does not create a mock session. A home-screen smoke test cannot establish live media/input continuity.

The focused regression set can be repeated with the appropriate local destination ID:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project dejaview.xcodeproj -scheme GlassyDesk \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -parallel-testing-enabled NO \
  -only-testing:GlassyDeskTests/ReservedRegionGeometryTests \
  -only-testing:GlassyDeskTests/SessionPaneGeometryTests \
  -only-testing:GlassyDeskTests/SessionArrangementCoordinatesTests \
  -only-testing:GlassyDeskTests/SessionFoldFocusStateTests \
  -only-testing:GlassyDeskTests/RemoteClipboardInputTests \
  -only-testing:GlassyDeskTests/RemoteViewportGeometryTests \
  -only-testing:GlassyDeskTests/RemoteViewportContinuityTests \
  -only-testing:GlassyDeskTests/RemoteDesktopCursorTests \
  -only-testing:GlassyDeskTests/SessionLayoutTests test
```

## Runtime acceptance matrix

Initial smoke checks on 20 September 2026: Duo outer-display onboarding at normal and largest accessibility text sizes; standard iPhone 17 Pro / iOS 26.1 onboarding; iPad Pro 13-inch / iOS 26.1 onboarding, host grid/sidebar, Add Mac sheet, and Fast Connection setup. Captures are in `/tmp/glassydesk-duo-evidence/`. The layouts were readable, with primary actions visible and long accessibility text in the scroll area. Device Hub native accessibility repeatedly timed out, so inner/outer switching and fold poses could not be exercised at this stage. Capturing the inactive inner display returned a black image and is not validation. This initial matrix predates the later hosted checks in the user's clamshell pose; none of those earlier results establishes final runtime acceptance of the current holistic follow-up.

| Area | Scenarios | Acceptance criterion | Evidence |
| --- | --- | --- | --- |
| First launch and onboarding | Outer portrait/landscape; inner tall/wide; smallest multitasking height; largest Dynamic Type | All copy can scroll; Continue/Back/Close remain reachable; page selection survives transition | Outer portrait and largest text observed; transition/rotation checks remain |
| Hosts and history | Outer ↔ inner; horizontal and vertical fold; either side of system multitasking | Correct collapsed/expanded navigation; search, section, selection, and reading position persist | iPad grid/sidebar observed; fold and multitasking checks remain |
| Add/edit/pair Mac | Sheets on outer and inner displays, manual code/password entry, software keyboard, repeated open/close | Draft and focus survive; fields and completion/cancellation controls remain reachable | iPad Add Mac/setup observed; draft/keyboard transition checks remain |
| QR pairing | Denied/unavailable camera; physical Duo scanning while changing displays | Manual entry stays available; preview and scan delivery recover correctly | Not yet recorded; physical camera required |
| Remote desktop and fast stream | Both protocols, all aspect directions, no fold and both active fold axes | Video remains continuous; remote desktop remains usable; essential controls avoid active divisions/occlusions | Not yet recorded; live host required |
| Laptop controller | Horizontal half-fold, vertical half-fold, off-center divisions, RTL, return to flat/open/closed | Desktop is top/logical-leading; keyboard/trackpad controls are bottom/logical-trailing; panes never independently choose the same side; desktop identity and session state persist | Pure geometry and initial hosted checks passed; actual half-fold transition not verified |
| Laptop keyboard and pointer | Show/hide software keyboard in both fold axes; software/hardware typing, trackpad, modifier shortcuts; keyboard covers most/all of controller pane | Keyboard visibility does not toggle laptop mode or cause repeated focus changes; input has one owner; reachable controls use visible pane space; modifiers are released on mode/strip changes | Initial automated coverage only; native keyboard bounds and real fold/focus behavior require interactive validation |
| Session interaction continuity | Resize while zoomed/panned, pinch/drag, pointer movement, hardware keyboard, typed software-keyboard draft | Meaningful viewport anchor and selected display retained; input maps to displayed content; no stuck modifiers or accidental disconnect | Automated viewport/keyboard/pointer checks passed; live host still required |
| Session controls | Narrow side-by-side pane; short height under pinned video; expanded and collapsed controls | Timer and top actions do not overlap; Close, keyboard, display, zoom, and options remain reachable | Not yet recorded |
| Session states | Connecting, reconnecting, stopped stream, disconnected, free timer, cooldown | State messages/actions fit or scroll in short clear regions; transition does not restart limits | Not yet recorded |
| Settings and subscription | Settings, timer sheet, paywall and customer center with keyboard/large text | Dismissal and purchase/restore actions remain accessible across size changes | Not yet recorded; configured subscription UI required |
| Occlusions and safe areas | Outer camera; inner camera active/inactive; asymmetric system bars on either physical edge | Fixed controls remain clear; background can extend; no double-applied region margins | Not yet recorded |
| Localization and accessibility | RTL; long labels; accessibility Dynamic Type; VoiceOver; reduced motion/transparency; increased contrast; light/dark | Physical avoidance and semantic ordering agree; labels/order/focus and contrast remain useful | RTL hosting tests and large-text onboarding passed; physical regions/VoiceOver/appearance checks remain |
| Ordinary iPhone regression | iOS 26 phone, portrait and both landscapes, keyboard and session overlays | Existing navigation, video framing, gestures and controls remain available | Full automated run and portrait onboarding smoke check recorded above; live session/rotation checks remain |
| iPad regression | Full screen, rotation, Split View/window resizing, keyboard; both local and external-display VNC mode | Existing scene navigation and external control continue; local resizing does not become display-global | Automated run and full-screen smoke checks recorded above; multitasking/live external-display checks remain |
| Multiple app scenes | Open a second supported app window; different navigation/editor states | Presentation state remains independent; shared machines/subscriptions synchronize as intended | Not yet recorded |

## Beta and hardware limits

Apple's current [Xcode 27.1 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes) were rechecked on the audit date. They still list slow initial Simulator launch and unavailable running/debugging for most extensions in the Duo runtime. Widget build success and widget runtime validation are separate results.

The installed `simctl` help exposes display enumeration, screenshots, recording, and compatible screen geometry changes, but no documented fold/pose subcommand. Use Simulator/Device Hub's observed controls to exercise supported poses. Geometry-only tests cannot prove delivery of physical fold/camera reserved regions.

Real Duo capture, camera direction during scanning, simultaneous physical displays, and ergonomics remain hardware acceptance items. This app does not need optional hinge-angle interactions or camera-capture accessories to provide its remote-desktop functionality.

## Closed/open transition keyboard diagnostics — 20 September 2026, historical

The follow-up user log contains `Conversion error!` for a full-width, zero-height rectangle at the bottom edge, alongside `RTIInputSystemClient` invalid-session messages. Reading the Simulator's unified log identified the conversion sender as Apple's `TextInputUI` / `KeyboardTrackingCoordinator`, and the session sender as `RemoteTextInput`. The accompanying app viewport logs retain finite fitting sizes, the same remote center, and an entirely visible desktop. They do not show an app rendering failure. The user also reproduced frame skips while the app was not running, so those skips are not evidence of this app causing the Simulator transition delay.

The hardware-keyboard responder had returned an empty `UIView` from `inputView`, a behavior predating the Duo changes. Apple's [`inputView` contract](https://developer.apple.com/documentation/uikit/uiresponder/inputview) presents a supplied custom view upon first-responder activation, even though this responder handles raw [`physical key presses`](https://developer.apple.com/documentation/uikit/handling-key-presses-made-on-a-physical-keyboard) and does not adopt [`UIKeyInput`](https://developer.apple.com/documentation/uikit/uikeyinput). The patch removes that empty view and its override while retaining existing key-window focus protections, hardware event forwarding, and the real software-input field. This unnecessary keyboard surface is a plausible trigger for the zero-height conversion; the logs alone do not establish that removing it eliminates every beta input-system warning.

Three additional tests host the actual desktop view through `UIHostingController` in a real `UIWindowScene`. They check that hardware focus creates no keyboard-show notifications or viewport resize, a software text field retains focus during ordinary layouts, and a menu window prevents focus stealing and automatic focus reclamation. These tests passed before the patch as well, so they are regression coverage rather than a reproducer for the conversion error. They share the serialized layout suite to avoid concurrent tests competing for the key window.

The keyboard-patch build, before the laptop-mode follow-up, passed 55 tests in six suites on each of Duo / iOS 27.1, iPhone 17 Pro / iOS 26.1, and iPad Pro 13-inch / iOS 26.1. Bundles: `/tmp/glassydesk-duo-keyboard-final.xcresult`, `/tmp/glassydesk-iphone26-keyboard-final.xcresult`, and `/tmp/glassydesk-ipad26-keyboard-final.xcresult`. These combine the previous 47 checks, three focus tests, and five clipboard tests. The RTI invalid-session diagnostic still appeared during focus transitions; the bounded Duo test did not emit the coordinate-conversion message. No test performed a real closed/open transition, so this does not prove the reported conversion error is resolved.

Simulator pose automation remained unavailable because Device Hub's accessibility connection timed out. A repeat closed/open transition is required to confirm the exact warnings disappear; source correction and hosted focus tests are separate evidence from that runtime check.

## Reference basis

- [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), rechecked 20 September 2026.
- [Xcode 27.1 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes), rechecked 20 September 2026.
- [`GeometryProxy.reservedRegions`](https://developer.apple.com/documentation/swiftui/geometryproxy/reservedregions(kind:options:layoutdirectionbehavior:)) reports regions intersecting the queried view; [`ignoresSafeArea`](https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)) allows the measurement probe to ignore keyboard safe-area changes. The visible pane layout continues to use its normal geometry.
- [`UIKeyboardLayoutGuide`](https://developer.apple.com/documentation/uikit/uikeyboardlayoutguide) describes keyboard-occupied geometry. Neither placing a `UIKeyInput` responder in a pane nor the probe above is evidence that the system keyboard is constrained to that pane.
- The task's `iphone-duo` skill and its developer guide, including the availability, scene-lifecycle, validation, and beta-limitations sections. Public SDK declarations remain the authority for exact adopted API signatures.


## Clamshell keyboard freeze correction — 20 September 2026, historical

The follow-up user initially reported a working trackpad with no keyboard, then confirmed the app also became unresponsive. A sample of the actual frozen process, captured after the user reproduced it and before rebuilding, showed approximately 101% process CPU. The main thread repeatedly entered `UIKeyboardSceneDelegate` input-view reloads and keyboard geometry updates. The decisive stack was SwiftUI property updates → `UIView.setUserInteractionEnabled` → `RemoteSoftwareKeyboardInput.InputView.resignFirstResponder` → UIKit keyboard reload → another SwiftUI keyboard layout. Evidence: `/tmp/glassydesk-clamshell-frozen-sample.txt`.

`SessionArrangement` had disabled hit testing for the entire controls subtree when keyboard avoidance reduced its visible frame to empty. That subtree also owns the active keyboard responder. Disabling it during keyboard presentation forced resignation while UIKit was updating the keyboard, causing recursive presentation/dismissal work. The correction removes that ancestor interaction toggle and retains visual clipping. No replacement keyboard implementation or fold-angle heuristic is introduced.

The earlier focus and synthetic pane tests did not exercise a fully presented system keyboard in the active clamshell pose. A new hosted regression compares a standard `UITextField` with the real folded controller under the production arrangement, measures `keyboardLayoutGuide`, checks show notifications and stable responder identity, and asserts the responder’s ancestor views stay interaction-enabled throughout presentation. Hardware keyboard settings can intentionally suppress the onscreen keyboard, so the custom input is required to match visibility when the stock field presents one in the same run.


The corrected source passed 14 hosted layout/input tests on Duo in the actual horizontal clamshell pose (`/tmp/glassydesk-clamshell-keyboard-live.xcresult`). Both the stock field and the real folded controller produced exactly one will-show/did-show pair; the remote responder remained first responder with no disabled ancestors. The measured system keyboard occupied the complete lower half (approximately y=455.67, height=495.33, in a 669×951 window). This confirms the freeze correction, but also establishes that the native clamshell keyboard can cover the trackpad pane rather than leave trackpad space beside it.

The input/layout, focus-state, and clipboard regression sets passed 23 tests on each of standard iPhone / iOS 26.1 (`/tmp/glassydesk-clamshell-iphone26.xcresult`) and iPad / iOS 26.1 (`/tmp/glassydesk-clamshell-ipad26.xcresult`). The new keyboard-presentation check observed a visible keyboard on both. The corrected app was reinstalled and launched on Duo for a live-session check.

## Clamshell keyboard toggle — 20 September 2026, historical

The user confirmed that the corrected build presents the keyboard, but the keyboard covers the trackpad. The requested behavior is now to start with the keyboard hidden and alternate between the trackpad and native keyboard using the keyboard button.

Entering or reconnecting the folded controller starts with software focus off. Ordinary geometry updates preserve the user's explicit show/hide choice. Unfolding still restores the saved ordinary input-field focus when that field is available. The keyboard toggle, Close, and compact options live on the desktop pane, so the native keyboard cannot cover those controls. Hiding the keyboard releases held modifiers and returns hardware-keyboard ownership to the trackpad responder. External-display keyboard behavior is unchanged.

A stock 100-point keyboard accessory was investigated before this requirement changed. On this clamshell runtime it appeared above the fold, increasing keyboard occupation into the desktop pane rather than providing trackpad space in the lower pane. That historical toggle build included no accessory. The later holistic follow-up adds only the 52-point special-key accessory described below, not the abandoned accessory trackpad.

The final toggle build passed the selected 25 tests in three suites on each destination:

- Duo / iOS 27.1, in the user's actual horizontal clamshell pose: `/tmp/glassydesk-clamshell-toggle-duo-final.xcresult`.
- iPhone 17 Pro / iOS 26.1: `/tmp/glassydesk-clamshell-toggle-iphone26.xcresult`.
- iPad Pro 13-inch / iOS 26.1: `/tmp/glassydesk-clamshell-toggle-ipad26.xcresult`.

The folded-controller probe exercises hidden → shown → hidden → shown native keyboard presentation, stable responder and trackpad identity, hardware-focus handoff, and the modal hardware-input gate. A real `SessionView` fixture on the active Duo fold also verifies hidden initial focus, presentation and dismissal through the production responder callback, and keyboard bounds. Its folded-only assertions do not run without an active division. SwiftUI's button accessibility tree was unavailable to the unit-test host, so button activation is not asserted by that test. An inner-display screenshot during the real-session fixture, `/tmp/glassydesk-toggle-keyboard-proof.png`, visually confirms that the keyboard toggle, Close, and options remain above the presented keyboard. The fixture uses a deterministic session rather than a live Mac transport.

The final app was installed and launched on Duo after these checks. The host-list runtime snapshot confirms successful launch; live remote reconnection remains user-driven because Simulator tap automation does not reliably target the inner display.

## Holistic rotation and input follow-up — 20 September 2026

The user subsequently reported intermittent rotation freezes and missing top actions in landscape clamshell mode. The source changes address layout consistency and responder ownership together:

- `SessionArrangement` no longer stores the unobscured geometry in `@State`. Both current geometry readers feed one pane calculation, with explicit origin conversion for asymmetric bounds and RTL. The two child identities and the existing Boolean separation callback remain stable.
- The folded desktop remains an interactive trackpad when the software keyboard covers the separate controller pane. A compact, fixed three-action toolbar replaces the horizontally scrolling folded header; Options carries the remaining session controls.
- `RemoteDesktopView` gates pointer hit testing and gesture routing without disabling its native responder view. This removes the synchronous responder-resignation side effect previously reachable from pointer eligibility updates.
- Software responder show and hide requests both defer until after the current layout transaction. A newer show request cancels a pending hide; deactivation cancels deferred work. Changing the effective touch mode cancels delayed presses and gesture recognizers, releases any held mouse button once, and ignores the old touch sequence. Repeated unchanged mode updates preserve a drag.
- `RemoteSoftwareKeyboardInput` owns a native accessory controller hosting the existing special-key strip at 52 points. UIKit presents it with the folded keyboard; the controller updates its hosted content without reloading input views for ordinary layout updates. External-display mode keeps its previous presentation.
- Folded input remains hidden by default, and the user controls show/hide. Hardware focus is assigned to the trackpad only while software focus is off and modal input is allowed. Losing folded software focus releases held modifiers, including when UIKit dismisses the keyboard for another presentation.

New coverage includes asymmetric reader origins, RTL coordinate conversion, alternating tall/wide hosted bounds, keyboard-visible local resizing with retained input/trackpad identity, and keyboard accessory lifecycle. These checks complement the existing region avoidance, pointer, focus, and viewport tests; synthetic sizes are not physical rotation or fold-transition evidence.

| Check | Evidence | Result |
| --- | --- | --- |
| Interim Duo holistic run | `/tmp/glassydesk-duo-holistic-2.xcresult` | All 32 tests in four suites passed. This build predates subsequent focus and gesture fixes and is not final-source validation. |
| Final current-source Duo regression | `/tmp/glassydesk-duo-holistic-verified.xcresult` | All 95 tests in nine suites passed on Duo / iOS 27.1 in the active vertical-division pose, including the final accessory-width correction. |
| Final standard iPhone regression | `/tmp/glassydesk-iphone26-holistic-verified.xcresult` | All 95 tests in nine suites passed on iPhone 17 Pro / iOS 26.1. |
| Final iPad regression | `/tmp/glassydesk-ipad26-holistic-verified.xcresult` | All 95 tests in nine suites passed on iPad Pro 13-inch / iOS 26.1. |
| Repeated live rotation/fold transitions and toolbar reachability with keyboard/accessory | To be recorded after interactive validation | Pending; no final runtime claim is made for this follow-up |

The current source changes and final regression runs do not establish that every intermittent physical rotation freeze is resolved. Live transition observations are recorded separately from synthetic and hosted tests.

The first legacy regression run exposed a misleading visibility check and a real accessory-width defect. On iOS 26, `keyboardLayoutGuide` retained 52 points after dismissal even though the accessory had no window or superview, the did-hide notification frame was offscreen, and the controls returned to their complete original frame. The probe now checks the public notification frame in local coordinates and separately requires detachment and full controls restoration. Its stronger shown-state bounds assertion then found a zero-width accessory inside the full-width UIKit container. Pinning the accessory to its actual superview, with a 52-point height, fixes the width without screen assumptions or layout-callback frame writes. Attachment constraints are removed on reparenting. Targeted checks observed 402×52 on iPhone and 1032×52 on iPad, followed by the complete final runs above.

Native Xcode beta MCP built and ran the app with its debugger. A live connection to the saved “mini” machine succeeded through the existing widget connection URL. An inner-display capture (`/tmp/glassydesk-duo-mini-state.png`) confirms the landscape separated layout, visible Options/Keyboard/Close, full trackpad, and hidden keyboard. This capture precedes only the accessory-width correction; it does not establish keyboard typing or touch delivery. The final corrected source was subsequently rebuilt and launched through native Xcode MCP. Direct simulator automation targets the outer display; completion of live inner-display gestures and rotation is pending.

## Controller-pane toolbar and portrait keyboard — 20 September 2026

The user requested moving Options, Keyboard, and Close to the trackpad side and keeping the special keys with the portrait keyboard. The toolbar now prefers the controller pane. When the native keyboard leaves insufficient controller space, the same actions appear on the desktop pane. Hiding the keyboard restores them to the trackpad side. The user explicitly chose to retain the native keyboard and allow controls above the fold while typing.

The user manually placed Duo in portrait clamshell for verification. The actual scene measured 669×951 points, with a horizontal division at y=455.5…495.5. The stock native keyboard alone occupied y=455.667…951, the entire lower half. The app's 52-point accessory appeared at y=403.667…455.667, immediately above the fold. Public SDK declarations for `UIInputViewController`, `UIInputView`, responder accessories, and `UIKeyboardLayoutGuide` expose no fold-pane placement control. Apple's [input assistant item documentation](https://developer.apple.com/documentation/uikit/uitextinputassistantitem) limits those shortcut groups to iPad; Duo reports the phone idiom. Runtime comparisons with a standard text field's assistant items and a SwiftUI `.keyboard` toolbar did not produce a lower-pane shortcut row. A second SwiftUI comparison used a plain navigation stack to exclude this app's pane layout as the cause. These observations establish the behavior on this beta runtime, not a guarantee for future system versions.

Comparison evidence: `/tmp/glassydesk-duo-accessory-comparison-portrait-confirmed.xcresult`, `/tmp/glassydesk-duo-accessory-comparison-portrait-confirmed.log`, and `/tmp/glassydesk-duo-accessory-comparison-plain.log`. Temporary comparison tests were removed before final regression builds. No custom keyboard, private keyboard transforms, window overlays, or device-idiom changes were adopted.

The current source passed all 95 selected tests in nine suites on Duo / iOS 27.1 in the actual portrait clamshell pose: `/tmp/glassydesk-duo-controls-pane.xcresult`. The production `SessionView` fixture's inner-display captures confirm the lower-pane toolbar with a visible trackpad (`/tmp/glassydesk-controls-pane-trackpad.png`), reachable upper-pane actions while typing (`/tmp/glassydesk-controls-pane-keyboard.png`), and restoration after dismissal (`/tmp/glassydesk-controls-pane-trackpad-return.png`). The fixture has a deterministic black desktop and verifies layout and responder transitions, not live transport, physical touch delivery, or repeated real rotation.

The same current-source regression set passed all 95 tests in nine suites on each legacy destination: iPhone 17 Pro / iOS 26.1 (`/tmp/glassydesk-iphone26-controls-pane.xcresult`) and iPad Pro 13-inch / iOS 26.1 (`/tmp/glassydesk-ipad26-controls-pane.xcresult`).

Native Xcode beta MCP's `RunProject` rebuilt and launched the final toolbar source successfully, preserving portrait. The host-list screenshot is `/tmp/glassydesk-duo-toolbar-final-portrait.png`; the captured launch console is `/tmp/glassydesk-duo-toolbar-final-launch-console.json`. This bounded launch capture contained no AttributeGraph cycles, constraint conflicts, keyboard coordinate-conversion errors, or KeyboardTrackingCoordinator diagnostics. It is launch evidence only; no new live “mini” connection or real fold/rotation sequence was performed for this placement change.
