# Picture in Picture

During a session, choose **Session Options → Picture in Picture**, or leave Glassy Desk while a session is on screen, to keep watching the Mac in a floating system window. The window is view-only: keyboard, pointer, and clipboard input resume when you return to Glassy Desk. Returning to the app closes the window and shows the session full size. Turn off **Settings → Sessions → Picture in Picture When Leaving** to start it only from the menu. iOS's own **Start PiP Automatically** setting also applies.

Both connection types are supported. Picture in Picture is unavailable on devices and simulators where `AVPictureInPictureController.isPictureInPictureSupported()` is false; the menu item and setting are hidden there.

## Content sources

- **Fast Connection** registers the existing `AVSampleBufferDisplayLayer` that hardware-decodes the H.264 stream. Nothing is decoded twice, and the host's adaptive bitrate continues to apply.
- **Standard VNC** has no video stream, so the session view keeps a covered `AVSampleBufferDisplayLayer` exactly beneath its framebuffer view. `FramebufferPictureInPictureFeeder` copies the visible display into BGRA sample buffers no larger than 1280 pixels on the long edge, marked display-immediately. It sends about one frame per second while the session is on screen, so the layer is ready for the start animation, and up to fifteen per second while the window is open. Only one conversion runs at a time; newer frames are dropped rather than queued.

Only the primary session view registers a source. External-display mirrors and controller previews do not. Removing the session view, disconnecting, or closing the session unregisters the layer and closes the window.

## Staying connected in the background

AVKit offers Picture in Picture only to apps with the **Audio, AirPlay, and Picture in Picture** background mode (`UIBackgroundModes` = `audio`) and a `.playback` audio session. Glassy Desk plays no sound; it activates the session with `.mixWithOthers` so music and calls are never interrupted, and deactivates it when the session view goes away.

Fast Connection normally retires its transport when the app backgrounds and resumes on return. While the window is active, or for one second after backgrounding when an automatic start is expected, `ContentView` keeps the transport open. A background task covers that grace period. If the window does not open, or the person closes it while Glassy Desk stays in the background, the usual suspension runs immediately. Standard VNC keeps its existing lifecycle.

The free-session timer continues while the window is open. When it ends, the session disconnects and the window closes.

## Verification

`PictureInPictureTests` cover frame throttling, scaling to even dimensions, display-immediately attachments, pool reuse, display cropping, the live time range, preference persistence, unsupported devices, and registration of the VNC mirror or Fast Connection layer as the session view enters and leaves a window. Simulators cannot show Picture in Picture.

Before release, verify on a physical iPhone and iPad:

1. With Fast Connection, start the window from the menu, switch apps, and confirm the desktop keeps updating. Return through the window's restore button and through the app icon.
2. Swipe home during a session with the setting on, then off. Confirm the window opens only when enabled and that the session resumes normally when it does not.
3. Close the window while Glassy Desk is in the background, wait a minute, and return. Confirm the session reconnects.
4. Repeat steps 1–2 with Standard VNC, including a multi-display Mac with one display selected.
5. Play music in another app first and confirm Glassy Desk never interrupts it.
