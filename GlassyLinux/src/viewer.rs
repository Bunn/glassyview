//! SDL window: renders the newest decoded picture, forwards keyboard, pointer,
//! scroll and clipboard input, and reconnects automatically after transient
//! network failures using the saved resume credential.
//!
//! The keyboard is captured only while the window is fullscreen. Windowed,
//! Super combinations stay with the compositor (Omarchy's Super+F fullscreens
//! the window); fullscreen, every key goes to the Mac except Super+F, which
//! leaves fullscreen and hands the keyboard back.

use crate::decoder::{self, Layout, PictureSlot};
use crate::keymap;
use crate::session::{self, Authenticated, ConnectRequest, Event, Sender, Session};
use crate::wire::{self, caps, Kind, Quality, ScrollDirection};
use anyhow::{anyhow, bail, Result};
use sdl2::event::{Event as SdlEvent, WindowEvent};
use sdl2::keyboard::{Keycode, Mod};
use sdl2::mouse::{MouseButton, MouseWheelDirection};
use sdl2::pixels::{Color, PixelFormatEnum};
use sdl2::rect::Rect;
use sdl2::render::Texture;
use sdl2::video::FullscreenType;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

const PING_INTERVAL: Duration = Duration::from_secs(3);
const MAXIMUM_RECONNECT_ATTEMPTS: u32 = 10;
const APP_ID: &str = "dev.bunn.glassydesk.linux";

pub struct Options {
    pub quality: Quality,
    pub prefer_hardware: bool,
    pub keymap: keymap::Options,
    pub show_local_cursor: bool,
    pub fullscreen: bool,
    pub grab_keyboard: bool,
    pub invert_scroll: bool,
    pub scroll_speed: f32,
}

enum Wake {
    Picture,
    Session(Event),
    Reconnected(Result<(Session, Authenticated)>),
}

enum Link {
    Connected(Arc<Sender>),
    Reconnecting { attempt: u32 },
}

pub fn run(
    session: Session,
    authenticated: Authenticated,
    mut options: Options,
    make_request: impl Fn(Quality) -> ConnectRequest + Send + Sync + 'static,
    mut on_authenticated: impl FnMut(&Authenticated),
    mut on_quality_change: impl FnMut(Quality),
) -> Result<()> {
    sdl2::hint::set("SDL_APP_ID", APP_ID);
    sdl2::hint::set("SDL_VIDEO_WAYLAND_WMCLASS", APP_ID);
    sdl2::hint::set("SDL_VIDEO_X11_WMCLASS", APP_ID);
    sdl2::hint::set("SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS", "0");
    sdl2::hint::set("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1");
    sdl2::hint::set("SDL_HINT_VIDEO_ALLOW_SCREENSAVER", "1");

    let sdl = sdl2::init().map_err(|e| anyhow!(e))?;
    let video = sdl.video().map_err(|e| anyhow!(e))?;
    let events = sdl.event().map_err(|e| anyhow!(e))?;
    events.register_custom_event::<Wake>().map_err(|e| anyhow!(e))?;
    let mut window = video
        .window(&format!("{} — Glassy Desk", authenticated.host_name), 1440, 900)
        .resizable()
        .allow_highdpi()
        .position_centered()
        .build()?;
    if options.fullscreen {
        let _ = window.set_fullscreen(FullscreenType::Desktop);
    }
    let mut canvas = window.into_canvas().accelerated().build()?;
    let texture_creator = canvas.texture_creator();
    let mut texture: Option<(Texture, u32, u32, Layout)> = None;
    let mouse = sdl.mouse();
    mouse.show_cursor(options.show_local_cursor);
    let clipboard = video.clipboard();
    let mut pump = sdl.event_pump().map_err(|e| anyhow!(e))?;

    let slot = Arc::new(PictureSlot::default());
    let wake_pending = Arc::new(AtomicBool::new(false));
    let make_request = Arc::new(make_request);
    let prefer_hardware = options.prefer_hardware;

    let start_session = |session: Session| -> Arc<Sender> {
        let sender = session.sender.clone();
        let (video_tx, video_rx) = mpsc::sync_channel(64);
        let picture_wake = {
            let pending = wake_pending.clone();
            let events = events.event_sender();
            move || {
                if !pending.swap(true, Ordering::AcqRel) {
                    let _ = events.push_custom_event(Wake::Picture);
                }
            }
        };
        decoder::spawn(video_rx, sender.clone(), slot.clone(), prefer_hardware, picture_wake);
        let control = events.event_sender();
        session.spawn_reader(video_tx, move |event| {
            let _ = control.push_custom_event(Wake::Session(event));
        });
        sender
    };

    let _active = crate::store::mark_active(&authenticated.host_id);
    let host_name = authenticated.host_name.clone();
    let mut capabilities = authenticated.capabilities;
    let mut link = Link::Connected(start_session(session));
    let mut status: Option<wire::HostStatus> = None;
    let mut keyboard_grabbed = false;
    let mut focused = true;
    let mut pressed_keys: HashSet<u32> = HashSet::new();
    let mut swallowed_keys: HashSet<i32> = HashSet::new();
    let mut buttons: u8 = 0;
    let mut pointer: Option<(i32, i32)> = None;
    let mut pointer_dirty = false;
    let mut scroll_accumulator = (0f32, 0f32);
    let mut destination: Option<Rect> = None;
    let mut last_ping = Instant::now();
    let mut title = String::new();
    let mut first_picture = true;

    eprintln!("glassy-desk: connected to {host_name}. Super+F toggles fullscreen (captures the keyboard). Hotkeys: Ctrl+Alt+Shift + G (fullscreen keyboard capture), F (fullscreen), V (paste clipboard), 1/2/3 (quality), C (cursor), Q (quit)");

    'main: loop {
        let sender = match &link {
            Link::Connected(sender) => Some(sender.clone()),
            Link::Reconnecting { .. } => None,
        };
        let send = |kind: Kind, payload: &[u8]| {
            if let Some(sender) = &sender {
                let _ = sender.send(kind, payload);
            }
        };

        let first = pump.wait_event_timeout(500);
        let mut new_picture = false;
        for event in first.into_iter().chain(std::iter::from_fn(|| pump.poll_event())) {
            if let Some(wake) = event.as_user_event_type::<Wake>() {
                match wake {
                    Wake::Picture => {
                        wake_pending.store(false, Ordering::Release);
                        new_picture = true;
                    }
                    Wake::Session(Event::Status(new_status)) => {
                        if let Some(message) = new_status.message() {
                            if status.and_then(|s| s.message()) != Some(message) {
                                notify(&host_name, message);
                            }
                        }
                        status = Some(new_status);
                    }
                    Wake::Session(Event::Closed(error)) => {
                        let Link::Connected(old) = &link else { continue };
                        old.close();
                        if session::is_fatal(&error) {
                            notify(&host_name, &error.to_string());
                            return Err(error);
                        }
                        eprintln!("glassy-desk: connection lost ({error:#}); reconnecting");
                        release_all(old, &mut pressed_keys, &mut buttons);
                        link = Link::Reconnecting { attempt: 1 };
                        spawn_reconnect(1, options.quality, make_request.clone(), events.event_sender());
                    }
                    Wake::Session(_) => {}
                    Wake::Reconnected(result) => {
                        let Link::Reconnecting { attempt } = link else { continue };
                        match result {
                            Ok((session, authenticated)) => {
                                eprintln!("glassy-desk: reconnected to {}", authenticated.host_name);
                                on_authenticated(&authenticated);
                                capabilities = authenticated.capabilities;
                                status = None;
                                link = Link::Connected(start_session(session));
                            }
                            Err(error) if session::is_fatal(&error) || attempt >= MAXIMUM_RECONNECT_ATTEMPTS => {
                                notify(&host_name, &format!("Disconnected: {error:#}"));
                                return Err(error);
                            }
                            Err(error) => {
                                eprintln!("glassy-desk: reconnect attempt {attempt} failed: {error:#}");
                                link = Link::Reconnecting { attempt: attempt + 1 };
                                spawn_reconnect(attempt + 1, options.quality, make_request.clone(), events.event_sender());
                            }
                        }
                    }
                }
                continue;
            }

            match event {
                SdlEvent::Quit { .. } => {
                    if let Some(sender) = &sender {
                        release_all(sender, &mut pressed_keys, &mut buttons);
                        sender.close();
                    }
                    break 'main;
                }
                SdlEvent::Window { win_event, .. } => match win_event {
                    WindowEvent::FocusGained => focused = true,
                    WindowEvent::FocusLost => {
                        focused = false;
                        if let Some(sender) = &sender {
                            release_all(sender, &mut pressed_keys, &mut buttons);
                        }
                        swallowed_keys.clear();
                        canvas.window_mut().set_keyboard_grab(false);
                        keyboard_grabbed = false;
                    }
                    WindowEvent::SizeChanged(..) | WindowEvent::Exposed => new_picture = true,
                    _ => {}
                },
                SdlEvent::KeyDown { keycode: Some(keycode), keymod, repeat, .. } => {
                    // Windowed, the compositor owns Super+F and fullscreens the
                    // window. Captured, it reaches us and leaves fullscreen.
                    if keycode == Keycode::F && keymod.intersects(Mod::LGUIMOD | Mod::RGUIMOD) && keyboard_grabbed {
                        swallowed_keys.insert(keycode.into_i32());
                        if !repeat {
                            if let Some(sender) = &sender {
                                release_all(sender, &mut pressed_keys, &mut buttons);
                            }
                            let _ = canvas.window_mut().set_fullscreen(FullscreenType::Off);
                        }
                        continue;
                    }
                    let hotkey_modifiers = keymod.intersects(Mod::LCTRLMOD | Mod::RCTRLMOD)
                        && keymod.intersects(Mod::LALTMOD | Mod::RALTMOD)
                        && keymod.intersects(Mod::LSHIFTMOD | Mod::RSHIFTMOD);
                    if hotkey_modifiers && is_hotkey(keycode) {
                        swallowed_keys.insert(keycode.into_i32());
                        if repeat {
                            continue;
                        }
                        match keycode {
                            Keycode::G => options.grab_keyboard = !options.grab_keyboard,
                            Keycode::F => {
                                let window = canvas.window_mut();
                                let next = if window.fullscreen_state() == FullscreenType::Off {
                                    FullscreenType::Desktop
                                } else {
                                    FullscreenType::Off
                                };
                                let _ = window.set_fullscreen(next);
                            }
                            Keycode::C => {
                                options.show_local_cursor = !options.show_local_cursor;
                                mouse.show_cursor(options.show_local_cursor);
                            }
                            Keycode::V => {
                                if capabilities & caps::CLIPBOARD_PASTE == 0 {
                                    notify(&host_name, "This version of Glassy Desk for Mac does not support clipboard paste.");
                                } else if let Ok(text) = clipboard.clipboard_text() {
                                    if !text.is_empty() && text.len() <= wire::MAXIMUM_CLIPBOARD_TEXT_LENGTH {
                                        if let Some(sender) = &sender {
                                            release_all(sender, &mut pressed_keys, &mut buttons);
                                        }
                                        send(Kind::ClipboardPaste, text.as_bytes());
                                    }
                                }
                            }
                            Keycode::NUM_1 | Keycode::NUM_2 | Keycode::NUM_3 => {
                                options.quality = match keycode {
                                    Keycode::NUM_1 => Quality::DataSaver,
                                    Keycode::NUM_2 => Quality::Balanced,
                                    _ => Quality::Best,
                                };
                                if capabilities & caps::STREAM_QUALITY_CONTROL != 0 {
                                    send(Kind::StreamQualityRequest, &wire::encode_stream_quality_request(options.quality));
                                }
                                on_quality_change(options.quality);
                                notify(&host_name, &format!("Quality: {}", options.quality.label()));
                            }
                            Keycode::Q => {
                                if let Some(sender) = &sender {
                                    release_all(sender, &mut pressed_keys, &mut buttons);
                                    sender.close();
                                }
                                break 'main;
                            }
                            _ => {}
                        }
                        continue;
                    }
                    if let Some(keysym) = keymap::keysym(keycode, options.keymap) {
                        pressed_keys.insert(keysym);
                        send(Kind::KeyInput, &wire::encode_key_input(keysym, true));
                    }
                }
                SdlEvent::KeyUp { keycode: Some(keycode), .. } => {
                    if swallowed_keys.remove(&keycode.into_i32()) {
                        continue;
                    }
                    if let Some(keysym) = keymap::keysym(keycode, options.keymap) {
                        if pressed_keys.remove(&keysym) {
                            send(Kind::KeyInput, &wire::encode_key_input(keysym, false));
                        }
                    }
                }
                SdlEvent::MouseMotion { x, y, .. } => {
                    pointer = Some((x, y));
                    pointer_dirty = true;
                }
                SdlEvent::MouseButtonDown { mouse_btn, x, y, .. } | SdlEvent::MouseButtonUp { mouse_btn, x, y, .. } => {
                    let bit = match mouse_btn {
                        MouseButton::Left => wire::BUTTON_LEFT,
                        MouseButton::Right => wire::BUTTON_RIGHT,
                        _ => continue,
                    };
                    let down = matches!(event, SdlEvent::MouseButtonDown { .. });
                    buttons = if down { buttons | bit } else { buttons & !bit };
                    pointer = Some((x, y));
                    if let Some(normalized) = normalize(pointer, destination, &canvas) {
                        send(Kind::PointerInput, &wire::encode_pointer_input(normalized.0, normalized.1, buttons));
                        pointer_dirty = false;
                    }
                }
                SdlEvent::MouseWheel { precise_x, precise_y, direction, .. } => {
                    let flip = if (direction == MouseWheelDirection::Flipped) != options.invert_scroll { -1.0 } else { 1.0 };
                    scroll_accumulator.0 += precise_x * flip * options.scroll_speed;
                    scroll_accumulator.1 += precise_y * flip * options.scroll_speed;
                    let vertical = scroll_accumulator.1.trunc();
                    if vertical != 0.0 {
                        scroll_accumulator.1 -= vertical;
                        let direction = if vertical > 0.0 { ScrollDirection::Up } else { ScrollDirection::Down };
                        send(Kind::ScrollInput, &wire::encode_scroll_input(direction, vertical.abs().min(64.0) as u16));
                    }
                    let horizontal = scroll_accumulator.0.trunc();
                    if horizontal != 0.0 {
                        scroll_accumulator.0 -= horizontal;
                        let direction = if horizontal > 0.0 { ScrollDirection::Right } else { ScrollDirection::Left };
                        send(Kind::ScrollInput, &wire::encode_scroll_input(direction, horizontal.abs().min(64.0) as u16));
                    }
                }
                _ => {}
            }
        }

        if pointer_dirty && focused {
            if let Some(normalized) = normalize(pointer, destination, &canvas) {
                send(Kind::PointerInput, &wire::encode_pointer_input(normalized.0, normalized.1, buttons));
            }
            pointer_dirty = false;
        }

        if let Some(sender) = &sender {
            if last_ping.elapsed() >= PING_INTERVAL {
                let _ = sender.send(Kind::Ping, &[]);
                last_ping = Instant::now();
            }
        }

        if let Some(picture) = slot.take() {
            let (width, height, layout) = (picture.width(), picture.height(), picture.layout());
            if texture.as_ref().map(|(_, w, h, l)| (*w, *h, *l)) != Some((width, height, layout)) {
                let format = match layout {
                    Layout::Nv12 => PixelFormatEnum::NV12,
                    Layout::I420 => PixelFormatEnum::IYUV,
                };
                texture = Some((texture_creator.create_texture_streaming(format, width, height)?, width, height, layout));
            }
            if first_picture {
                first_picture = false;
                let decoder = if slot.hardware.load(Ordering::Relaxed) { "VA-API" } else { "software" };
                eprintln!("glassy-desk: streaming {width}×{height} ({decoder} decoding)");
            }
            let (texture, ..) = texture.as_mut().unwrap();
            upload(texture, &picture, height)?;
            new_picture = true;
        }

        if new_picture {
            canvas.set_draw_color(Color::RGB(0, 0, 0));
            canvas.clear();
            if let Some((texture, width, height, _)) = &texture {
                let (output_width, output_height) = canvas.output_size().map_err(|e| anyhow!(e))?;
                let rect = aspect_fit(*width, *height, output_width, output_height);
                canvas.copy(texture, None, rect).map_err(|e| anyhow!(e))?;
                destination = Some(rect);
            }
            canvas.present();
        }

        // Fullscreen can change underneath us (the compositor's Super+F), so
        // follow the window state rather than our own requests.
        let fullscreen = canvas.window().fullscreen_state() != FullscreenType::Off;
        let capture = focused && fullscreen && options.grab_keyboard;
        if capture != keyboard_grabbed {
            if let Some(sender) = &sender {
                release_all(sender, &mut pressed_keys, &mut buttons);
            }
            canvas.window_mut().set_keyboard_grab(capture);
            keyboard_grabbed = capture;
        }

        let next_title = window_title(&host_name, &link, status, keyboard_grabbed);
        if next_title != title {
            let _ = canvas.window_mut().set_title(&next_title);
            title = next_title;
        }
    }
    Ok(())
}

fn is_hotkey(keycode: Keycode) -> bool {
    matches!(
        keycode,
        Keycode::G | Keycode::F | Keycode::C | Keycode::V | Keycode::Q | Keycode::NUM_1 | Keycode::NUM_2 | Keycode::NUM_3
    )
}

fn window_title(host: &str, link: &Link, status: Option<wire::HostStatus>, grabbed: bool) -> String {
    let mut title = format!("{host} — Glassy Desk");
    match link {
        Link::Reconnecting { attempt } => title.push_str(&format!(" · Reconnecting (attempt {attempt})…")),
        Link::Connected(_) => {
            if let Some(message) = status.and_then(|s| s.message()) {
                title.push_str(" · ");
                title.push_str(message);
            } else if grabbed {
                title.push_str(" · Keyboard captured (Super+F exits fullscreen)");
            }
        }
    }
    title
}

fn spawn_reconnect(
    attempt: u32,
    quality: Quality,
    make_request: Arc<impl Fn(Quality) -> ConnectRequest + Send + Sync + 'static>,
    events: sdl2::event::EventSender,
) {
    thread::spawn(move || {
        let delay = Duration::from_millis(500 * 2u64.pow((attempt - 1).min(4)));
        thread::sleep(delay);
        let result = session::connect(make_request(quality));
        let _ = events.push_custom_event(Wake::Reconnected(result));
    });
}

/// Releases held keys and buttons so the Mac never keeps a stuck modifier.
fn release_all(sender: &Sender, pressed_keys: &mut HashSet<u32>, buttons: &mut u8) {
    for keysym in pressed_keys.drain() {
        let _ = sender.send(Kind::KeyInput, &wire::encode_key_input(keysym, false));
    }
    *buttons = 0;
}

fn aspect_fit(width: u32, height: u32, output_width: u32, output_height: u32) -> Rect {
    let scale = (output_width as f64 / width as f64).min(output_height as f64 / height as f64);
    let w = ((width as f64 * scale).round() as u32).max(1);
    let h = ((height as f64 * scale).round() as u32).max(1);
    Rect::new(((output_width - w.min(output_width)) / 2) as i32, ((output_height - h.min(output_height)) / 2) as i32, w, h)
}

/// Maps window coordinates to the host's 0…65535 normalized display space.
fn normalize(
    pointer: Option<(i32, i32)>,
    destination: Option<Rect>,
    canvas: &sdl2::render::WindowCanvas,
) -> Option<(u16, u16)> {
    let (x, y) = pointer?;
    let rect = destination?;
    let (window_width, window_height) = canvas.window().size();
    let (output_width, output_height) = canvas.output_size().ok()?;
    let scale_x = output_width as f64 / window_width.max(1) as f64;
    let scale_y = output_height as f64 / window_height.max(1) as f64;
    let px = (x as f64 * scale_x - rect.x() as f64) / rect.width() as f64;
    let py = (y as f64 * scale_y - rect.y() as f64) / rect.height() as f64;
    Some(((px.clamp(0.0, 1.0) * 65535.0).round() as u16, (py.clamp(0.0, 1.0) * 65535.0).round() as u16))
}

fn upload(texture: &mut Texture, picture: &decoder::Picture, height: u32) -> Result<()> {
    let height = height as usize;
    match picture.layout() {
        Layout::Nv12 => {
            let (y, y_pitch) = picture.plane(0);
            let (uv, uv_pitch) = picture.plane(1);
            let status = unsafe { sdl2::sys::SDL_UpdateNVTexture(texture.raw(), std::ptr::null(), y, y_pitch, uv, uv_pitch) };
            if status != 0 {
                bail!("SDL_UpdateNVTexture failed: {}", sdl2::get_error());
            }
        }
        Layout::I420 => {
            let chroma_height = height.div_ceil(2);
            let plane = |index: usize, rows: usize| {
                let (data, pitch) = picture.plane(index);
                (unsafe { std::slice::from_raw_parts(data, pitch as usize * rows) }, pitch as usize)
            };
            let (y, y_pitch) = plane(0, height);
            let (u, u_pitch) = plane(1, chroma_height);
            let (v, v_pitch) = plane(2, chroma_height);
            texture.update_yuv(None, y, y_pitch, u, u_pitch, v, v_pitch)?;
        }
    }
    Ok(())
}

/// Desktop notification through mako/any notification daemon, when available.
pub fn notify(host: &str, message: &str) {
    eprintln!("glassy-desk: {message}");
    let _ = std::process::Command::new("notify-send")
        .args(["--app-name=Glassy Desk", "--icon=video-display", &format!("Glassy Desk · {host}"), message])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}
