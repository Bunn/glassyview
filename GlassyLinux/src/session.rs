//! Encrypted Glassy Stream transport: route selection, authentication, the
//! inbound reader thread, and a sequence-ordered encrypted writer.

use crate::password;
use crate::store::Credential;
use crate::wire::{self, caps, AuthenticationMethod, ClientHello, Frame, Kind, ServerHello, SessionMaterial};
use anyhow::{anyhow, bail, ensure, Context, Result};
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroize;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const AUTHENTICATION_TIMEOUT: Duration = Duration::from_secs(12);
/// The viewer pings every few seconds; silence beyond this means the route died.
const IDLE_READ_TIMEOUT: Duration = Duration::from_secs(20);

/// Errors that must not trigger an automatic reconnect: the user has to act.
#[derive(Debug)]
pub struct Fatal(pub String);

impl std::fmt::Display for Fatal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Fatal {}

pub fn is_fatal(error: &anyhow::Error) -> bool {
    error.downcast_ref::<Fatal>().is_some()
}

fn fatal(message: impl Into<String>) -> anyhow::Error {
    anyhow!(Fatal(message.into()))
}

pub enum Bootstrap {
    Code(String),
    Password(String),
}

pub struct ConnectRequest {
    pub addresses: Vec<(String, u16)>,
    pub expected_host_id: Option<[u8; wire::IDENTIFIER_LENGTH]>,
    pub bootstrap: Option<Bootstrap>,
    pub credentials: Vec<Credential>,
    pub client_name: String,
    pub quality: wire::Quality,
}

#[derive(Clone)]
pub struct Authenticated {
    pub host_id: [u8; wire::IDENTIFIER_LENGTH],
    pub host_name: String,
    pub client_id: [u8; wire::IDENTIFIER_LENGTH],
    pub resume_secret: [u8; wire::RESUME_SECRET_LENGTH],
    pub connected_host: String,
    pub port: u16,
    pub resumed: bool,
    pub capabilities: u32,
}

pub enum Event {
    VideoConfiguration(wire::VideoConfiguration),
    Video { sequence: u64, unit: wire::VideoAccessUnit, received: Instant },
    Status(wire::HostStatus),
    Pong,
    Closed(anyhow::Error),
}

struct Outbound {
    stream: TcpStream,
    next_sequence: u64,
}

/// Thread-safe sender for authenticated client-to-server messages. Holding the
/// lock across sequence assignment, sealing and writing keeps the wire order
/// identical to the nonce order.
pub struct Sender {
    outbound: Mutex<Outbound>,
    material: SessionMaterial,
    capabilities: u32,
    closed: AtomicBool,
}

impl Sender {
    pub fn send(&self, kind: Kind, plaintext: &[u8]) -> Result<()> {
        if self.closed.load(Ordering::Relaxed) {
            bail!("connection closed");
        }
        let mut out = self.outbound.lock().unwrap();
        let sequence = out.next_sequence;
        out.next_sequence += 1;
        let sealed = self.material.seal(plaintext, kind, 0, sequence)?;
        let frame = wire::encode_frame(kind, wire::FLAG_ENCRYPTED, sequence, &sealed)?;
        let result = out.stream.write_all(&frame);
        if result.is_err() {
            self.close_locked(&out);
        }
        result.context("sending to the Mac failed")
    }

    pub fn supports(&self, capability: u32) -> bool {
        self.capabilities & capability == capability
    }

    pub fn close(&self) {
        let out = self.outbound.lock().unwrap();
        self.close_locked(&out);
    }

    fn close_locked(&self, out: &Outbound) {
        self.closed.store(true, Ordering::Relaxed);
        let _ = out.stream.shutdown(Shutdown::Both);
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Relaxed)
    }
}

pub struct Session {
    pub sender: Arc<Sender>,
    reader: TcpStream,
    last_inbound_sequence: u64,
    maximum_inbound_payload_length: usize,
}

/// Connects to the first reachable address, authenticates, and subscribes to
/// adaptive delivery. Blocks for at most a few seconds.
pub fn connect(request: ConnectRequest) -> Result<(Session, Authenticated)> {
    let uses_password = matches!(request.bootstrap, Some(Bootstrap::Password(_)));
    let addresses: Vec<(String, u16)> = request
        .addresses
        .iter()
        .filter(|(host, _)| !uses_password || password::is_recognized_tailscale_host(host))
        .cloned()
        .collect();
    if addresses.is_empty() {
        if uses_password {
            return Err(fatal(
                "Password pairing requires the Mac's Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48) or its full .ts.net name.",
            ));
        }
        bail!("no address to connect to");
    }

    let (mut stream, hello_frame, connected_host, port) = race_routes(&addresses, request.expected_host_id)?;
    stream.set_read_timeout(Some(AUTHENTICATION_TIMEOUT))?;
    stream.set_write_timeout(Some(AUTHENTICATION_TIMEOUT))?;

    let hello = ServerHello::decode(&hello_frame.payload)?;
    let capabilities = hello.capabilities;
    let required = caps::H264_AVCC | caps::ENCRYPTED_MEDIA | caps::DIRECT_INPUT;
    if capabilities & required != required {
        return Err(fatal("This version of Glassy Desk for Mac is not supported. Update it on the Mac and try again."));
    }
    if let Some(expected) = request.expected_host_id {
        if hello.host_identifier != expected {
            return Err(fatal("This is not the Mac paired with this saved machine."));
        }
    }

    let stored = request.credentials.iter().find(|c| c.host_id == hello.host_identifier);
    let client_identifier = match stored {
        Some(c) => c.client_id,
        None => random_array()?,
    };

    let (mut credential, method, resumed): (Vec<u8>, AuthenticationMethod, bool) = match &request.bootstrap {
        Some(Bootstrap::Code(code)) => {
            let code = wire::normalized_pairing_code(code)
                .ok_or_else(|| fatal("The pairing code must contain twelve valid symbols."))?;
            (code.into_bytes(), AuthenticationMethod::PairingCode, false)
        }
        Some(Bootstrap::Password(secret)) => {
            if capabilities & caps::PAIRING_PASSWORD == 0 {
                return Err(fatal("Glassy Desk on this Mac does not support password pairing."));
            }
            let derived = password::derive_credential(secret, &hello.host_identifier).map_err(|e| fatal(e.to_string()))?;
            (derived.to_vec(), AuthenticationMethod::PairingPasswordV1, false)
        }
        None => match stored {
            Some(c) => (c.resume_secret.to_vec(), AuthenticationMethod::ResumeSecret, true),
            None => {
                return Err(fatal(format!(
                    "This computer is not paired with {}. Run `glassy-desk pair` with the code shown by Glassy Desk for Mac.",
                    hello.server_name
                )))
            }
        },
    };

    let mut secret_bytes: [u8; 32] = random_array()?;
    let private_key = StaticSecret::from(secret_bytes);
    secret_bytes.zeroize();
    let shared = private_key.diffie_hellman(&PublicKey::from(hello.server_public_key));
    ensure!(shared.was_contributory(), "invalid host public key");
    let shared_bytes = *shared.as_bytes();

    let client_hello = ClientHello {
        client_identifier,
        client_nonce: random_array()?,
        client_public_key: *PublicKey::from(&private_key).as_bytes(),
        authentication_method: method,
        pairing_window: hello.pairing_window,
        client_name: request.client_name.clone(),
    };
    let transcript = wire::authentication_transcript(&hello, &client_hello)?;
    let proof = wire::authentication_proof(&shared_bytes, &credential, &transcript);
    let material = SessionMaterial::derive(&shared_bytes, &credential, &transcript)?;
    credential.zeroize();

    // Client sequence numbers start at 1 with the plaintext ClientHello.
    let hello_payload = client_hello.encode_with_proof(&proof)?;
    stream.write_all(&wire::encode_frame(Kind::ClientHello, 0, 1, &hello_payload)?)?;

    let mut last_inbound_sequence = hello_frame.sequence;
    let frame = match read_frame(&mut stream, wire::MAXIMUM_HANDSHAKE_PAYLOAD_LENGTH) {
        Ok(frame) => frame,
        Err(e) if is_timeout(&e) => bail!("Glassy Desk did not complete the secure connection in time."),
        Err(e) if is_eof(&e) && !resumed => {
            return Err(fatal("The Mac closed the connection during pairing. Check the code (it rotates every minute) and try again."))
        }
        Err(e) => return Err(e),
    };
    ensure!(frame.sequence > last_inbound_sequence, "replayed or out-of-order sequence");
    last_inbound_sequence = frame.sequence;
    if frame.kind == Kind::ProtocolError {
        let message = wire::decode_protocol_error(&frame.payload);
        return Err(fatal(format!("Glassy Desk rejected authentication: {message}")));
    }
    ensure!(
        frame.kind == Kind::AuthenticationAccepted && frame.flags == wire::FLAG_ENCRYPTED,
        "expected encrypted AuthenticationAccepted"
    );
    let plaintext = material.open(&frame.payload, frame.kind, frame.flags, frame.sequence)?;
    let accepted = wire::AuthenticationAccepted::decode(&plaintext)?;
    ensure!(accepted.client_identifier == client_identifier, "host echoed a different client identifier");

    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(IDLE_READ_TIMEOUT))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let reader = stream.try_clone()?;
    let sender = Arc::new(Sender {
        outbound: Mutex::new(Outbound { stream, next_sequence: 2 }),
        material,
        capabilities,
        closed: AtomicBool::new(false),
    });

    // Adaptive feedback with sequence zero is the explicit subscription and
    // must be the first encrypted message so the host starts media promptly.
    if capabilities & caps::ADAPTIVE_STREAM != 0 {
        sender.send(Kind::StreamFeedback, &wire::encode_stream_feedback(0, 0))?;
    }
    if capabilities & caps::STREAM_QUALITY_CONTROL != 0 {
        sender.send(Kind::StreamQualityRequest, &wire::encode_stream_quality_request(request.quality))?;
    }

    let authenticated = Authenticated {
        host_id: hello.host_identifier,
        host_name: hello.server_name,
        client_id: accepted.client_identifier,
        resume_secret: accepted.resume_secret,
        connected_host,
        port,
        resumed,
        capabilities,
    };
    let session = Session {
        sender,
        reader,
        last_inbound_sequence,
        maximum_inbound_payload_length: accepted.maximum_media_payload_length as usize,
    };
    Ok((session, authenticated))
}

impl Session {
    /// Runs the inbound loop on a new thread. Video goes to `video`, everything
    /// else (and the final `Closed`) to `on_event`.
    pub fn spawn_reader(
        self,
        video: mpsc::SyncSender<Event>,
        on_event: impl Fn(Event) + Send + 'static,
    ) -> thread::JoinHandle<()> {
        thread::Builder::new()
            .name("glassy-net".into())
            .spawn(move || {
                let sender = self.sender.clone();
                let error = self.run(&video, &on_event).unwrap_err();
                sender.close();
                on_event(Event::Closed(error));
            })
            .expect("spawn network thread")
    }

    fn run(mut self, video: &mpsc::SyncSender<Event>, on_event: &impl Fn(Event)) -> Result<()> {
        loop {
            let frame = match read_frame(&mut self.reader, self.maximum_inbound_payload_length) {
                Ok(frame) => frame,
                Err(_) if self.sender.is_closed() => bail!("disconnected"),
                Err(e) if is_timeout(&e) => bail!("The Mac stopped responding."),
                Err(e) if is_eof(&e) => bail!("Glassy Desk closed the connection."),
                Err(e) => return Err(e),
            };
            let received = Instant::now();
            ensure!(frame.sequence > self.last_inbound_sequence, "replayed or out-of-order sequence");
            self.last_inbound_sequence = frame.sequence;
            if frame.kind == Kind::ProtocolError {
                return Err(fatal(format!("Glassy Desk: {}", wire::decode_protocol_error(&frame.payload))));
            }
            ensure!(frame.flags & wire::FLAG_ENCRYPTED != 0, "received plaintext after authentication");
            let plaintext = self.sender.material.open(&frame.payload, frame.kind, frame.flags, frame.sequence)?;
            let key_frame = frame.flags & wire::FLAG_KEY_FRAME != 0;
            match frame.kind {
                Kind::VideoConfiguration => {
                    ensure!(!key_frame, "video configuration incorrectly carries keyframe flag");
                    let configuration = wire::VideoConfiguration::decode(&plaintext)?;
                    if video.send(Event::VideoConfiguration(configuration)).is_err() {
                        bail!("decoder stopped");
                    }
                }
                Kind::VideoAccessUnit => {
                    let unit = wire::VideoAccessUnit::decode(plaintext, key_frame)?;
                    if video.send(Event::Video { sequence: frame.sequence, unit, received }).is_err() {
                        bail!("decoder stopped");
                    }
                }
                Kind::HostStreamStatus => {
                    ensure!(self.sender.supports(caps::ADAPTIVE_STREAM), "host stream status was not negotiated");
                    on_event(Event::Status(wire::HostStatus::decode(&plaintext)?));
                }
                Kind::Pong => on_event(Event::Pong),
                Kind::CursorPosition => {
                    // Not subscribed; the video already contains the cursor.
                    let _ = wire::decode_cursor_position(&plaintext)?;
                }
                other => bail!("message type {other:?} is invalid in the server direction"),
            }
        }
    }
}

/// Opens every address concurrently and keeps the first route that returns a
/// valid ServerHello from the expected Mac.
fn race_routes(
    addresses: &[(String, u16)],
    expected_host_id: Option<[u8; wire::IDENTIFIER_LENGTH]>,
) -> Result<(TcpStream, Frame, String, u16)> {
    let (tx, rx) = mpsc::channel::<Result<(TcpStream, Frame, String, u16)>>();
    for (host, port) in addresses.iter().cloned() {
        let tx = tx.clone();
        thread::spawn(move || {
            let result = (|| -> Result<(TcpStream, Frame, String, u16)> {
                let resolved: Vec<SocketAddr> = (host.as_str(), port)
                    .to_socket_addrs()
                    .with_context(|| format!("could not resolve {host}"))?
                    .collect();
                let mut last_error = anyhow!("{host} did not resolve to an address");
                for address in resolved {
                    match TcpStream::connect_timeout(&address, CONNECT_TIMEOUT) {
                        Ok(mut stream) => {
                            stream.set_read_timeout(Some(CONNECT_TIMEOUT))?;
                            let frame = read_frame(&mut stream, wire::MAXIMUM_HANDSHAKE_PAYLOAD_LENGTH)
                                .with_context(|| format!("{host}:{port} is not a Glassy Desk host"))?;
                            ensure!(
                                frame.kind == Kind::ServerHello && frame.flags == 0 && frame.sequence == 1,
                                "expected plaintext ServerHello"
                            );
                            if let Some(expected) = expected_host_id {
                                let hello = ServerHello::decode(&frame.payload)?;
                                ensure!(hello.host_identifier == expected, "{host} is a different Mac");
                            }
                            return Ok((stream, frame, host.clone(), port));
                        }
                        Err(e) => last_error = anyhow!("could not connect to {host}:{port}: {e}"),
                    }
                }
                Err(last_error)
            })();
            let _ = tx.send(result);
        });
    }
    drop(tx);
    let mut errors = Vec::new();
    for result in rx {
        match result {
            Ok(winner) => return Ok(winner),
            Err(e) => errors.push(format!("{e:#}")),
        }
    }
    bail!("Could not reach Glassy Desk for Mac: {}", errors.join("; "))
}

fn read_frame(stream: &mut TcpStream, allowed_length: usize) -> Result<Frame> {
    let mut header_bytes = [0u8; wire::HEADER_LENGTH];
    stream.read_exact(&mut header_bytes)?;
    let header = wire::decode_header(&header_bytes, allowed_length)?;
    let mut payload = vec![0u8; header.payload_length];
    stream.read_exact(&mut payload)?;
    Ok(Frame { kind: header.kind, flags: header.flags, sequence: header.sequence, payload })
}

fn io_kind(error: &anyhow::Error) -> Option<ErrorKind> {
    error.downcast_ref::<std::io::Error>().map(|e| e.kind())
}

fn is_timeout(error: &anyhow::Error) -> bool {
    matches!(io_kind(error), Some(ErrorKind::WouldBlock | ErrorKind::TimedOut))
}

fn is_eof(error: &anyhow::Error) -> bool {
    matches!(io_kind(error), Some(ErrorKind::UnexpectedEof | ErrorKind::ConnectionReset))
}

fn random_array<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0u8; N];
    getrandom::getrandom(&mut bytes).map_err(|e| anyhow!("secure random generator failed: {e}"))?;
    Ok(bytes)
}

pub fn client_name() -> String {
    let host = std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "Linux".into());
    let mut name = host;
    while name.len() > 255 {
        name.pop();
    }
    name
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    fn write_frame(stream: &mut TcpStream, kind: Kind, flags: u16, sequence: u64, payload: &[u8]) {
        stream.write_all(&wire::encode_frame(kind, flags, sequence, payload).unwrap()).unwrap();
    }

    /// Minimal host that verifies the client's proof exactly as
    /// `HostServer.authenticate` does, then exercises the encrypted channel.
    fn fake_host(listener: TcpListener, code: &'static str, reject: bool) {
        let (mut stream, _) = listener.accept().unwrap();
        let secret = StaticSecret::from([5u8; 32]);
        let hello = ServerHello {
            host_identifier: [9u8; 16],
            server_nonce: [1u8; 32],
            server_public_key: *PublicKey::from(&secret).as_bytes(),
            pairing_window: 42,
            pairing_code_lifetime_seconds: 60,
            capabilities: 0b1101_1111,
            server_name: "Test Mac".into(),
        };
        write_frame(&mut stream, Kind::ServerHello, 0, 1, &hello.encode().unwrap());

        let frame = read_frame(&mut stream, wire::MAXIMUM_HANDSHAKE_PAYLOAD_LENGTH).unwrap();
        assert_eq!((frame.kind, frame.flags, frame.sequence), (Kind::ClientHello, 0, 1));
        let p = &frame.payload;
        let name_length = u16::from_be_bytes([p[92], p[93]]) as usize;
        assert_eq!(p.len(), 94 + name_length + 32);
        assert_eq!(&p[81..84], &[0, 0, 0], "reserved bytes");
        assert_eq!(p[80], AuthenticationMethod::PairingCode as u8);
        let client = ClientHello {
            client_identifier: p[0..16].try_into().unwrap(),
            client_nonce: p[16..48].try_into().unwrap(),
            client_public_key: p[48..80].try_into().unwrap(),
            authentication_method: AuthenticationMethod::PairingCode,
            pairing_window: u64::from_be_bytes(p[84..92].try_into().unwrap()),
            client_name: String::from_utf8(p[94..94 + name_length].to_vec()).unwrap(),
        };
        assert_eq!(client.pairing_window, 42, "client echoes the server's pairing window");
        let proof: [u8; 32] = p[94 + name_length..].try_into().unwrap();
        let shared = *secret.diffie_hellman(&PublicKey::from(client.client_public_key)).as_bytes();
        let transcript = wire::authentication_transcript(&hello, &client).unwrap();
        let valid = wire::authentication_proof(&shared, code.as_bytes(), &transcript) == proof;
        if reject || !valid {
            let message = b"Authentication failed.";
            let mut error = vec![0, 1];
            error.extend_from_slice(&(message.len() as u16).to_be_bytes());
            error.extend_from_slice(message);
            write_frame(&mut stream, Kind::ProtocolError, 0, 2, &error);
            return;
        }
        let material = SessionMaterial::derive(&shared, code.as_bytes(), &transcript).unwrap();

        let mut accepted = client.client_identifier.to_vec();
        accepted.extend_from_slice(&[7u8; 32]);
        accepted.extend_from_slice(&1_000u64.to_be_bytes());
        accepted.extend_from_slice(&(1u32 << 20).to_be_bytes());
        let sealed = material.seal_as_server(&accepted, Kind::AuthenticationAccepted, 0, 2).unwrap();
        write_frame(&mut stream, Kind::AuthenticationAccepted, wire::FLAG_ENCRYPTED, 2, &sealed);

        // Adaptive subscription must come first, then the quality request.
        let feedback = read_frame(&mut stream, 1024).unwrap();
        assert_eq!((feedback.kind, feedback.sequence), (Kind::StreamFeedback, 2));
        let plain = material.open_as_server(&feedback.payload, feedback.kind, feedback.flags, 2).unwrap();
        assert_eq!(plain, [0u8; 16]);
        let quality = read_frame(&mut stream, 1024).unwrap();
        assert_eq!((quality.kind, quality.sequence), (Kind::StreamQualityRequest, 3));
        let plain = material.open_as_server(&quality.payload, quality.kind, quality.flags, 3).unwrap();
        assert_eq!(plain, [2, 0, 0, 0]);

        let status = material.seal_as_server(&[1, 3, 0, 0], Kind::HostStreamStatus, 0, 3).unwrap();
        write_frame(&mut stream, Kind::HostStreamStatus, wire::FLAG_ENCRYPTED, 3, &status);
        let pong = material.seal_as_server(&[], Kind::Pong, 0, 4).unwrap();
        write_frame(&mut stream, Kind::Pong, wire::FLAG_ENCRYPTED, 4, &pong);
    }

    fn request(port: u16, code: &str) -> ConnectRequest {
        ConnectRequest {
            addresses: vec![("127.0.0.1".into(), port)],
            expected_host_id: None,
            bootstrap: Some(Bootstrap::Code(code.into())),
            credentials: vec![],
            client_name: "test-linux".into(),
            quality: wire::Quality::Best,
        }
    }

    #[test]
    fn pairs_with_code_and_receives_encrypted_messages() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let host = thread::spawn(move || fake_host(listener, "ABCDEFGHJK23", false));

        let (session, authenticated) = connect(request(port, "abcd-efgh-jk23")).unwrap();
        assert_eq!(authenticated.host_name, "Test Mac");
        assert_eq!(authenticated.host_id, [9u8; 16]);
        assert_eq!(authenticated.resume_secret, [7u8; 32]);
        assert!(!authenticated.resumed);

        let (video_tx, _video_rx) = mpsc::sync_channel(4);
        let (event_tx, event_rx) = mpsc::channel();
        session.spawn_reader(video_tx, move |event| {
            let _ = event_tx.send(event);
        });
        let timeout = Duration::from_secs(5);
        match event_rx.recv_timeout(timeout).unwrap() {
            Event::Status(status) => {
                assert_eq!(status.state, wire::CaptureState::Streaming);
                assert!(status.owns_input && status.accessibility_granted);
            }
            _ => panic!("expected status"),
        }
        assert!(matches!(event_rx.recv_timeout(timeout).unwrap(), Event::Pong));
        match event_rx.recv_timeout(timeout).unwrap() {
            Event::Closed(error) => assert!(!is_fatal(&error), "a dropped route is transient"),
            _ => panic!("expected close"),
        }
        host.join().unwrap();
    }

    #[test]
    fn rejected_code_is_fatal() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let host = thread::spawn(move || fake_host(listener, "ABCDEFGHJK23", true));
        let error = connect(request(port, "ZZZZZZZZZZZZ")).err().unwrap();
        assert!(is_fatal(&error), "{error:#}");
        assert!(error.to_string().contains("Authentication failed."));
        host.join().unwrap();
    }

    #[test]
    fn wrong_host_identity_is_refused() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let host = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let hello = ServerHello {
                host_identifier: [9u8; 16],
                server_nonce: [1u8; 32],
                server_public_key: [3u8; 32],
                pairing_window: 1,
                pairing_code_lifetime_seconds: 60,
                capabilities: 0b1101_1111,
                server_name: "Impostor".into(),
            };
            write_frame(&mut stream, Kind::ServerHello, 0, 1, &hello.encode().unwrap());
            thread::sleep(Duration::from_millis(200));
        });
        let mut request = request(port, "ABCDEFGHJK23");
        request.expected_host_id = Some([8u8; 16]);
        assert!(connect(request).is_err());
        host.join().unwrap();
    }
}
