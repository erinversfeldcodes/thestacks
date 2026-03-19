use crate::error::ScraperError;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

/// Maximum allowed age of an HMAC token in seconds.
const MAX_TOKEN_AGE_SECS: u64 = 60;

/// Validate an `X-Internal-Token` header value.
///
/// Token format: `<unix_timestamp>.<hex_signature>`
///
/// Signature is HMAC-SHA256 of `"<timestamp>.<method>.<path>"`.
///
/// Returns Ok(()) if valid, Err(ScraperError::AuthFailed) otherwise.
pub fn verify_token(
    token: &str,
    method: &str,
    path: &str,
    secret: &str,
) -> Result<(), ScraperError> {
    let parts: Vec<&str> = token.splitn(2, '.').collect();
    if parts.len() != 2 {
        return Err(ScraperError::AuthFailed(
            "malformed token: expected timestamp.signature".to_string(),
        ));
    }

    let timestamp_str = parts[0];
    let provided_hex = parts[1];

    let timestamp: u64 = timestamp_str
        .parse()
        .map_err(|_| ScraperError::AuthFailed("invalid timestamp".to_string()))?;

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ScraperError::AuthFailed("system clock error".to_string()))?
        .as_secs();

    if now.saturating_sub(timestamp) > MAX_TOKEN_AGE_SECS
        || timestamp.saturating_sub(now) > MAX_TOKEN_AGE_SECS
    {
        return Err(ScraperError::AuthFailed("token expired".to_string()));
    }

    let message = format!("{timestamp_str}.{method}.{path}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|_| ScraperError::AuthFailed("invalid secret key".to_string()))?;
    mac.update(message.as_bytes());
    let expected = hex::encode(mac.finalize().into_bytes());

    // Constant-time comparison.
    if !constant_time_eq(expected.as_bytes(), provided_hex.as_bytes()) {
        return Err(ScraperError::AuthFailed("signature mismatch".to_string()));
    }

    Ok(())
}

/// Generate a valid HMAC token for testing or client use.
pub fn generate_token(method: &str, path: &str, secret: &str) -> Result<String, ScraperError> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ScraperError::AuthFailed("system clock error".to_string()))?
        .as_secs();

    let message = format!("{timestamp}.{method}.{path}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|_| ScraperError::AuthFailed("invalid secret key".to_string()))?;
    mac.update(message.as_bytes());
    let sig = hex::encode(mac.finalize().into_bytes());

    Ok(format!("{timestamp}.{sig}"))
}

/// Constant-time byte comparison (avoids timing attacks).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut result = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        result |= x ^ y;
    }
    result == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "test-secret-key";

    #[test]
    fn test_valid_token_accepted() {
        let token = generate_token("POST", "/scrape", SECRET).unwrap();
        assert!(verify_token(&token, "POST", "/scrape", SECRET).is_ok());
    }

    #[test]
    fn test_wrong_path_rejected() {
        let token = generate_token("POST", "/scrape", SECRET).unwrap();
        let result = verify_token(&token, "POST", "/health", SECRET);
        assert!(result.is_err());
    }

    #[test]
    fn test_wrong_method_rejected() {
        let token = generate_token("POST", "/scrape", SECRET).unwrap();
        let result = verify_token(&token, "GET", "/scrape", SECRET);
        assert!(result.is_err());
    }

    #[test]
    fn test_wrong_secret_rejected() {
        let token = generate_token("POST", "/scrape", SECRET).unwrap();
        let result = verify_token(&token, "POST", "/scrape", "wrong-secret");
        assert!(result.is_err());
    }

    #[test]
    fn test_malformed_token_rejected() {
        assert!(verify_token("notokenformat", "POST", "/scrape", SECRET).is_err());
        assert!(verify_token("", "POST", "/scrape", SECRET).is_err());
    }

    #[test]
    fn test_expired_token_rejected() {
        // Manually craft a token with a timestamp 120 seconds in the past.
        let old_timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - 120;
        let message = format!("{old_timestamp}.POST./scrape");
        let mut mac = HmacSha256::new_from_slice(SECRET.as_bytes()).unwrap();
        mac.update(message.as_bytes());
        let sig = hex::encode(mac.finalize().into_bytes());
        let token = format!("{old_timestamp}.{sig}");

        let result = verify_token(&token, "POST", "/scrape", SECRET);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("expired"));
    }
}
