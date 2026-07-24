# WWDC 2026 Feature Ideas

Validated against Apple WWDC 2026 session coverage, current developer documentation, and the local `$wwdc` skill notes. The most valuable direction for Glassy Desk is to make saved remote sessions faster to launch, easier to discover from system surfaces, and more adaptive across modern Apple device contexts.

## 1. Siri and Shortcuts: Connect to My Mac

Expose saved machines through App Intents so users can run phrases such as "Connect to my Mac" from Siri, Shortcuts, Spotlight, and system suggestions. This should start with a narrow intent that opens Glassy Desk and hands off to the existing saved-machine connection flow.

Value: Reduces the core task to one voice or shortcut action without duplicating VNC session logic.

## 2. Screen-Aware AI Command Mode

Add an optional assistive command mode that can understand the current remote-screen context and help users perform common actions. Keep it bounded to explicit user requests and clear privacy controls.

Value: Turns a remote desktop from a pure pixel stream into an easier-to-operate workspace.

## 3. Semantic Search Across Machines and History

Use richer indexing for saved machines, aliases, recent hosts, and connection notes so users can search by intent rather than exact hostnames.

Value: Helps people with multiple Macs, lab machines, servers, and changing hostnames reconnect quickly.

## 4. Live Activity for Active Sessions

Surface active connection state, elapsed time, host name, and disconnect controls through Live Activities where available.

Value: Gives users persistent awareness of a remote session without reopening the app.

## 5. Accessibility-First Remote Control Mode

Add a control mode optimized for Switch Control, VoiceOver, larger hit targets, keyboard traversal, and explicit pointer actions.

Value: Remote desktop apps are often hard to use with assistive input; this would make core control paths more reliable.

## 6. Adaptive Liquid Glass Control Polish

Continue refining connection tiles, session controls, menus, and overlays for Liquid Glass while preserving contrast over remote-screen content.

Value: Keeps the app feeling native on current Apple platforms without making controls harder to read.

## 7. iPhone Mirroring and Resizable iPad Readiness

Audit layouts, pointer interactions, keyboard handling, and compact-width behavior for mirrored iPhone use and highly resizable iPad windows.

Value: Remote control should remain predictable when the app is used in smaller, reflected, or windowed contexts.

## 8. SwiftData-Backed Machines and Connection History

Move saved-machine metadata and recent-connection history to a model layer that is easier to query, migrate, and potentially sync.

Value: Creates a stronger foundation for search, shortcuts, recents, and future user-facing organization.

## 9. Performance Telemetry for VNC Rendering

Add lightweight instrumentation around connection setup, frame decode, render latency, and input latency.

Value: Makes performance regressions measurable and helps prioritize rendering improvements.
