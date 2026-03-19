use crate::error::ScraperError;

/// A parsed price value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Price {
    /// Price in smallest currency unit (e.g. cents).
    pub cents: i64,
    pub currency: String,
}

/// Parse a price string into integer cents, asserting the expected currency.
///
/// Handles formats:
/// - `R 285.00`   → 28500 ZAR
/// - `R285`       → 28500 ZAR
/// - `R 1,285.00` → 128500 ZAR
/// - `ZAR 285.00` → 28500 ZAR
/// - `285.00`     → 28500 (bare number, no currency prefix)
///
/// Rejects strings that contain a different currency symbol.
pub fn parse_price(raw: &str, expected_currency: &str) -> Result<i64, ScraperError> {
    let s = raw.trim();

    // Strip known currency prefixes and validate they match expected_currency.
    let s = strip_currency_prefix(s, expected_currency)?;

    // Remove thousands separators (commas) and strip whitespace.
    let s = s.replace(',', "").trim().to_string();

    // Parse as f64 and convert to cents.
    let amount: f64 = s
        .parse()
        .map_err(|_| ScraperError::PriceParse(format!("cannot parse '{raw}' as a price number")))?;

    if amount < 0.0 {
        return Err(ScraperError::PriceParse(format!(
            "negative price '{raw}' is not valid"
        )));
    }

    // Round to nearest cent.
    Ok((amount * 100.0).round() as i64)
}

/// Strip the currency prefix from `s`, returning the bare numeric portion.
/// Returns an error if a different currency symbol is detected.
fn strip_currency_prefix<'a>(s: &'a str, expected_currency: &str) -> Result<&'a str, ScraperError> {
    // Map of known currency symbols/codes to their ISO codes.
    // Order matters: longer matches first.
    const KNOWN_CURRENCIES: &[(&str, &str)] = &[
        ("ZAR", "ZAR"),
        ("GBP", "GBP"),
        ("USD", "USD"),
        ("EUR", "EUR"),
        ("AUD", "AUD"),
        ("R", "ZAR"), // South African Rand shorthand
        ("£", "GBP"),
        ("$", "USD"),
        ("€", "EUR"),
    ];

    for (prefix, iso_code) in KNOWN_CURRENCIES {
        if let Some(stripped) = s.strip_prefix(prefix) {
            if *iso_code != expected_currency {
                return Err(ScraperError::PriceParse(format!(
                    "currency mismatch: got prefix '{prefix}' ({iso_code}) but expected {expected_currency}"
                )));
            }
            return Ok(stripped.trim_start());
        }
    }

    // No currency prefix found — treat as bare number.
    Ok(s)
}

/// Extract the price from an HTML snippet using a CSS selector.
pub fn extract_price(html: &str, selector: &str, currency: &str) -> Result<Price, ScraperError> {
    let document = scraper::Html::parse_fragment(html);
    let sel = scraper::Selector::parse(selector)
        .map_err(|e| ScraperError::SelectorParse(format!("{e:?}")))?;

    let text = document
        .select(&sel)
        .next()
        .map(|el| el.text().collect::<String>())
        .ok_or_else(|| ScraperError::PriceNotFound {
            selector: selector.to_string(),
        })?;

    let cents = parse_price(text.trim(), currency)?;
    Ok(Price {
        cents,
        currency: currency.to_string(),
    })
}

/// Extract a text value from HTML using a CSS selector. Returns None if not found.
pub fn extract_text(html: &str, selector: &str) -> Result<Option<String>, ScraperError> {
    let document = scraper::Html::parse_fragment(html);
    let sel = scraper::Selector::parse(selector)
        .map_err(|e| ScraperError::SelectorParse(format!("{e:?}")))?;

    Ok(document
        .select(&sel)
        .next()
        .map(|el| el.text().collect::<String>().trim().to_string()))
}

/// Extract a boolean stock status from HTML using a CSS selector.
/// Returns true if the element exists and does not contain known out-of-stock keywords.
pub fn extract_in_stock(html: &str, selector: &str) -> Result<Option<bool>, ScraperError> {
    match extract_text(html, selector)? {
        None => Ok(None),
        Some(text) => {
            let lower = text.to_lowercase();
            let out_of_stock = lower.contains("out of stock")
                || lower.contains("unavailable")
                || lower.contains("not available")
                || lower.contains("sold out");
            Ok(Some(!out_of_stock))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- parse_price ---

    #[test]
    fn test_parse_r_space_decimal() {
        assert_eq!(parse_price("R 285.00", "ZAR").unwrap(), 28500);
    }

    #[test]
    fn test_parse_r_no_space() {
        assert_eq!(parse_price("R285", "ZAR").unwrap(), 28500);
    }

    #[test]
    fn test_parse_r_thousands_separator() {
        assert_eq!(parse_price("R 1,285.00", "ZAR").unwrap(), 128500);
    }

    #[test]
    fn test_parse_zar_prefix() {
        assert_eq!(parse_price("ZAR 285.00", "ZAR").unwrap(), 28500);
    }

    #[test]
    fn test_parse_wrong_currency_errors() {
        assert!(parse_price("$25.00", "ZAR").is_err());
        assert!(parse_price("£25.00", "ZAR").is_err());
        assert!(parse_price("€25.00", "ZAR").is_err());
    }

    #[test]
    fn test_parse_bare_number() {
        assert_eq!(parse_price("149.99", "ZAR").unwrap(), 14999);
    }

    #[test]
    fn test_parse_zero() {
        assert_eq!(parse_price("R 0.00", "ZAR").unwrap(), 0);
    }

    #[test]
    fn test_parse_negative_errors() {
        assert!(parse_price("R -10.00", "ZAR").is_err());
    }

    #[test]
    fn test_parse_non_numeric_errors() {
        assert!(parse_price("R N/A", "ZAR").is_err());
        assert!(parse_price("price not available", "ZAR").is_err());
    }

    // --- extract_price from HTML ---

    #[test]
    fn test_extract_price_from_html() {
        let html = r#"<div class="product-price">R 285.00</div>"#;
        let price = extract_price(html, ".product-price", "ZAR").unwrap();
        assert_eq!(price.cents, 28500);
        assert_eq!(price.currency, "ZAR");
    }

    #[test]
    fn test_extract_price_missing_selector() {
        let html = r#"<div class="other">R 285.00</div>"#;
        let result = extract_price(html, ".product-price", "ZAR");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(matches!(err, ScraperError::PriceNotFound { .. }));
    }

    // --- extract_in_stock ---

    #[test]
    fn test_extract_in_stock_positive() {
        let html = r#"<span class="stock-status">In Stock</span>"#;
        assert_eq!(extract_in_stock(html, ".stock-status").unwrap(), Some(true));
    }

    #[test]
    fn test_extract_in_stock_negative() {
        let html = r#"<span class="stock-status">Out of Stock</span>"#;
        assert_eq!(
            extract_in_stock(html, ".stock-status").unwrap(),
            Some(false)
        );
    }

    #[test]
    fn test_extract_in_stock_missing() {
        let html = r#"<div class="other">foo</div>"#;
        assert_eq!(extract_in_stock(html, ".stock-status").unwrap(), None);
    }
}
