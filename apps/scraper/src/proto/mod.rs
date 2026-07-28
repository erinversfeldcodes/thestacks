pub mod generated;

#[cfg(test)]
mod tests {
    use super::generated::scraper::{ConfigReloadResponse, ScrapeRequest, ScrapeResponse};

    #[test]
    fn scrape_request_round_trip() {
        let req = ScrapeRequest {
            isbn: "9780679410232".to_string(),
            store: "za/loot".to_string(),
        };
        let json = serde_json::to_string(&req).unwrap();
        let decoded: ScrapeRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.isbn, req.isbn);
        assert_eq!(decoded.store, req.store);
    }

    #[test]
    fn scrape_response_optional_fields_omitted_when_none() {
        let resp = ScrapeResponse {
            isbn: "9780679410232".to_string(),
            store: "za/loot".to_string(),
            currency: "ZAR".to_string(),
            price_cents: None,
            in_stock: None,
            url: None,
            title: None,
            selector_match_rate: None,
            outcome: "SCRAPE_OUTCOME_NOT_STOCKED".to_string(),
            detail: None,
            capability: None,
        };
        let json = serde_json::to_string(&resp).unwrap();
        // Parse as Value so field-presence checks aren't fooled by substrings in
        // other field names (e.g. "cover_image_url" containing "url").
        let val: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(
            val.get("price_cents").is_none(),
            "None fields must be omitted"
        );
        assert!(val.get("in_stock").is_none(), "None fields must be omitted");
        assert!(val.get("url").is_none(), "None fields must be omitted");
    }

    #[test]
    fn scrape_response_optional_fields_round_trip_when_some() {
        let resp = ScrapeResponse {
            isbn: "9780679410232".to_string(),
            store: "za/loot".to_string(),
            currency: "ZAR".to_string(),
            price_cents: Some(29900),
            in_stock: Some(true),
            url: Some("https://example.com".to_string()),
            title: Some("The Book".to_string()),
            selector_match_rate: Some(0.95),
            outcome: "SCRAPE_OUTCOME_PRICED".to_string(),
            detail: Some("priced".to_string()),
            capability: None,
        };
        let json = serde_json::to_string(&resp).unwrap();
        let decoded: ScrapeResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.price_cents, Some(29900));
        assert_eq!(decoded.in_stock, Some(true));
        assert_eq!(decoded.url.as_deref(), Some("https://example.com"));
        assert!((decoded.selector_match_rate.unwrap() - 0.95).abs() < f64::EPSILON);
    }

    #[test]
    fn config_reload_response_round_trip() {
        let resp = ConfigReloadResponse { loaded: 7 };
        let json = serde_json::to_string(&resp).unwrap();
        let decoded: ConfigReloadResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.loaded, 7);
    }
}
