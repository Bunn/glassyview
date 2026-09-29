//! Saved Macs and their per-device resume credentials.
//!
//! Stored as JSON at `$XDG_DATA_HOME/glassy-desk/machines.json` (default
//! `~/.local/share/glassy-desk/machines.json`) with owner-only permissions,
//! mirroring Glassy Desk for Mac's ad-hoc fallback store. The one-time code and
//! pairing password are never saved; only the random, host-bound resume secret
//! the Mac issues after authentication.

use crate::wire::{Quality, DEFAULT_PORT, IDENTIFIER_LENGTH, RESUME_SECRET_LENGTH};
use anyhow::{Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SavedMachine {
    /// Display name reported by the Mac.
    pub name: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub alternate_hosts: Vec<String>,
    /// base64, 16 bytes. Connections to a different Mac are refused.
    pub host_id: String,
    /// base64, 16 bytes.
    pub client_id: String,
    /// base64, 32 bytes.
    pub resume_secret: String,
    #[serde(default)]
    pub quality: Option<Quality>,
    #[serde(default)]
    pub last_connected: Option<u64>,
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

#[derive(Clone)]
pub struct Credential {
    pub host_id: [u8; IDENTIFIER_LENGTH],
    pub client_id: [u8; IDENTIFIER_LENGTH],
    pub resume_secret: [u8; RESUME_SECRET_LENGTH],
}

impl SavedMachine {
    pub fn host_id_bytes(&self) -> Option<[u8; IDENTIFIER_LENGTH]> {
        B64.decode(&self.host_id).ok()?.try_into().ok()
    }

    pub fn credential(&self) -> Option<Credential> {
        Some(Credential {
            host_id: self.host_id_bytes()?,
            client_id: B64.decode(&self.client_id).ok()?.try_into().ok()?,
            resume_secret: B64.decode(&self.resume_secret).ok()?.try_into().ok()?,
        })
    }

    pub fn addresses(&self) -> Vec<(String, u16)> {
        std::iter::once(&self.host)
            .chain(self.alternate_hosts.iter())
            .map(|h| (h.clone(), self.port))
            .collect()
    }
}

#[derive(Default, Serialize, Deserialize)]
pub struct Store {
    #[serde(default)]
    pub machines: Vec<SavedMachine>,
}

fn store_path() -> Result<PathBuf> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .context("neither XDG_DATA_HOME nor HOME is set")?;
    Ok(base.join("glassy-desk").join("machines.json"))
}

impl Store {
    pub fn load() -> Result<Store> {
        let path = store_path()?;
        match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).with_context(|| format!("reading {}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Store::default()),
            Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = store_path()?;
        let dir = path.parent().unwrap();
        fs::create_dir_all(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        let tmp = path.with_extension("json.tmp");
        {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)?;
            file.write_all(&serde_json::to_vec_pretty(self)?)?;
            file.sync_all()?;
        }
        fs::rename(&tmp, &path)?;
        Ok(())
    }

    pub fn credentials(&self) -> Vec<Credential> {
        self.machines.iter().filter_map(SavedMachine::credential).collect()
    }

    /// Finds a machine by (case-insensitive) name, host, or unique name prefix.
    pub fn find(&self, query: &str) -> Option<&SavedMachine> {
        let q = query.to_lowercase();
        self.machines
            .iter()
            .find(|m| m.name.to_lowercase() == q || m.host.to_lowercase() == q)
            .or_else(|| {
                let mut matches = self.machines.iter().filter(|m| m.name.to_lowercase().starts_with(&q));
                let first = matches.next();
                if matches.next().is_some() { None } else { first }
            })
    }

    pub fn find_by_host_id(&self, host_id: &[u8]) -> Option<&SavedMachine> {
        self.machines.iter().find(|m| m.host_id_bytes().is_some_and(|id| id == host_id))
    }

    /// Inserts or updates the machine identified by its host identifier.
    pub fn upsert(&mut self, machine: SavedMachine) {
        if let Some(existing) = self.machines.iter_mut().find(|m| m.host_id == machine.host_id) {
            let quality = existing.quality;
            *existing = machine;
            existing.quality = existing.quality.or(quality);
        } else {
            self.machines.push(machine);
        }
    }

    pub fn remove(&mut self, query: &str) -> Option<SavedMachine> {
        let host_id = self.find(query)?.host_id.clone();
        let index = self.machines.iter().position(|m| m.host_id == host_id)?;
        Some(self.machines.remove(index))
    }
}

/// Marks a Mac as having an open viewer while this value lives, so
/// `glassy-desk status` (and the Omarchy bar widget) can show it as connected.
pub struct ActiveSession(PathBuf);

impl Drop for ActiveSession {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn runtime_dir() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir());
    base.join("glassy-desk")
}

fn active_path(host_id: &[u8]) -> PathBuf {
    let hex: String = host_id.iter().map(|b| format!("{b:02x}")).collect();
    runtime_dir().join(format!("{hex}.pid"))
}

pub fn mark_active(host_id: &[u8]) -> Option<ActiveSession> {
    let path = active_path(host_id);
    fs::create_dir_all(path.parent()?).ok()?;
    fs::write(&path, std::process::id().to_string()).ok()?;
    Some(ActiveSession(path))
}

/// The pid of a live viewer connected to this Mac, if any.
pub fn active_pid(host_id: &[u8]) -> Option<u32> {
    let path = active_path(host_id);
    let pid: u32 = fs::read_to_string(&path).ok()?.trim().parse().ok()?;
    let comm = fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
    if comm.trim() == "glassy-desk" {
        Some(pid)
    } else {
        let _ = fs::remove_file(&path); // stale marker from a crashed viewer
        None
    }
}

pub fn encode(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

pub fn decode_host_id(value: &str) -> Option<[u8; IDENTIFIER_LENGTH]> {
    B64.decode(value).ok()?.try_into().ok()
}

pub fn now_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
