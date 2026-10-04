//! Glassy Desk for Linux: a Fast Connection client for Glassy Desk for Mac.

mod decoder;
mod discover;
mod keymap;
mod password;
mod session;
mod store;
mod viewer;
mod wire;

use anyhow::{bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use session::{Authenticated, Bootstrap, ConnectRequest};
use std::io::{BufRead, IsTerminal, Write};
use store::{SavedMachine, Store};
use wire::Quality;

#[derive(Parser)]
#[command(name = "glassy-desk", version, about = "Connect to Glassy Desk for Mac from Linux")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
    #[command(flatten)]
    view: ViewArgs,
}

#[derive(Subcommand)]
enum Command {
    /// Pair with a Mac using the code (or password) shown by Glassy Desk for Mac, then connect.
    Pair {
        /// Mac address or name (e.g. 192.168.1.20, mac.local, mac.tailnet.ts.net, host:port).
        /// Omit to discover Macs on the local network. A `glassydesk://pair?...` link also works.
        host: Option<String>,
        /// The 12-symbol pairing code. Prompted for when omitted.
        #[arg(long)]
        code: Option<String>,
        /// Use the Mac's reusable pairing password instead of the code (Tailscale routes only).
        #[arg(long, conflicts_with = "code")]
        password: bool,
        /// Pair and save without opening the viewer.
        #[arg(long)]
        no_connect: bool,
    },
    /// Connect to a paired Mac (by name or address). Prompts when several are saved.
    Connect { machine: Option<String> },
    /// List paired Macs.
    List,
    /// Forget a paired Mac and delete its saved credential.
    Forget { machine: String },
    /// Find Glassy Desk for Mac hosts on the local network (Bonjour).
    Discover {
        #[arg(long, default_value_t = 3)]
        seconds: u64,
    },
    /// Show paired Macs with reachability and open viewers (used by the Omarchy bar widget).
    Status {
        /// Machine-readable output.
        #[arg(long)]
        json: bool,
        /// Also list unpaired Macs found on the local network.
        #[arg(long)]
        nearby: bool,
    },
    /// Close the open viewer for a Mac.
    Disconnect { machine: String },
    /// Install a desktop launcher so Glassy Desk appears in the Omarchy app launcher.
    InstallDesktop,
}

#[derive(Args, Clone)]
struct ViewArgs {
    /// Stream quality (defaults to the last choice for this Mac, else best).
    #[arg(long, global = true, value_enum)]
    quality: Option<Quality>,
    /// Start fullscreen.
    #[arg(long, global = true)]
    fullscreen: bool,
    /// Decode on the CPU instead of VA-API.
    #[arg(long, global = true)]
    software_decode: bool,
    /// Send Ctrl as ⌘ Command (and Super as Control).
    #[arg(long, global = true)]
    ctrl_as_cmd: bool,
    /// Do not capture system shortcuts (Super, Alt+Tab) while the window is fullscreen.
    #[arg(long, global = true)]
    no_keyboard_grab: bool,
    /// Show the Linux pointer over the video (the Mac cursor is part of the stream).
    #[arg(long, global = true)]
    show_local_cursor: bool,
    /// Reverse scroll direction.
    #[arg(long, global = true)]
    invert_scroll: bool,
    /// Scroll speed multiplier.
    #[arg(long, global = true, default_value_t = 1.0)]
    scroll_speed: f32,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("glassy-desk: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::Pair { host, code, password, no_connect }) => pair(host, code, password, no_connect, cli.view),
        Some(Command::Connect { machine }) => connect(machine, cli.view),
        None => connect(None, cli.view),
        Some(Command::List) => {
            let store = Store::load()?;
            if store.machines.is_empty() {
                println!("No paired Macs. Run `glassy-desk pair` to add one.");
            }
            for m in &store.machines {
                let alternates =
                    if m.alternate_hosts.is_empty() { String::new() } else { format!(" (+{})", m.alternate_hosts.join(", ")) };
                println!("{}\t{}:{}{}", m.name, m.host, m.port, alternates);
            }
            Ok(())
        }
        Some(Command::Forget { machine }) => {
            let mut store = Store::load()?;
            let removed = store.remove(&machine).with_context(|| format!("no saved Mac matches “{machine}”"))?;
            store.save()?;
            println!("Forgot {}. Revoke this computer in Glassy Desk for Mac → Connections to invalidate its credential there too.", removed.name);
            Ok(())
        }
        Some(Command::Discover { seconds }) => {
            let hosts = discover::browse(std::time::Duration::from_secs(seconds))?;
            if hosts.is_empty() {
                println!("No Glassy Desk for Mac hosts found. Remote Macs (e.g. over Tailscale) must be paired by address.");
            }
            for h in hosts {
                println!("{}\t{}:{}", h.name, h.addresses.join(", "), h.port);
            }
            Ok(())
        }
        Some(Command::Status { json, nearby }) => status(json, nearby),
        Some(Command::Disconnect { machine }) => {
            let store = Store::load()?;
            let m = store.find(&machine).with_context(|| format!("no saved Mac matches “{machine}”"))?;
            let pid = m.host_id_bytes().and_then(|id| store::active_pid(&id)).context("no open viewer for that Mac")?;
            // SDL turns SIGTERM into a normal quit, so held keys are released on the Mac.
            unsafe { libc::kill(pid as i32, libc::SIGTERM) };
            Ok(())
        }
        Some(Command::InstallDesktop) => install_desktop(),
    }
}

/// TCP-connect probe across every saved route, like the iOS app's
/// reachability check. It never authenticates, so it cannot count against the
/// Mac's pairing-attempt limit.
fn is_reachable(addresses: &[(String, u16)], timeout: std::time::Duration) -> bool {
    use std::net::{TcpStream, ToSocketAddrs};
    let (tx, rx) = std::sync::mpsc::channel();
    for (host, port) in addresses.iter().cloned() {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let reachable = (host.as_str(), port)
                .to_socket_addrs()
                .map(|mut addrs| addrs.any(|a| TcpStream::connect_timeout(&a, timeout).is_ok()))
                .unwrap_or(false);
            let _ = tx.send(reachable);
        });
    }
    drop(tx);
    let deadline = std::time::Instant::now() + timeout + std::time::Duration::from_millis(500);
    while let Some(remaining) = deadline.checked_duration_since(std::time::Instant::now()) {
        match rx.recv_timeout(remaining) {
            Ok(true) => return true,
            Ok(false) => continue,
            Err(_) => break,
        }
    }
    false
}

fn status(json: bool, include_nearby: bool) -> Result<()> {
    let store = Store::load()?;
    let timeout = std::time::Duration::from_millis(1500);
    let nearby_thread = include_nearby.then(|| std::thread::spawn(|| discover::browse(std::time::Duration::from_secs(2))));
    let probes: Vec<_> = store
        .machines
        .iter()
        .map(|m| {
            let addresses = m.addresses();
            std::thread::spawn(move || is_reachable(&addresses, timeout))
        })
        .collect();
    let machines: Vec<serde_json::Value> = store
        .machines
        .iter()
        .zip(probes)
        .map(|(m, probe)| {
            let connected = m.host_id_bytes().and_then(|id| store::active_pid(&id)).is_some();
            serde_json::json!({
                "name": m.name,
                "host": m.host,
                "port": m.port,
                "online": connected || probe.join().unwrap_or(false),
                "connected": connected,
                "quality": m.quality.map(|q| q.label()),
                "lastConnected": m.last_connected,
            })
        })
        .collect();
    let nearby: Vec<serde_json::Value> = match nearby_thread {
        Some(handle) => handle
            .join()
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_default()
            .into_iter()
            .filter(|h| {
                !store.machines.iter().any(|m| {
                    m.name == h.name || h.addresses.iter().any(|a| *a == m.host || m.alternate_hosts.contains(a))
                })
            })
            .map(|h| serde_json::json!({ "name": h.name, "address": h.addresses.first(), "port": h.port }))
            .collect(),
        None => Vec::new(),
    };

    if json {
        println!("{}", serde_json::json!({ "machines": machines, "nearby": nearby }));
        return Ok(());
    }
    for m in &machines {
        let state = if m["connected"] == true {
            "connected"
        } else if m["online"] == true {
            "online"
        } else {
            "offline"
        };
        println!("{}\t{}\t{}", m["name"].as_str().unwrap_or(""), m["host"].as_str().unwrap_or(""), state);
    }
    for h in &nearby {
        println!("{}\t{}\tnearby (not paired)", h["name"].as_str().unwrap_or(""), h["address"].as_str().unwrap_or(""));
    }
    Ok(())
}

fn pair(host: Option<String>, code: Option<String>, use_password: bool, no_connect: bool, view: ViewArgs) -> Result<()> {
    let mut store = Store::load()?;
    let mut code = code;
    let mut expected_host_id = None;
    let addresses: Vec<(String, u16)> = match host {
        Some(link) if link.starts_with("glassydesk://pair?") => {
            let invitation = parse_invitation(&link)?;
            code = code.or(Some(invitation.code));
            expected_host_id = invitation.host_id;
            invitation.addresses
        }
        Some(host) => vec![split_host_port(&host)],
        None => {
            eprintln!("Searching for Glassy Desk for Mac on the local network…");
            let hosts = discover::browse(std::time::Duration::from_secs(3))?;
            let host = match hosts.len() {
                0 => bail!("no Mac found nearby. Pass its address: glassy-desk pair <address>"),
                1 => hosts.into_iter().next().unwrap(),
                _ => {
                    let names: Vec<String> =
                        hosts.iter().map(|h| format!("{} ({})", h.name, h.addresses.join(", "))).collect();
                    let index = choose("Choose a Mac", &names)?;
                    hosts.into_iter().nth(index).unwrap()
                }
            };
            eprintln!("Found {}", host.name);
            host.addresses.iter().map(|a| (a.clone(), host.port)).collect()
        }
    };

    let bootstrap = if use_password {
        let secret = rpassword::prompt_password("Pairing password: ")?;
        Bootstrap::Password(secret)
    } else {
        let code = match code {
            Some(code) => code,
            None => prompt("Pairing code shown by Glassy Desk for Mac (Connections → Add Device → Pair Manually): ")?,
        };
        if wire::normalized_pairing_code(&code).is_none() {
            bail!("the pairing code must contain twelve valid symbols");
        }
        Bootstrap::Code(code)
    };

    let request = ConnectRequest {
        addresses: addresses.clone(),
        expected_host_id,
        bootstrap: Some(bootstrap),
        credentials: store.credentials(),
        client_name: session::client_name(),
        quality: view.quality.unwrap_or(Quality::Best),
    };
    eprintln!("Pairing…");
    let (session, authenticated) = session::connect(request)?;
    let alternates = addresses.iter().map(|(h, _)| h.clone()).filter(|h| *h != authenticated.connected_host).collect();
    save_authenticated(&mut store, &authenticated, alternates)?;
    eprintln!("Paired with {}. Next time just run: glassy-desk connect \"{}\"", authenticated.host_name, authenticated.host_name);
    if no_connect {
        session.sender.close();
        return Ok(());
    }
    let machine = store.find_by_host_id(&authenticated.host_id).cloned().unwrap();
    view_machine(machine, session, authenticated, view)
}

fn connect(query: Option<String>, view: ViewArgs) -> Result<()> {
    let store = Store::load()?;
    let machine = match query {
        Some(q) => match store.find(&q) {
            Some(machine) => machine.clone(),
            None => bail!("no paired Mac matches “{q}”. Pair it first: glassy-desk pair {q}"),
        },
        None => match store.machines.len() {
            0 => bail!("no paired Macs yet. Run: glassy-desk pair <mac-address>"),
            1 => store.machines[0].clone(),
            _ => {
                let mut machines = store.machines.clone();
                machines.sort_by_key(|m| std::cmp::Reverse(m.last_connected.unwrap_or(0)));
                let names: Vec<String> = machines.iter().map(|m| format!("{}  ({})", m.name, m.host)).collect();
                let index = choose("Connect to", &names)?;
                machines[index].clone()
            }
        },
    };
    let quality = view.quality.or(machine.quality).unwrap_or(Quality::Best);
    eprintln!("Connecting to {}…", machine.name);
    let (session, authenticated) = session::connect(resume_request(&machine, quality)?)?;
    let mut store = Store::load()?;
    save_authenticated(&mut store, &authenticated, machine.alternate_hosts.clone())?;
    view_machine(machine, session, authenticated, view)
}

fn resume_request(machine: &SavedMachine, quality: Quality) -> Result<ConnectRequest> {
    let credential = machine.credential().context("the saved credential is damaged; pair again")?;
    Ok(ConnectRequest {
        addresses: machine.addresses(),
        expected_host_id: Some(credential.host_id),
        bootstrap: None,
        credentials: vec![credential],
        client_name: session::client_name(),
        quality,
    })
}

fn view_machine(machine: SavedMachine, session: session::Session, authenticated: Authenticated, view: ViewArgs) -> Result<()> {
    let quality = view.quality.or(machine.quality).unwrap_or(Quality::Best);
    let options = viewer::Options {
        quality,
        prefer_hardware: !view.software_decode,
        keymap: keymap::Options { ctrl_as_command: view.ctrl_as_cmd },
        show_local_cursor: view.show_local_cursor,
        fullscreen: view.fullscreen,
        grab_keyboard: !view.no_keyboard_grab,
        invert_scroll: view.invert_scroll,
        scroll_speed: view.scroll_speed,
    };
    let host_id = authenticated.host_id;
    let alternates = machine.alternate_hosts.clone();
    viewer::run(
        session,
        authenticated,
        options,
        move |quality| {
            // Reload so a resume secret rotated by the previous session is used.
            let machine = Store::load()
                .ok()
                .and_then(|s| s.find_by_host_id(&host_id).cloned())
                .unwrap_or_else(|| machine.clone());
            resume_request(&machine, quality).unwrap_or_else(|_| ConnectRequest {
                addresses: machine.addresses(),
                expected_host_id: Some(host_id),
                bootstrap: None,
                credentials: vec![],
                client_name: session::client_name(),
                quality,
            })
        },
        move |authenticated| {
            if let Ok(mut store) = Store::load() {
                let _ = save_authenticated(&mut store, authenticated, alternates.clone());
            }
        },
        move |quality| {
            if let Ok(mut store) = Store::load() {
                if let Some(m) = store.machines.iter_mut().find(|m| store::decode_host_id(&m.host_id) == Some(host_id)) {
                    m.quality = Some(quality);
                    let _ = store.save();
                }
            }
        },
    )
}

fn save_authenticated(store: &mut Store, authenticated: &Authenticated, alternate_hosts: Vec<String>) -> Result<()> {
    let existing = store.find_by_host_id(&authenticated.host_id).cloned();
    store.upsert(SavedMachine {
        name: authenticated.host_name.clone(),
        host: authenticated.connected_host.clone(),
        port: authenticated.port,
        alternate_hosts: alternate_hosts.into_iter().filter(|h| *h != authenticated.connected_host).collect(),
        host_id: store::encode(&authenticated.host_id),
        client_id: store::encode(&authenticated.client_id),
        resume_secret: store::encode(&authenticated.resume_secret),
        quality: existing.and_then(|m| m.quality),
        last_connected: Some(store::now_seconds()),
    });
    if !authenticated.resumed {
        eprintln!("Saved a device credential for {}", authenticated.host_name);
    }
    store.save()
}

struct Invitation {
    addresses: Vec<(String, u16)>,
    code: String,
    host_id: Option<[u8; 16]>,
}

/// Parses the `glassydesk://pair?v=2&host=…&port=…&name=…&code=…&expires=…&id=…&alt=…`
/// link encoded in the Mac's pairing QR code.
fn parse_invitation(link: &str) -> Result<Invitation> {
    let query = link.strip_prefix("glassydesk://pair?").context("not a Glassy Desk pairing link")?;
    let mut host = None;
    let mut port = wire::DEFAULT_PORT;
    let mut code = None;
    let mut host_id = None;
    let mut alternates = Vec::new();
    for item in query.split('&') {
        let (key, value) = item.split_once('=').unwrap_or((item, ""));
        let value = percent_decode(value);
        match key {
            "host" => host = Some(value),
            "port" => port = value.parse().context("invalid port in pairing link")?,
            "code" => code = Some(value),
            "id" => host_id = store::decode_host_id(&value),
            "alt" => alternates.push(value),
            "expires" => {
                if value.parse::<u64>().is_ok_and(|expires| expires < store::now_seconds()) {
                    bail!("this pairing link has expired; use the current code on the Mac");
                }
            }
            _ => {}
        }
    }
    let host = host.context("pairing link has no host")?;
    Ok(Invitation {
        addresses: std::iter::once(host).chain(alternates).map(|h| (h, port)).collect(),
        code: code.context("pairing link has no code")?,
        host_id,
    })
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&value[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn split_host_port(value: &str) -> (String, u16) {
    let value = value.trim();
    // [v6]:port
    if let Some(rest) = value.strip_prefix('[') {
        if let Some((host, tail)) = rest.split_once(']') {
            let port = tail.strip_prefix(':').and_then(|p| p.parse().ok()).unwrap_or(wire::DEFAULT_PORT);
            return (host.to_string(), port);
        }
    }
    // host:port, but a bare IPv6 address has several colons.
    if value.matches(':').count() == 1 {
        if let Some((host, port)) = value.rsplit_once(':') {
            if let Ok(port) = port.parse() {
                return (host.to_string(), port);
            }
        }
    }
    (value.to_string(), wire::DEFAULT_PORT)
}

fn prompt(message: &str) -> Result<String> {
    if !std::io::stdin().is_terminal() {
        if let Some(answer) = dmenu(message.trim_end_matches([' ', ':']), &[], true)? {
            return Ok(answer);
        }
    }
    eprint!("{message}");
    std::io::stderr().flush()?;
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    Ok(line.trim().to_string())
}

/// Picks from a list: a terminal menu when interactive, otherwise the Omarchy
/// launcher (walker) or another dmenu-style tool.
fn choose(title: &str, items: &[String]) -> Result<usize> {
    if !std::io::stdin().is_terminal() {
        if let Some(answer) = dmenu(title, items, false)? {
            return items.iter().position(|i| *i == answer).context("nothing selected");
        }
        bail!("nothing selected");
    }
    for (i, item) in items.iter().enumerate() {
        eprintln!("  {}. {item}", i + 1);
    }
    let answer = prompt(&format!("{title} [1-{}]: ", items.len()))?;
    let index: usize = answer.parse().context("enter a number")?;
    if index == 0 || index > items.len() {
        bail!("choose between 1 and {}", items.len());
    }
    Ok(index - 1)
}

fn dmenu(title: &str, items: &[String], free_text: bool) -> Result<Option<String>> {
    use std::process::{Command, Stdio};
    // Omarchy's own shell menu (omarchy-shell) first.
    let omarchy = if free_text {
        Command::new("omarchy-menu-input").arg(title).stdin(Stdio::null()).output()
    } else {
        Command::new("omarchy-menu-select").arg(title).args(items).stdin(Stdio::null()).output()
    };
    if let Ok(output) = omarchy {
        let answer = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Ok((output.status.success() && !answer.is_empty()).then_some(answer));
    }
    let candidates: [(&str, Vec<String>); 3] = [
        ("walker", vec!["--dmenu".into(), "--placeholder".into(), title.into()]),
        ("fuzzel", vec!["--dmenu".into(), "--prompt".into(), format!("{title}: ")]),
        ("wofi", vec!["--dmenu".into(), "--prompt".into(), title.into()]),
    ];
    for (program, args) in candidates {
        let mut args = args;
        if free_text && program == "walker" {
            args.push("--inputonly".into());
        }
        let Ok(mut child) = Command::new(program).args(&args).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn()
        else {
            continue;
        };
        child.stdin.take().unwrap().write_all(items.join("\n").as_bytes())?;
        let output = child.wait_with_output()?;
        let answer = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Ok((!answer.is_empty()).then_some(answer));
    }
    Ok(None)
}

fn install_desktop() -> Result<()> {
    let exe = std::env::current_exe()?.canonicalize()?;
    let home = std::env::var("HOME").context("HOME is not set")?;
    let data = std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| format!("{home}/.local/share"));
    let dir = std::path::Path::new(&data).join("applications");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("dev.bunn.glassydesk.linux.desktop");
    std::fs::write(
        &path,
        format!(
            "[Desktop Entry]\nType=Application\nName=Glassy Desk\nGenericName=Mac Screen Sharing\nComment=Connect to Glassy Desk for Mac\nExec={} connect\nIcon=video-display\nTerminal=false\nCategories=Network;RemoteAccess;\nKeywords=mac;remote;screen;vnc;\nStartupWMClass=dev.bunn.glassydesk.linux\n",
            exe.display()
        ),
    )?;
    println!("Installed {}", path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_port_parsing() {
        assert_eq!(split_host_port("mac.local"), ("mac.local".into(), 51515));
        assert_eq!(split_host_port("10.0.0.2:6000"), ("10.0.0.2".into(), 6000));
        assert_eq!(split_host_port("fd7a:115c:a1e0::1"), ("fd7a:115c:a1e0::1".into(), 51515));
        assert_eq!(split_host_port("[fd7a::1]:7"), ("fd7a::1".into(), 7));
    }

    #[test]
    fn invitation_parsing() {
        let far_future = store::now_seconds() + 60;
        let link = format!(
            "glassydesk://pair?v=2&host=192.168.1.5&port=51515&name=My%20Mac&code=ABCDEFGHJK23&expires={far_future}&id=AAAAAAAAAAAAAAAAAAAAAA%3D%3D&alt=100.100.1.1"
        );
        let invitation = parse_invitation(&link).unwrap();
        assert_eq!(invitation.addresses.len(), 2);
        assert_eq!(invitation.code, "ABCDEFGHJK23");
        assert_eq!(invitation.host_id, Some([0u8; 16]));
    }
}
