//! Linux half of Glassy Host wire protocol v1. Keep constants, layouts and
//! transcript strings byte-for-byte aligned with
//! `GlassyHost/Services/HostProtocol.swift` and
//! `dejaview/Services/GlassyStream/GlassyStreamWire.swift`.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{bail, ensure, Context, Result};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

pub const VERSION: u8 = 1;
pub const MAGIC: u32 = 0x474C_5359; // "GLSY"
pub const HEADER_LENGTH: usize = 20;
pub const MAXIMUM_HANDSHAKE_PAYLOAD_LENGTH: usize = 64 * 1024;
pub const MAXIMUM_PAYLOAD_LENGTH: usize = 16 * 1024 * 1024;
pub const MAXIMUM_CLIPBOARD_TEXT_LENGTH: usize = 1024 * 1024;
pub const IDENTIFIER_LENGTH: usize = 16;
pub const NONCE_LENGTH: usize = 32;
pub const PUBLIC_KEY_LENGTH: usize = 32;
pub const PROOF_LENGTH: usize = 32;
pub const RESUME_SECRET_LENGTH: usize = 32;
pub const AUTHENTICATION_TAG_LENGTH: usize = 16;
pub const PAIRING_CODE_SYMBOL_COUNT: usize = 12;
pub const DEFAULT_PORT: u16 = 51515;

pub mod caps {
    pub const H264_AVCC: u32 = 1 << 0;
    pub const ENCRYPTED_MEDIA: u32 = 1 << 1;
    pub const DIRECT_INPUT: u32 = 1 << 2;
    pub const STREAM_QUALITY_CONTROL: u32 = 1 << 3;
    #[allow(dead_code)]
    pub const CURSOR_POSITION_UPDATES: u32 = 1 << 4;
    pub const PAIRING_PASSWORD: u32 = 1 << 5;
    pub const CLIPBOARD_PASTE: u32 = 1 << 6;
    pub const ADAPTIVE_STREAM: u32 = 1 << 7;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    ServerHello = 0x01,
    ClientHello = 0x02,
    AuthenticationAccepted = 0x03,
    ProtocolError = 0x04,
    Ping = 0x05,
    Pong = 0x06,
    VideoConfiguration = 0x10,
    VideoAccessUnit = 0x11,
    KeyFrameRequest = 0x12,
    StreamQualityRequest = 0x13,
    CursorPositionSubscription = 0x14,
    CursorPosition = 0x15,
    StreamFeedback = 0x16,
    HostStreamStatus = 0x17,
    PointerInput = 0x20,
    ScrollInput = 0x21,
    KeyInput = 0x22,
    TextInput = 0x23,
    ClipboardPaste = 0x24,
}

impl Kind {
    fn from_u8(value: u8) -> Option<Kind> {
        use Kind::*;
        Some(match value {
            0x01 => ServerHello,
            0x02 => ClientHello,
            0x03 => AuthenticationAccepted,
            0x04 => ProtocolError,
            0x05 => Ping,
            0x06 => Pong,
            0x10 => VideoConfiguration,
            0x11 => VideoAccessUnit,
            0x12 => KeyFrameRequest,
            0x13 => StreamQualityRequest,
            0x14 => CursorPositionSubscription,
            0x15 => CursorPosition,
            0x16 => StreamFeedback,
            0x17 => HostStreamStatus,
            0x20 => PointerInput,
            0x21 => ScrollInput,
            0x22 => KeyInput,
            0x23 => TextInput,
            0x24 => ClipboardPaste,
            _ => return None,
        })
    }
}

pub const FLAG_ENCRYPTED: u16 = 1 << 0;
pub const FLAG_KEY_FRAME: u16 = 1 << 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum AuthenticationMethod {
    PairingCode = 1,
    ResumeSecret = 2,
    PairingPasswordV1 = 3,
}

#[derive(Debug, Clone)]
pub struct Frame {
    pub kind: Kind,
    pub flags: u16,
    pub sequence: u64,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
pub struct Header {
    pub kind: Kind,
    pub flags: u16,
    pub sequence: u64,
    pub payload_length: usize,
}

pub fn encode_frame(kind: Kind, flags: u16, sequence: u64, payload: &[u8]) -> Result<Vec<u8>> {
    ensure!(payload.len() <= MAXIMUM_PAYLOAD_LENGTH, "payload exceeds the 16 MiB limit");
    let mut w = Writer::with_capacity(HEADER_LENGTH + payload.len());
    w.u32(MAGIC);
    w.u8(VERSION);
    w.u8(kind as u8);
    w.u16(flags);
    w.u64(sequence);
    w.u32(payload.len() as u32);
    w.bytes(payload);
    Ok(w.0)
}

pub fn decode_header(bytes: &[u8; HEADER_LENGTH], allowed_length: usize) -> Result<Header> {
    let mut r = Reader::new(bytes);
    ensure!(r.u32()? == MAGIC, "invalid frame magic");
    let version = r.u8()?;
    ensure!(version == VERSION, "Glassy Desk protocol version {version} is not supported");
    let raw_kind = r.u8()?;
    let kind = Kind::from_u8(raw_kind).with_context(|| format!("unknown message type {raw_kind}"))?;
    let flags = r.u16()?;
    ensure!(flags & !(FLAG_ENCRYPTED | FLAG_KEY_FRAME) == 0, "unknown message flags {flags}");
    let sequence = r.u64()?;
    let payload_length = r.u32()? as usize;
    ensure!(
        payload_length <= allowed_length.min(MAXIMUM_PAYLOAD_LENGTH),
        "payload length {payload_length} exceeds the negotiated limit"
    );
    Ok(Header { kind, flags, sequence, payload_length })
}

// ---------------------------------------------------------------- handshake

#[derive(Debug, Clone)]
pub struct ServerHello {
    pub host_identifier: [u8; IDENTIFIER_LENGTH],
    pub server_nonce: [u8; NONCE_LENGTH],
    pub server_public_key: [u8; PUBLIC_KEY_LENGTH],
    pub pairing_window: u64,
    pub pairing_code_lifetime_seconds: u16,
    pub capabilities: u32,
    pub server_name: String,
}

impl ServerHello {
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = Reader::new(data);
        let hello = ServerHello {
            host_identifier: r.array()?,
            server_nonce: r.array()?,
            server_public_key: r.array()?,
            pairing_window: r.u64()?,
            pairing_code_lifetime_seconds: r.u16()?,
            capabilities: r.u32()?,
            server_name: r.length_prefixed_string(255)?,
        };
        r.require_end()?;
        Ok(hello)
    }

    pub(crate) fn encode(&self) -> Result<Vec<u8>> {
        let mut w = Writer::with_capacity(128);
        w.bytes(&self.host_identifier);
        w.bytes(&self.server_nonce);
        w.bytes(&self.server_public_key);
        w.u64(self.pairing_window);
        w.u16(self.pairing_code_lifetime_seconds);
        w.u32(self.capabilities);
        w.length_prefixed_string(&self.server_name)?;
        Ok(w.0)
    }
}

#[derive(Debug, Clone)]
pub struct ClientHello {
    pub client_identifier: [u8; IDENTIFIER_LENGTH],
    pub client_nonce: [u8; NONCE_LENGTH],
    pub client_public_key: [u8; PUBLIC_KEY_LENGTH],
    pub authentication_method: AuthenticationMethod,
    pub pairing_window: u64,
    pub client_name: String,
}

impl ClientHello {
    fn encode_for_transcript(&self) -> Result<Vec<u8>> {
        let mut w = Writer::with_capacity(128);
        w.bytes(&self.client_identifier);
        w.bytes(&self.client_nonce);
        w.bytes(&self.client_public_key);
        w.u8(self.authentication_method as u8);
        w.bytes(&[0, 0, 0]);
        w.u64(self.pairing_window);
        w.length_prefixed_string(&self.client_name)?;
        Ok(w.0)
    }

    pub fn encode_with_proof(&self, proof: &[u8; PROOF_LENGTH]) -> Result<Vec<u8>> {
        let mut data = self.encode_for_transcript()?;
        data.extend_from_slice(proof);
        Ok(data)
    }
}

pub fn authentication_transcript(server: &ServerHello, client: &ClientHello) -> Result<Vec<u8>> {
    let mut transcript = b"GlassyHost authentication transcript v1\0".to_vec();
    transcript.extend(server.encode()?);
    transcript.extend(client.encode_for_transcript()?);
    Ok(transcript)
}

/// Mirrors CryptoKit `SharedSecret.hkdfDerivedSymmetricKey(using: SHA256,
/// salt:, sharedInfo:, outputByteCount: 32)`: HKDF-SHA256 over the raw X25519
/// output.
fn hkdf32(shared_secret: &[u8; 32], salt: &[u8], info: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(salt), shared_secret);
    let mut out = [0u8; 32];
    hk.expand(info, &mut out).expect("32 bytes is a valid HKDF-SHA256 length");
    out
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

pub fn authentication_proof(shared_secret: &[u8; 32], credential: &[u8], transcript: &[u8]) -> [u8; 32] {
    let transcript_hash = Sha256::digest(transcript);
    let mut info = b"GlassyHost authentication key v1\0".to_vec();
    info.extend_from_slice(credential);
    let key = hkdf32(shared_secret, &transcript_hash, &info);
    hmac_sha256(&key, transcript)
}

#[derive(Clone)]
pub struct SessionMaterial {
    cipher: Aes256Gcm,
    server_to_client_prefix: [u8; 4],
    client_to_server_prefix: [u8; 4],
}

impl SessionMaterial {
    pub fn derive(shared_secret: &[u8; 32], credential: &[u8], transcript: &[u8]) -> Result<Self> {
        let transcript_hash = Sha256::digest(transcript);
        let mut info = b"GlassyHost encrypted session v1\0".to_vec();
        info.extend_from_slice(credential);
        let key = hkdf32(shared_secret, &transcript_hash, &info);
        let server = hmac_sha256(&key, b"GlassyHost server-to-client nonce v1");
        let client = hmac_sha256(&key, b"GlassyHost client-to-server nonce v1");
        let material = SessionMaterial {
            cipher: Aes256Gcm::new_from_slice(&key).expect("32-byte AES key"),
            server_to_client_prefix: server[..4].try_into().unwrap(),
            client_to_server_prefix: client[..4].try_into().unwrap(),
        };
        // Preserve the v1 key schedule, but never permit a shared key to use
        // the same nonce domain for both directions.
        ensure!(
            material.server_to_client_prefix != material.client_to_server_prefix,
            "session nonce directions overlap"
        );
        Ok(material)
    }

    fn nonce(prefix: &[u8; 4], sequence: u64) -> [u8; 12] {
        let mut nonce = [0u8; 12];
        nonce[..4].copy_from_slice(prefix);
        nonce[4..].copy_from_slice(&sequence.to_be_bytes());
        nonce
    }

    /// Encrypts a client-to-server message. Returns ciphertext || tag.
    pub fn seal(&self, plaintext: &[u8], kind: Kind, flags: u16, sequence: u64) -> Result<Vec<u8>> {
        let flags = flags | FLAG_ENCRYPTED;
        let nonce = Self::nonce(&self.client_to_server_prefix, sequence);
        let aad = additional_data(kind, flags, sequence);
        self.cipher
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: plaintext, aad: &aad })
            .map_err(|_| anyhow::anyhow!("encryption failed"))
    }

    /// Host-direction sealing, used by the loopback fake host in tests.
    #[cfg(test)]
    pub fn seal_as_server(&self, plaintext: &[u8], kind: Kind, flags: u16, sequence: u64) -> Result<Vec<u8>> {
        let flags = flags | FLAG_ENCRYPTED;
        let nonce = Self::nonce(&self.server_to_client_prefix, sequence);
        let aad = additional_data(kind, flags, sequence);
        self.cipher
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: plaintext, aad: &aad })
            .map_err(|_| anyhow::anyhow!("encryption failed"))
    }

    #[cfg(test)]
    pub fn open_as_server(&self, data: &[u8], kind: Kind, flags: u16, sequence: u64) -> Result<Vec<u8>> {
        let nonce = Self::nonce(&self.client_to_server_prefix, sequence);
        let aad = additional_data(kind, flags, sequence);
        self.cipher
            .decrypt(Nonce::from_slice(&nonce), Payload { msg: data, aad: &aad })
            .map_err(|_| anyhow::anyhow!("message authentication failed"))
    }

    /// Decrypts a server-to-client message.
    pub fn open(&self, ciphertext_and_tag: &[u8], kind: Kind, flags: u16, sequence: u64) -> Result<Vec<u8>> {
        ensure!(
            flags & FLAG_ENCRYPTED != 0 && ciphertext_and_tag.len() >= AUTHENTICATION_TAG_LENGTH,
            "encrypted message is missing its authentication tag"
        );
        let nonce = Self::nonce(&self.server_to_client_prefix, sequence);
        let aad = additional_data(kind, flags, sequence);
        self.cipher
            .decrypt(Nonce::from_slice(&nonce), Payload { msg: ciphertext_and_tag, aad: &aad })
            .map_err(|_| anyhow::anyhow!("message authentication failed"))
    }
}

fn additional_data(kind: Kind, flags: u16, sequence: u64) -> Vec<u8> {
    let mut w = Writer::with_capacity(16);
    w.u32(MAGIC);
    w.u8(VERSION);
    w.u8(kind as u8);
    w.u16(flags);
    w.u64(sequence);
    w.0
}

pub struct AuthenticationAccepted {
    pub client_identifier: [u8; IDENTIFIER_LENGTH],
    pub resume_secret: [u8; RESUME_SECRET_LENGTH],
    #[allow(dead_code)]
    pub server_time_milliseconds: u64,
    pub maximum_media_payload_length: u32,
}

impl AuthenticationAccepted {
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = Reader::new(data);
        let accepted = AuthenticationAccepted {
            client_identifier: r.array()?,
            resume_secret: r.array()?,
            server_time_milliseconds: r.u64()?,
            maximum_media_payload_length: r.u32()?,
        };
        r.require_end()?;
        ensure!(
            accepted.maximum_media_payload_length > 0
                && accepted.maximum_media_payload_length as usize <= MAXIMUM_PAYLOAD_LENGTH,
            "invalid maximum media payload length"
        );
        Ok(accepted)
    }
}

pub fn decode_protocol_error(data: &[u8]) -> String {
    let parsed = (|| -> Result<String> {
        let mut r = Reader::new(data);
        let code = r.u16()?;
        let message = r.length_prefixed_string(1024)?;
        r.require_end()?;
        Ok(if message.is_empty() { format!("Host error {code}") } else { message })
    })();
    parsed.unwrap_or_else(|_| "The host rejected the protocol message.".into())
}

// ---------------------------------------------------------------- media

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoConfiguration {
    pub nal_unit_header_length: usize,
    pub parameter_sets: Vec<Vec<u8>>,
}

impl VideoConfiguration {
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = Reader::new(data);
        let nal_unit_header_length = r.u8()? as usize;
        let count = r.u8()? as usize;
        ensure!(r.u16()? == 0, "video configuration reserved bytes are nonzero");
        ensure!(
            (1..=4).contains(&nal_unit_header_length) && (1..=16).contains(&count),
            "invalid H.264 configuration"
        );
        let mut parameter_sets = Vec::with_capacity(count);
        for _ in 0..count {
            let length = r.u32()? as usize;
            ensure!(length > 0 && length <= MAXIMUM_PAYLOAD_LENGTH, "invalid H.264 parameter-set length");
            parameter_sets.push(r.take(length)?.to_vec());
        }
        r.require_end()?;
        Ok(VideoConfiguration { nal_unit_header_length, parameter_sets })
    }
}

pub struct VideoAccessUnit {
    /// AVCC formatted (length-prefixed) NAL units.
    pub data: Vec<u8>,
    #[allow(dead_code)]
    pub presentation_nanoseconds: i64,
    pub is_key_frame: bool,
}

impl VideoAccessUnit {
    pub fn decode(mut data: Vec<u8>, is_key_frame: bool) -> Result<Self> {
        ensure!(data.len() > 16, "empty H.264 access unit");
        let mut r = Reader::new(&data);
        let presentation_nanoseconds = r.i64()?;
        let duration_nanoseconds = r.i64()?;
        ensure!(
            presentation_nanoseconds >= 0 && (duration_nanoseconds == -1 || duration_nanoseconds >= 0),
            "invalid media timestamp"
        );
        data.drain(..16);
        Ok(VideoAccessUnit { data, presentation_nanoseconds, is_key_frame })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureState {
    Starting,
    Streaming,
    Stopped,
    ScreenPermissionRequired,
    DisplayUnavailable,
    CaptureFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostStatus {
    pub state: CaptureState,
    pub accessibility_granted: bool,
    pub owns_input: bool,
}

impl HostStatus {
    pub fn decode(data: &[u8]) -> Result<Self> {
        let mut r = Reader::new(data);
        let state = match r.u8()? {
            0 => CaptureState::Starting,
            1 => CaptureState::Streaming,
            2 => CaptureState::Stopped,
            3 => CaptureState::ScreenPermissionRequired,
            4 => CaptureState::DisplayUnavailable,
            5 => CaptureState::CaptureFailed,
            _ => bail!("unknown host stream state"),
        };
        let flags = r.u8()?;
        ensure!(flags & !3 == 0 && r.u16()? == 0, "invalid host stream status flags");
        r.require_end()?;
        Ok(HostStatus { state, accessibility_granted: flags & 1 != 0, owns_input: flags & 2 != 0 })
    }

    pub fn message(&self) -> Option<&'static str> {
        match self.state {
            CaptureState::Starting => None,
            CaptureState::Stopped => Some("Screen sharing is stopped. Open Glassy Desk on your Mac to resume sharing."),
            CaptureState::ScreenPermissionRequired => {
                Some("On your Mac, open Glassy Desk and allow Screen Recording and Direct Screen Access.")
            }
            CaptureState::DisplayUnavailable => {
                Some("Waiting for the Mac display. If the Mac is asleep or locked, wake or unlock it.")
            }
            CaptureState::CaptureFailed => Some("Your Mac could not start screen capture."),
            CaptureState::Streaming if !self.accessibility_granted => {
                Some("View only: enable Accessibility for Glassy Desk on your Mac to use the keyboard and pointer.")
            }
            CaptureState::Streaming if !self.owns_input => {
                Some("View only: another connected device controls this Mac.")
            }
            CaptureState::Streaming => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Quality {
    /// 720p / 15 FPS / ~2 Mbps
    DataSaver,
    /// 1080p / 30 FPS / ~5 Mbps
    Balanced,
    /// up to 4K / 60 FPS / ~12 Mbps
    Best,
}

impl Quality {
    pub fn label(self) -> &'static str {
        match self {
            Quality::DataSaver => "Data Saver",
            Quality::Balanced => "Balanced",
            Quality::Best => "Best",
        }
    }
}

pub fn encode_stream_quality_request(quality: Quality) -> Vec<u8> {
    let preset = match quality {
        Quality::DataSaver => 0,
        Quality::Balanced => 1,
        Quality::Best => 2,
    };
    vec![preset, 0, 0, 0]
}

pub fn encode_stream_feedback(sequence: u64, queue_age_milliseconds: u32) -> Vec<u8> {
    let mut w = Writer::with_capacity(16);
    w.u64(sequence);
    w.u32(queue_age_milliseconds.min(60_000));
    w.u32(0);
    w.0
}

pub fn decode_cursor_position(data: &[u8]) -> Result<(u16, u16)> {
    let mut r = Reader::new(data);
    let position = (r.u16()?, r.u16()?);
    r.require_end()?;
    Ok(position)
}

// ---------------------------------------------------------------- input

pub const BUTTON_LEFT: u8 = 1 << 0;
pub const BUTTON_RIGHT: u8 = 1 << 1;

pub fn encode_pointer_input(x: u16, y: u16, buttons: u8) -> Vec<u8> {
    let mut w = Writer::with_capacity(6);
    w.u16(x);
    w.u16(y);
    w.u8(buttons & (BUTTON_LEFT | BUTTON_RIGHT));
    w.u8(0);
    w.0
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ScrollDirection {
    Up = 0,
    Down = 1,
    Left = 2,
    Right = 3,
}

pub fn encode_scroll_input(direction: ScrollDirection, steps: u16) -> Vec<u8> {
    let steps = steps.clamp(1, 64);
    let mut w = Writer::with_capacity(4);
    w.u8(direction as u8);
    w.u8(0);
    w.u16(steps);
    w.0
}

pub fn encode_key_input(keysym: u32, is_down: bool) -> Vec<u8> {
    let mut w = Writer::with_capacity(8);
    w.u32(keysym);
    w.u8(is_down as u8);
    w.bytes(&[0, 0, 0]);
    w.0
}

// ---------------------------------------------------------------- pairing code

/// Returns the canonical 12-symbol code, accepting dashes, spaces and lowercase.
pub fn normalized_pairing_code(value: &str) -> Option<String> {
    const ALPHABET: &str = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let normalized: String = value
        .trim()
        .chars()
        .filter(|c| *c != '-' && *c != ' ')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    (normalized.chars().count() == PAIRING_CODE_SYMBOL_COUNT && normalized.chars().all(|c| ALPHABET.contains(c)))
        .then_some(normalized)
}

// ---------------------------------------------------------------- bytes

struct Writer(Vec<u8>);

impl Writer {
    fn with_capacity(capacity: usize) -> Self {
        Writer(Vec::with_capacity(capacity))
    }
    fn u8(&mut self, v: u8) {
        self.0.push(v);
    }
    fn u16(&mut self, v: u16) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    fn bytes(&mut self, v: &[u8]) {
        self.0.extend_from_slice(v);
    }
    fn length_prefixed_string(&mut self, value: &str) -> Result<()> {
        ensure!(value.len() <= 255, "name exceeds 255 UTF-8 bytes");
        self.u16(value.len() as u16);
        self.bytes(value.as_bytes());
        Ok(())
    }
}

struct Reader<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Reader { data, offset: 0 }
    }
    fn take(&mut self, count: usize) -> Result<&'a [u8]> {
        ensure!(self.data.len() - self.offset >= count, "unexpected end of payload");
        let slice = &self.data[self.offset..self.offset + count];
        self.offset += count;
        Ok(slice)
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N]> {
        Ok(self.take(N)?.try_into().unwrap())
    }
    fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.array()?))
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.array()?))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.array()?))
    }
    fn i64(&mut self) -> Result<i64> {
        Ok(i64::from_be_bytes(self.array()?))
    }
    fn length_prefixed_string(&mut self, maximum: usize) -> Result<String> {
        let length = self.u16()? as usize;
        ensure!(length <= maximum, "string exceeds byte limit");
        String::from_utf8(self.take(length)?.to_vec()).context("string is not UTF-8")
    }
    fn require_end(&self) -> Result<()> {
        ensure!(self.offset == self.data.len(), "payload contains trailing bytes");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_round_trip() {
        let bytes = encode_frame(Kind::Ping, FLAG_ENCRYPTED, 7, b"abc").unwrap();
        let header = decode_header(bytes[..HEADER_LENGTH].try_into().unwrap(), 1024).unwrap();
        assert_eq!(header.kind, Kind::Ping);
        assert_eq!(header.flags, FLAG_ENCRYPTED);
        assert_eq!(header.sequence, 7);
        assert_eq!(header.payload_length, 3);
    }

    #[test]
    fn pairing_code_normalization() {
        assert_eq!(normalized_pairing_code("abcd-efgh-jk23").as_deref(), Some("ABCDEFGHJK23"));
        assert!(normalized_pairing_code("ABCDEFGHIJ23").is_none()); // I is excluded
        assert!(normalized_pairing_code("ABC").is_none());
    }

    #[test]
    fn seal_open_directions_are_distinct() {
        let material = SessionMaterial::derive(&[7u8; 32], b"credential", b"transcript").unwrap();
        let sealed = material.seal(b"hello", Kind::Ping, 0, 3).unwrap();
        // Client-sealed data must not open with the server-direction nonce.
        assert!(material.open(&sealed, Kind::Ping, FLAG_ENCRYPTED, 3).is_err());
    }

    #[test]
    fn host_status_decoding() {
        let status = HostStatus::decode(&[1, 3, 0, 0]).unwrap();
        assert_eq!(status.state, CaptureState::Streaming);
        assert!(status.accessibility_granted && status.owns_input);
        assert!(HostStatus::decode(&[1, 4, 0, 0]).is_err());
        assert!(HostStatus::decode(&[9, 0, 0, 0]).is_err());
    }
}
