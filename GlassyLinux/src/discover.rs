//! Bonjour discovery of `_glassydesk._tcp` services on the local network.
//! Presence is only a hint: identity is proven by the authenticated handshake.

use anyhow::Result;
use mdns_sd::{ServiceDaemon, ServiceEvent};
use std::time::{Duration, Instant};

const SERVICE_TYPE: &str = "_glassydesk._tcp.local.";

pub struct DiscoveredHost {
    pub name: String,
    pub addresses: Vec<String>,
    pub port: u16,
}

pub fn browse(duration: Duration) -> Result<Vec<DiscoveredHost>> {
    let daemon = ServiceDaemon::new()?;
    let receiver = daemon.browse(SERVICE_TYPE)?;
    let deadline = Instant::now() + duration;
    let mut hosts: Vec<DiscoveredHost> = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        match receiver.recv_timeout(remaining) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                let name = info
                    .get_fullname()
                    .strip_suffix(&format!(".{SERVICE_TYPE}"))
                    .unwrap_or(info.get_fullname())
                    .replace("\\032", " ")
                    .replace("\\ ", " ");
                // Prefer IPv4 first; link-local IPv6 needs a scope id we do not keep.
                let mut addresses: Vec<std::net::IpAddr> = info.get_addresses().iter().copied().collect();
                addresses.retain(|a| match a {
                    std::net::IpAddr::V6(v6) => (v6.segments()[0] & 0xffc0) != 0xfe80,
                    _ => true,
                });
                addresses.sort_by_key(|a| a.is_ipv6());
                let addresses: Vec<String> = addresses.iter().map(|a| a.to_string()).collect();
                if addresses.is_empty() {
                    continue;
                }
                if let Some(existing) = hosts.iter_mut().find(|h| h.name == name) {
                    for a in addresses {
                        if !existing.addresses.contains(&a) {
                            existing.addresses.push(a);
                        }
                    }
                } else {
                    hosts.push(DiscoveredHost { name, addresses, port: info.get_port() });
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = daemon.shutdown();
    Ok(hosts)
}
