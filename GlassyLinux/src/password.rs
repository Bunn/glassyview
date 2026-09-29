//! Client-side policy and key derivation for the optional reusable pairing
//! password. Keep every constant byte-for-byte aligned with
//! `dejaview/Services/GlassyStream/GlassyStreamPairingPassword.swift`.

use anyhow::{bail, Result};
use std::net::{IpAddr, Ipv6Addr};
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroize;

const MINIMUM_SCALAR_COUNT: usize = 15;
const MAXIMUM_SCALAR_COUNT: usize = 128;
const MAXIMUM_UTF8_BYTE_COUNT: usize = 512;
const ITERATION_COUNT: u32 = 600_000;
const SALT_DOMAIN: &[u8] = b"GlassyStream pairing password PBKDF2-SHA256 v1\0";

/// NFC-normalizes and validates the password without trimming or changing case.
pub fn validated(password: &str) -> Result<String> {
    let normalized: String = password.nfc().collect();
    let scalars = normalized.chars().count();
    if scalars < MINIMUM_SCALAR_COUNT {
        bail!("Use at least {MINIMUM_SCALAR_COUNT} characters.");
    }
    if scalars > MAXIMUM_SCALAR_COUNT {
        bail!("Use no more than {MAXIMUM_SCALAR_COUNT} characters.");
    }
    if normalized.len() > MAXIMUM_UTF8_BYTE_COUNT {
        bail!("Use a password no larger than {MAXIMUM_UTF8_BYTE_COUNT} UTF-8 bytes.");
    }
    // Foundation's controlCharacters covers Cc and Cf; newlines adds U+2028/2029.
    if normalized.chars().any(|c| c.is_control() || is_format(c) || c == '\u{2028}' || c == '\u{2029}') {
        bail!("Passwords cannot contain control characters or line breaks.");
    }
    Ok(normalized)
}

fn is_format(c: char) -> bool {
    matches!(c as u32,
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2 | 0x180E
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF
        | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3
        | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

pub fn derive_credential(password: &str, host_identifier: &[u8; 16]) -> Result<[u8; 32]> {
    let mut normalized = validated(password)?;
    let mut salt = SALT_DOMAIN.to_vec();
    salt.extend_from_slice(host_identifier);
    let mut credential = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(normalized.as_bytes(), &salt, ITERATION_COUNT, &mut credential);
    normalized.zeroize();
    Ok(credential)
}

/// Tailscale CGNAT IPv4 (100.64.0.0/10), Tailscale ULA IPv6
/// (fd7a:115c:a1e0::/48), or a full MagicDNS `.ts.net` name.
pub fn is_recognized_tailscale_host(host: &str) -> bool {
    let mut host = host.trim().to_lowercase();
    while host.ends_with('.') {
        host.pop();
    }
    if host.ends_with(".ts.net") && host.len() > ".ts.net".len() {
        return true;
    }
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    match bare.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => {
            let o = v4.octets();
            o[0] == 100 && (64..=127).contains(&o[1])
        }
        Ok(IpAddr::V6(v6)) => v6.octets()[..6] == Ipv6Addr::new(0xfd7a, 0x115c, 0xa1e0, 0, 0, 0, 0, 0).octets()[..6],
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tailscale_hosts() {
        assert!(is_recognized_tailscale_host("100.101.2.3"));
        assert!(!is_recognized_tailscale_host("100.128.0.1"));
        assert!(is_recognized_tailscale_host("mac.tail1234.ts.net."));
        assert!(is_recognized_tailscale_host("fd7a:115c:a1e0::1"));
        assert!(!is_recognized_tailscale_host("192.168.1.10"));
        assert!(!is_recognized_tailscale_host(".ts.net"));
    }

    /// Fixed vector from GlassyHost/Tests/GlassyHostTests/PairingPasswordTests.swift.
    #[test]
    fn matches_host_kdf_vector() {
        let host_identifier: [u8; 16] = std::array::from_fn(|i| i as u8);
        let credential = derive_credential("correct horse battery staple", &host_identifier).unwrap();
        let hex: String = credential.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "7860e2835faffc21a071c0b70458d3ec34e18527efcf7a06d2f902d5cb0b54f9");
    }

    #[test]
    fn nfc_normalization() {
        let id = [0x42u8; 16];
        assert_eq!(
            derive_credential("e\u{301}abcdefghijklmn", &id).unwrap(),
            derive_credential("éabcdefghijklmn", &id).unwrap()
        );
    }

    #[test]
    fn password_validation() {
        assert!(validated("short").is_err());
        assert!(validated("a perfectly long passphrase").is_ok());
        assert!(validated("a perfectly long\npassphrase").is_err());
    }
}
