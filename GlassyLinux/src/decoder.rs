//! H.264 decoding with libavcodec. Uses VA-API when available (Intel/AMD on
//! Omarchy) and falls back to software decoding. Runs on its own thread,
//! publishes only the newest decoded picture, and acknowledges handled video
//! to the host so its receiver-credit window keeps advancing.

use crate::session::{Event, Sender};
use crate::wire::{self, Kind};
use ffmpeg_sys_next as ff;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const FEEDBACK_COALESCING: Duration = Duration::from_millis(30);
const START_CODE: [u8; 4] = [0, 0, 0, 1];
const AVERROR_EAGAIN: i32 = -(libc::EAGAIN);

/// A decoded picture in system memory (NV12 or planar I420), owned until it is
/// uploaded by the render thread.
pub struct Picture {
    frame: *mut ff::AVFrame,
}

// The frame is exclusively owned and only accessed by one thread at a time.
unsafe impl Send for Picture {}

impl Drop for Picture {
    fn drop(&mut self) {
        unsafe { ff::av_frame_free(&mut self.frame) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    Nv12,
    I420,
}

impl Picture {
    pub fn width(&self) -> u32 {
        unsafe { (*self.frame).width as u32 }
    }
    pub fn height(&self) -> u32 {
        unsafe { (*self.frame).height as u32 }
    }
    pub fn layout(&self) -> Layout {
        let format = unsafe { (*self.frame).format };
        if format == ff::AVPixelFormat::AV_PIX_FMT_NV12 as i32 {
            Layout::Nv12
        } else {
            Layout::I420
        }
    }
    /// (data pointer, line size) for plane `index`.
    pub fn plane(&self, index: usize) -> (*const u8, i32) {
        unsafe { ((*self.frame).data[index] as *const u8, (*self.frame).linesize[index]) }
    }
}

/// Newest-picture mailbox shared with the renderer.
#[derive(Default)]
pub struct PictureSlot {
    picture: Mutex<Option<Picture>>,
    pub decoded_frames: AtomicU64,
    pub hardware: AtomicBool,
}

impl PictureSlot {
    pub fn take(&self) -> Option<Picture> {
        self.picture.lock().unwrap().take()
    }
    fn put(&self, picture: Picture) {
        *self.picture.lock().unwrap() = Some(picture);
        self.decoded_frames.fetch_add(1, Ordering::Relaxed);
    }
}

struct Decoder {
    context: *mut ff::AVCodecContext,
    packet: *mut ff::AVPacket,
    frame: *mut ff::AVFrame,
    hardware: bool,
}

unsafe extern "C" fn select_vaapi(
    _context: *mut ff::AVCodecContext,
    mut formats: *const ff::AVPixelFormat,
) -> ff::AVPixelFormat {
    let first = *formats;
    while *formats != ff::AVPixelFormat::AV_PIX_FMT_NONE {
        if *formats == ff::AVPixelFormat::AV_PIX_FMT_VAAPI {
            return ff::AVPixelFormat::AV_PIX_FMT_VAAPI;
        }
        formats = formats.add(1);
    }
    first
}

impl Decoder {
    fn new(prefer_hardware: bool) -> Result<Decoder, String> {
        unsafe {
            ff::av_log_set_level(ff::AV_LOG_ERROR as i32);
            let codec = ff::avcodec_find_decoder(ff::AVCodecID::AV_CODEC_ID_H264);
            if codec.is_null() {
                return Err("FFmpeg has no H.264 decoder".into());
            }
            let context = ff::avcodec_alloc_context3(codec);
            (*context).flags |= ff::AV_CODEC_FLAG_LOW_DELAY as i32;
            let mut hardware = false;
            if prefer_hardware {
                let mut device: *mut ff::AVBufferRef = ptr::null_mut();
                let status = ff::av_hwdevice_ctx_create(
                    &mut device,
                    ff::AVHWDeviceType::AV_HWDEVICE_TYPE_VAAPI,
                    ptr::null(),
                    ptr::null_mut(),
                    0,
                );
                if status >= 0 {
                    (*context).hw_device_ctx = ff::av_buffer_ref(device);
                    (*context).get_format = Some(select_vaapi);
                    ff::av_buffer_unref(&mut device);
                    hardware = true;
                } else {
                    eprintln!("glassy-desk: VA-API unavailable ({status}); using software decoding");
                }
            }
            if !hardware {
                // Slice threads add no latency; frame threads would delay output.
                (*context).thread_type = ff::FF_THREAD_SLICE as i32;
                (*context).thread_count = 0;
            }
            let status = ff::avcodec_open2(context, codec, ptr::null_mut());
            if status < 0 {
                let mut context = context;
                ff::avcodec_free_context(&mut context);
                return Err(format!("could not open the H.264 decoder ({status})"));
            }
            Ok(Decoder { context, packet: ff::av_packet_alloc(), frame: ff::av_frame_alloc(), hardware })
        }
    }

    /// Decodes one Annex B access unit; returns the newest resulting picture.
    fn decode(&mut self, annex_b: &[u8]) -> Result<Option<Picture>, i32> {
        unsafe {
            let status = ff::av_new_packet(self.packet, annex_b.len() as i32);
            if status < 0 {
                return Err(status);
            }
            ptr::copy_nonoverlapping(annex_b.as_ptr(), (*self.packet).data, annex_b.len());
            let status = ff::avcodec_send_packet(self.context, self.packet);
            ff::av_packet_unref(self.packet);
            if status < 0 && status != AVERROR_EAGAIN {
                return Err(status);
            }
            let mut newest = None;
            loop {
                let status = ff::avcodec_receive_frame(self.context, self.frame);
                if status == AVERROR_EAGAIN || status == ff::AVERROR_EOF {
                    break;
                }
                if status < 0 {
                    return Err(status);
                }
                let output = ff::av_frame_alloc();
                if (*self.frame).format == ff::AVPixelFormat::AV_PIX_FMT_VAAPI as i32 {
                    let status = ff::av_hwframe_transfer_data(output, self.frame, 0);
                    ff::av_frame_unref(self.frame);
                    if status < 0 {
                        let mut output = output;
                        ff::av_frame_free(&mut output);
                        return Err(status);
                    }
                } else {
                    ff::av_frame_move_ref(output, self.frame);
                }
                let format = (*output).format;
                let supported = [
                    ff::AVPixelFormat::AV_PIX_FMT_NV12 as i32,
                    ff::AVPixelFormat::AV_PIX_FMT_YUV420P as i32,
                    ff::AVPixelFormat::AV_PIX_FMT_YUVJ420P as i32,
                ];
                if !supported.contains(&format) {
                    let mut output = output;
                    ff::av_frame_free(&mut output);
                    eprintln!("glassy-desk: unsupported decoded pixel format {format}");
                    return Err(-1);
                }
                newest = Some(Picture { frame: output });
            }
            Ok(newest)
        }
    }

    fn flush(&mut self) {
        unsafe { ff::avcodec_flush_buffers(self.context) }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe {
            ff::av_frame_free(&mut self.frame);
            ff::av_packet_free(&mut self.packet);
            ff::avcodec_free_context(&mut self.context);
        }
    }
}

/// Converts AVCC length-prefixed NAL units to Annex B start-code format.
fn append_annex_b(avcc: &[u8], nal_length_size: usize, out: &mut Vec<u8>) -> bool {
    let mut offset = 0;
    while offset < avcc.len() {
        if avcc.len() - offset < nal_length_size {
            return false;
        }
        let length = avcc[offset..offset + nal_length_size].iter().fold(0usize, |acc, b| (acc << 8) | *b as usize);
        offset += nal_length_size;
        if length == 0 || avcc.len() - offset < length {
            return false;
        }
        out.extend_from_slice(&START_CODE);
        out.extend_from_slice(&avcc[offset..offset + length]);
        offset += length;
    }
    true
}

struct Feedback {
    sender: Arc<Sender>,
    enabled: bool,
    handled_sequence: u64,
    pending_age_ms: u32,
    pending: bool,
    last_sent: Instant,
}

impl Feedback {
    fn record(&mut self, sequence: u64, age: Duration) {
        if !self.enabled {
            return;
        }
        self.handled_sequence = self.handled_sequence.max(sequence);
        self.pending_age_ms = self.pending_age_ms.max(age.as_millis().min(60_000) as u32);
        self.pending = true;
        if self.last_sent.elapsed() >= FEEDBACK_COALESCING {
            self.flush();
        }
    }

    fn deadline(&self) -> Option<Instant> {
        self.pending.then(|| self.last_sent + FEEDBACK_COALESCING)
    }

    fn flush(&mut self) {
        if !self.pending {
            return;
        }
        let payload = wire::encode_stream_feedback(self.handled_sequence, self.pending_age_ms);
        let _ = self.sender.send(Kind::StreamFeedback, &payload);
        self.pending = false;
        self.pending_age_ms = 0;
        self.last_sent = Instant::now();
    }
}

pub fn spawn(
    video: Receiver<Event>,
    sender: Arc<Sender>,
    slot: Arc<PictureSlot>,
    prefer_hardware: bool,
    wake: impl Fn() + Send + 'static,
) -> thread::JoinHandle<()> {
    thread::Builder::new()
        .name("glassy-decode".into())
        .spawn(move || {
            let mut decoder = match Decoder::new(prefer_hardware) {
                Ok(decoder) => decoder,
                Err(message) => {
                    eprintln!("glassy-desk: {message}");
                    sender.close();
                    return;
                }
            };
            slot.hardware.store(decoder.hardware, Ordering::Relaxed);
            let mut feedback = Feedback {
                enabled: sender.supports(wire::caps::ADAPTIVE_STREAM),
                sender: sender.clone(),
                handled_sequence: 0,
                pending_age_ms: 0,
                pending: false,
                last_sent: Instant::now(),
            };
            let mut parameter_sets: Vec<u8> = Vec::new();
            let mut nal_length_size = 4;
            let mut needs_parameter_sets = true;
            let mut waiting_for_key_frame = true;
            let mut hardware_failures = 0u32;
            let mut annex_b = Vec::with_capacity(512 * 1024);

            loop {
                let received = match feedback.deadline() {
                    Some(deadline) => video.recv_timeout(deadline.saturating_duration_since(Instant::now())),
                    None => video.recv().map_err(|_| RecvTimeoutError::Disconnected),
                };
                match received {
                    Ok(Event::VideoConfiguration(configuration)) => {
                        let mut sets = Vec::new();
                        for set in &configuration.parameter_sets {
                            sets.extend_from_slice(&START_CODE);
                            sets.extend_from_slice(set);
                        }
                        if sets != parameter_sets || nal_length_size != configuration.nal_unit_header_length {
                            parameter_sets = sets;
                            nal_length_size = configuration.nal_unit_header_length;
                        }
                        needs_parameter_sets = true;
                    }
                    Ok(Event::Video { sequence, unit, received }) => {
                        if waiting_for_key_frame && !unit.is_key_frame {
                            // A dependent frame without its reference chain;
                            // acknowledging the deliberate drop frees credit.
                            feedback.record(sequence, received.elapsed());
                            continue;
                        }
                        annex_b.clear();
                        if unit.is_key_frame || needs_parameter_sets {
                            annex_b.extend_from_slice(&parameter_sets);
                            needs_parameter_sets = false;
                        }
                        let decoded = if append_annex_b(&unit.data, nal_length_size, &mut annex_b) {
                            decoder.decode(&annex_b)
                        } else {
                            Err(-1)
                        };
                        match decoded {
                            Ok(picture) => {
                                waiting_for_key_frame = false;
                                if let Some(picture) = picture {
                                    slot.put(picture);
                                    wake();
                                }
                            }
                            Err(status) => {
                                eprintln!("glassy-desk: decode error {status}; requesting a keyframe");
                                decoder.flush();
                                if decoder.hardware {
                                    hardware_failures += 1;
                                    if hardware_failures >= 5 {
                                        eprintln!("glassy-desk: repeated VA-API failures; switching to software decoding");
                                        if let Ok(software) = Decoder::new(false) {
                                            decoder = software;
                                            slot.hardware.store(false, Ordering::Relaxed);
                                        }
                                    }
                                }
                                waiting_for_key_frame = true;
                                needs_parameter_sets = true;
                                let _ = sender.send(Kind::KeyFrameRequest, &[]);
                            }
                        }
                        feedback.record(sequence, received.elapsed());
                    }
                    Ok(_) => {}
                    Err(RecvTimeoutError::Timeout) => feedback.flush(),
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
        })
        .expect("spawn decoder thread")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Encodes a short clip (Main profile, no B-frames, like VideoToolbox's
    /// real-time output) and splits it into access units at AUD NAL units.
    fn sample_access_units() -> Option<Vec<Vec<u8>>> {
        let output = std::process::Command::new("ffmpeg")
            .args([
                "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30",
                "-frames:v", "12", "-c:v", "libx264", "-profile:v", "main", "-bf", "0", "-g", "6",
                "-x264-params", "aud=1", "-f", "h264", "-",
            ])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let stream = output.stdout;
        let aud = [0u8, 0, 0, 1, 9];
        let starts: Vec<usize> = (0..stream.len().saturating_sub(4)).filter(|&i| stream[i..i + 5] == aud).collect();
        Some(
            starts
                .iter()
                .enumerate()
                .map(|(n, &start)| stream[start..*starts.get(n + 1).unwrap_or(&stream.len())].to_vec())
                .collect(),
        )
    }

    fn decode_all(prefer_hardware: bool) -> Option<(bool, usize, Layout, u32, u32)> {
        let units = sample_access_units()?;
        let mut decoder = Decoder::new(prefer_hardware).ok()?;
        let mut pictures = 0;
        let mut last = None;
        for unit in &units {
            if let Some(picture) = decoder.decode(unit).expect("decode") {
                pictures += 1;
                last = Some((picture.layout(), picture.width(), picture.height()));
            }
        }
        let (layout, width, height) = last?;
        Some((decoder.hardware, pictures, layout, width, height))
    }

    #[test]
    fn decodes_h264_with_software() {
        let Some((_, pictures, layout, width, height)) = decode_all(false) else {
            eprintln!("ffmpeg/libx264 unavailable; skipping");
            return;
        };
        // Low-delay decoding: one picture out per access unit in.
        assert_eq!(pictures, 12);
        assert_eq!(layout, Layout::I420);
        assert_eq!((width, height), (1920, 1080));
    }

    #[test]
    fn decodes_h264_with_vaapi_when_available() {
        let Some((hardware, pictures, layout, width, height)) = decode_all(true) else {
            eprintln!("ffmpeg/libx264 unavailable; skipping");
            return;
        };
        eprintln!("hardware={hardware} layout={layout:?}");
        assert_eq!(pictures, 12);
        assert_eq!((width, height), (1920, 1080));
        if hardware {
            assert_eq!(layout, Layout::Nv12);
        }
    }

    #[test]
    fn avcc_to_annex_b() {
        let avcc = [0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x41];
        let mut out = Vec::new();
        assert!(append_annex_b(&avcc, 4, &mut out));
        assert_eq!(out, [0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x41]);
        assert!(!append_annex_b(&[0, 0, 0, 9, 1], 4, &mut Vec::new()));
    }
}
