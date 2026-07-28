//! Platform adapters for stores that expose a public product JSON API.
//!
//! Measured across the twelve owner-specified targets (2026-07-27): 6 are Shopify
//! and 2 are WooCommerce, so two adapters cover 8 of 10 reachable shops with no
//! HTML parsing and no CSS selectors at all. The remaining four have no usable
//! per-ISBN path at any price and are recorded as such rather than configured
//! hopefully.
//!
//! Everything here is a pure function over a JSON string. The HTTP orchestration
//! lives in the engine; keeping parsing separate is what makes the price-unit
//! traps below testable without a network.

use crate::error::ScraperError;
use serde_json::Value;

/// Which product API a store speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PriceSource {
    /// Shopify. `/products.json` for enumeration, `/products/<handle>.js` for a
    /// single product.
    ShopifyProductsJson,
    /// WooCommerce Store API: `/wp-json/wc/store/v1/products`.
    WooStoreApi,
    /// No usable product API. Recorded explicitly so the store stops being retried
    /// as though it were merely misconfigured.
    None,
}

/// Where a store keeps the ISBN on a product record. Measured per shop — there is
/// no convention across them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IsbnLocation {
    /// The product handle *is* the ISBN, so it can be addressed directly.
    /// (Exclusive Books: 50/50 sampled.)
    Handle,
    /// `variants[].sku` (Wordsworth 46/50, Stellenbosch 50/50, Bridge 49/50,
    /// Book Lounge 30/30).
    Sku,
    /// `variants[].barcode`.
    Barcode,
    /// Free-text description only (Clarke's: 35/50).
    Body,
    /// No ISBN anywhere in the sampled products (Ike's 0/50, Love Books 0/30).
    /// Fuzzy title+author matching is the only remaining path.
    None,
}

/// How a single ISBN can be turned into a product.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LookupMode {
    /// One request addresses the product by ISBN, and a 404 means "not stocked".
    /// Only possible when the handle is the ISBN.
    Direct,
    /// The platform's own search matches the ISBN. WooCommerce's Store API
    /// `?search=` matches `sku`; Shopify's storefront search does **not** — proven
    /// against four stores using ISBNs they demonstrably stock.
    NativeSearch,
    /// Neither: an ISBN→handle index has to be built locally first.
    LocalIndex,
}

/// A price extracted from a product payload.
#[derive(Debug, Clone, PartialEq)]
pub struct ProductPrice {
    pub price_cents: i64,
    pub currency: String,
    pub in_stock: Option<bool>,
    pub title: Option<String>,
    pub handle: Option<String>,
}

/// Parse a Shopify `/products/<handle>.js` payload.
///
/// ⚠️ **This endpoint reports price in integer cents.** `/products.json` reports
/// the same price as a decimal *string* (`"400.00"`). Confusing the two is a silent
/// 100× error in either direction, so they get separate functions rather than a
/// shared "parse a Shopify price" helper.
pub fn shopify_product_js(
    body: &str,
    default_currency: &str,
) -> Result<ProductPrice, ScraperError> {
    let root: Value = serde_json::from_str(body)
        .map_err(|e| ScraperError::PriceParse(format!("product.js is not JSON: {e}")))?;

    let variant = root
        .get("variants")
        .and_then(Value::as_array)
        .and_then(|v| v.first())
        .ok_or_else(|| ScraperError::PriceParse("product.js has no variants".to_string()))?;

    // Integer cents on this endpoint. Reject a string outright rather than trying
    // to be helpful: silently accepting "400.00" here would record R4.00.
    let price_cents = variant
        .get("price")
        .and_then(Value::as_i64)
        .ok_or_else(|| {
            ScraperError::PriceParse(
                "product.js variant price is not an integer (cents) — refusing to guess the unit"
                    .to_string(),
            )
        })?;

    Ok(ProductPrice {
        price_cents,
        currency: default_currency.to_string(),
        in_stock: variant.get("available").and_then(Value::as_bool),
        title: root
            .get("title")
            .and_then(Value::as_str)
            .map(str::to_string),
        handle: root
            .get("handle")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

/// One product from a Shopify `/products.json` listing.
#[derive(Debug, Clone, PartialEq)]
pub struct ShopifyListing {
    pub handle: String,
    pub title: String,
    /// Price in cents, converted from the decimal string this endpoint uses.
    pub price_cents: Option<i64>,
    pub sku: Option<String>,
    pub barcode: Option<String>,
    pub body: Option<String>,
}

/// Parse a Shopify `/products.json` page.
///
/// ⚠️ Price here is a **decimal string** (`"215.00"`), unlike `/products/<h>.js`.
pub fn shopify_products_json(body: &str) -> Result<Vec<ShopifyListing>, ScraperError> {
    let root: Value = serde_json::from_str(body)
        .map_err(|e| ScraperError::PriceParse(format!("products.json is not JSON: {e}")))?;

    let products = root
        .get("products")
        .and_then(Value::as_array)
        .ok_or_else(|| ScraperError::PriceParse("products.json has no products".to_string()))?;

    Ok(products
        .iter()
        .filter_map(|p| {
            let variant = p
                .get("variants")
                .and_then(Value::as_array)
                .and_then(|v| v.first());

            Some(ShopifyListing {
                handle: p.get("handle").and_then(Value::as_str)?.to_string(),
                title: p
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                price_cents: variant
                    .and_then(|v| v.get("price"))
                    .and_then(Value::as_str)
                    .and_then(decimal_string_to_cents),
                sku: variant
                    .and_then(|v| v.get("sku"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
                barcode: variant
                    .and_then(|v| v.get("barcode"))
                    .and_then(Value::as_str)
                    .map(str::to_string),
                body: p
                    .get("body_html")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect())
}

/// Parse a WooCommerce Store API product array (from `?search=<isbn>`).
///
/// ⚠️ Woo reports price as a **string of minor units** (`"24500"`) alongside
/// `currency_minor_unit`, so it needs neither multiplication nor division — but it
/// is a string, not a number. A documented upstream bug also omits
/// `currency_code` on some installs, hence the fallback.
///
/// Returns the entry whose `sku` matches `isbn` rather than "the first result":
/// a search can legitimately return several products.
pub fn woo_search(
    body: &str,
    isbn: &str,
    default_currency: &str,
) -> Result<Option<ProductPrice>, ScraperError> {
    let root: Value = serde_json::from_str(body)
        .map_err(|e| ScraperError::PriceParse(format!("Store API response is not JSON: {e}")))?;

    let products = root.as_array().ok_or_else(|| {
        ScraperError::PriceParse("Store API response is not an array".to_string())
    })?;

    let matched = products.iter().find(|p| {
        p.get("sku")
            .and_then(Value::as_str)
            .map(|sku| normalise_isbn(sku) == isbn)
            .unwrap_or(false)
    });

    let Some(product) = matched else {
        return Ok(None);
    };

    let prices = product
        .get("prices")
        .ok_or_else(|| ScraperError::PriceParse("Store API product has no prices".to_string()))?;

    let price_cents = prices
        .get("price")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<i64>().ok())
        .ok_or_else(|| {
            ScraperError::PriceParse("Store API price is not a minor-unit string".to_string())
        })?;

    Ok(Some(ProductPrice {
        price_cents,
        currency: prices
            .get("currency_code")
            .and_then(Value::as_str)
            .unwrap_or(default_currency)
            .to_string(),
        in_stock: product.get("is_in_stock").and_then(Value::as_bool),
        title: product
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string),
        handle: product
            .get("slug")
            .and_then(Value::as_str)
            .map(str::to_string),
    }))
}

/// Find an ISBN-13 on a Shopify listing, trying each location in order of how much
/// we can trust it. This ladder is per-shop because the conventions are: the handle
/// is the ISBN at Exclusive Books, `sku` carries it at three others, and Clarke's
/// only has it in prose.
pub fn isbn_from_listing(listing: &ShopifyListing) -> Option<(String, IsbnLocation)> {
    if let Some(isbn) = isbn13_in(&listing.handle) {
        return Some((isbn, IsbnLocation::Handle));
    }
    if let Some(isbn) = listing.barcode.as_deref().and_then(isbn13_in) {
        return Some((isbn, IsbnLocation::Barcode));
    }
    if let Some(isbn) = listing.sku.as_deref().and_then(isbn13_in) {
        return Some((isbn, IsbnLocation::Sku));
    }
    // Last and least trustworthy: free text may mention an ISBN that is not this
    // product's (a "see also", a box-set component).
    if let Some(isbn) = listing.body.as_deref().and_then(isbn13_in) {
        return Some((isbn, IsbnLocation::Body));
    }
    None
}

/// Whether a Shopify store addresses products by ISBN, judged from a sample.
///
/// Deliberately a ratio rather than "the first product matched": Bridge Books has
/// the ISBN in 37/50 handles but the handle is not *equal* to it, so a single
/// lucky hit would wrongly promise `LookupMode::Direct` and produce 404s.
pub fn handle_is_isbn_ratio(listings: &[ShopifyListing]) -> f64 {
    if listings.is_empty() {
        return 0.0;
    }

    let exact = listings
        .iter()
        .filter(|l| is_exact_isbn13(&l.handle))
        .count();

    exact as f64 / listings.len() as f64
}

/// What a store can do, as *observed* rather than configured.
///
/// Platform is deliberately not a config field. Bookshops replatform — WooCommerce
/// to Shopify, a theme change that moves the ISBN out of `sku` — and a stored
/// `platform = "shopify"` turns that into a silent outage indistinguishable from
/// "not stocked". Re-deriving means a replatform produces a new observation instead
/// of a stale config, and at worst one cycle of `PriceSource::None`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capability {
    pub price_source: PriceSource,
    pub isbn_location: IsbnLocation,
    pub lookup_mode: LookupMode,
}

impl PriceSource {
    /// Wire value. The proto documents these strings, so the mapping lives beside
    /// the enum rather than at the serialisation site.
    pub fn as_wire(self) -> &'static str {
        match self {
            PriceSource::ShopifyProductsJson => "shopify_products_json",
            PriceSource::WooStoreApi => "woo_store_api",
            PriceSource::None => "none",
        }
    }
}

impl IsbnLocation {
    pub fn as_wire(self) -> &'static str {
        match self {
            IsbnLocation::Handle => "handle",
            IsbnLocation::Sku => "sku",
            IsbnLocation::Barcode => "barcode",
            IsbnLocation::Body => "body",
            IsbnLocation::None => "none",
        }
    }
}

impl LookupMode {
    pub fn as_wire(self) -> &'static str {
        match self {
            LookupMode::Direct => "direct",
            LookupMode::NativeSearch => "native_search",
            LookupMode::LocalIndex => "local_index",
        }
    }
}

impl Capability {
    /// Nothing usable. Recorded as a fact about the store, not treated as a
    /// misconfiguration to retry forever.
    pub fn none() -> Self {
        Self {
            price_source: PriceSource::None,
            isbn_location: IsbnLocation::None,
            lookup_mode: LookupMode::LocalIndex,
        }
    }
}

/// Classify a Shopify store from a sample of its catalogue.
///
/// `handle_is_isbn_threshold` is a ratio, not a single hit: Bridge Books carries an
/// ISBN inside 37/50 handles without the handle *being* one, and one lucky match
/// would wrongly promise `Direct` — producing 404s for every lookup.
pub fn classify_shopify(listings: &[ShopifyListing]) -> Capability {
    if listings.is_empty() {
        return Capability::none();
    }

    // 0.9 rather than 1.0: a single oddly-named product should not demote a store
    // that is otherwise addressable by ISBN.
    let direct = handle_is_isbn_ratio(listings) >= 0.9;

    // Where the ISBN most often lives, across the sample. Counting beats trusting
    // the first product, since coverage is partial almost everywhere (Clarke's has
    // one in 35/50 bodies; Wordsworth in 46/50 skus).
    let found_at = |loc: IsbnLocation| {
        listings
            .iter()
            .filter(|l| isbn_from_listing(l).map(|(_, at)| at == loc) == Some(true))
            .count()
    };

    let location = [
        IsbnLocation::Handle,
        IsbnLocation::Barcode,
        IsbnLocation::Sku,
        IsbnLocation::Body,
    ]
    .into_iter()
    .map(|loc| (loc, found_at(loc)))
    .filter(|(_, n)| *n > 0)
    .max_by_key(|(_, n)| *n)
    .map(|(loc, _)| loc)
    .unwrap_or(IsbnLocation::None);

    Capability {
        price_source: PriceSource::ShopifyProductsJson,
        isbn_location: location,
        // Only a handle that *is* the ISBN allows a stateless per-ISBN request.
        // Everything else needs a local ISBN→handle index first, including the case
        // where no ISBN is present at all — there the index cannot be built either,
        // and fuzzy title matching takes over further up the stack.
        lookup_mode: if direct {
            LookupMode::Direct
        } else {
            LookupMode::LocalIndex
        },
    }
}

/// Classify a WooCommerce store. Its Store API `?search=` matches `sku`, which is
/// why Woo can do a stateless per-ISBN lookup where Shopify cannot.
pub fn classify_woo(sample: &str) -> Capability {
    let has_isbn_skus = serde_json::from_str::<Value>(sample)
        .ok()
        .and_then(|v| v.as_array().cloned())
        .map(|products| {
            products.iter().any(|p| {
                p.get("sku")
                    .and_then(Value::as_str)
                    .map(|s| is_exact_isbn13(&normalise_isbn(s)))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false);

    if has_isbn_skus {
        Capability {
            price_source: PriceSource::WooStoreApi,
            isbn_location: IsbnLocation::Sku,
            lookup_mode: LookupMode::NativeSearch,
        }
    } else {
        // The API works but its products carry no ISBN, so we cannot ask it for one.
        // Love Books measured 0/30.
        Capability {
            price_source: PriceSource::WooStoreApi,
            isbn_location: IsbnLocation::None,
            lookup_mode: LookupMode::LocalIndex,
        }
    }
}

/// Convert a decimal price string (`"215.00"`, `"215"`, `"215.5"`) to cents.
fn decimal_string_to_cents(s: &str) -> Option<i64> {
    let trimmed = s.trim();
    let (whole, frac) = match trimmed.split_once('.') {
        Some((w, f)) => (w, f),
        None => (trimmed, ""),
    };

    let whole: i64 = whole.parse().ok()?;
    // Pad or truncate to exactly two decimal places. "215.5" is 21550, not 21505.
    let cents: i64 = match frac.len() {
        0 => 0,
        1 => frac.parse::<i64>().ok()? * 10,
        _ => frac[..2].parse().ok()?,
    };

    Some(whole * 100 + cents)
}

/// Digits only, so hyphenated ISBNs compare equal.
fn normalise_isbn(s: &str) -> String {
    s.chars().filter(char::is_ascii_digit).collect()
}

/// Whether `s` is *exactly* an ISBN-13 and nothing else.
///
/// Deliberately does NOT strip separators, unlike [`normalise_isbn`]. A handle
/// like `"some-title-9781049281483-paperback"` normalises to exactly those 13
/// digits, so a stripping comparison would call it addressable-by-ISBN — and
/// `/products/9781049281483.js` then 404s, which is what Bridge Books actually
/// returned. Hyphen-stripping is right for comparing SKU *values*; it is wrong for
/// deciding whether a URL segment equals an ISBN.
fn is_exact_isbn13(s: &str) -> bool {
    s.len() == 13
        && s.bytes().all(|b| b.is_ascii_digit())
        && (s.starts_with("978") || s.starts_with("979"))
}

/// First ISBN-13-shaped run of digits in a string.
fn isbn13_in(s: &str) -> Option<String> {
    let digits: Vec<char> = s.chars().filter(char::is_ascii_digit).collect();

    digits.windows(13).find_map(|w| {
        let candidate: String = w.iter().collect();
        if candidate.starts_with("978") || candidate.starts_with("979") {
            Some(candidate)
        } else {
            None
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // Shaped after the real payloads measured on 2026-07-27.
    const EB_PRODUCT_JS: &str = r#"{
      "id": 1, "title": "Name of the Rose", "handle": "9780749397050",
      "variants": [{"id": 2, "price": 40000, "sku": "9780749397050",
                    "barcode": null, "available": true}]
    }"#;

    const WORDSWORTH_PRODUCTS_JSON: &str = r#"{
      "products": [
        {"handle": "peter-rabbit-book", "title": "Peter Rabbit",
         "body_html": "<p>A classic.</p>",
         "variants": [{"price": "215.00", "sku": "9780723263661", "barcode": null}]},
        {"handle": "another-title", "title": "Another",
         "body_html": "<p>ISBN 9780099590088 mentioned in prose.</p>",
         "variants": [{"price": "215.5", "sku": null, "barcode": null}]}
      ]
    }"#;

    const BOOKLOUNGE_SEARCH: &str = r#"[
      {"id": 9, "name": "Crow: Thief of Magic", "slug": "crow-thief",
       "sku": "9780008717360", "is_in_stock": true,
       "prices": {"price": "24500", "currency_code": "ZAR", "currency_minor_unit": 2}}
    ]"#;

    #[test]
    fn shopify_product_js_reads_integer_cents() {
        let p = shopify_product_js(EB_PRODUCT_JS, "ZAR").unwrap();
        assert_eq!(p.price_cents, 40_000, "R400.00 as integer cents");
        assert_eq!(p.in_stock, Some(true));
        assert_eq!(p.title.as_deref(), Some("Name of the Rose"));
        assert_eq!(p.handle.as_deref(), Some("9780749397050"));
    }

    #[test]
    fn shopify_product_js_refuses_any_string_price_even_a_numeric_one() {
        // The trap: /products.json reports the same price as a decimal string
        // ("400.00") that /products/<h>.js reports as the integer 40000. A *string*
        // price means we are looking at the other endpoint's payload, so the unit is
        // unknown and must not be guessed.
        //
        // Note "400.00" alone does not test this — it fails an integer parse anyway,
        // so a permissive implementation rejects it too and the assertion is
        // vacuous. A numeric string is what discriminates.
        for price in [r#""40000""#, r#""400.00""#, "null", "true"] {
            let body = format!(r#"{{"title":"X","handle":"h","variants":[{{"price":{price}}}]}}"#);

            let err = shopify_product_js(&body, "ZAR")
                .expect_err(&format!("price {price} should have been refused"));

            assert!(
                matches!(err, ScraperError::PriceParse(_)),
                "expected a parse error for {price}, got {err:?}"
            );
        }

        // ...and the integer form is accepted.
        let ok = shopify_product_js(
            r#"{"title":"X","handle":"h","variants":[{"price":40000}]}"#,
            "ZAR",
        )
        .unwrap();
        assert_eq!(ok.price_cents, 40_000);
    }

    #[test]
    fn shopify_products_json_converts_decimal_strings() {
        let listings = shopify_products_json(WORDSWORTH_PRODUCTS_JSON).unwrap();
        assert_eq!(listings.len(), 2);
        assert_eq!(listings[0].price_cents, Some(21_500), "\"215.00\" → 21500");
        // One decimal place must pad, not truncate: 215.5 is R215.50.
        assert_eq!(listings[1].price_cents, Some(21_550), "\"215.5\" → 21550");
    }

    #[test]
    fn isbn_ladder_prefers_sku_over_prose() {
        let listings = shopify_products_json(WORDSWORTH_PRODUCTS_JSON).unwrap();

        assert_eq!(
            isbn_from_listing(&listings[0]),
            Some(("9780723263661".to_string(), IsbnLocation::Sku))
        );

        // Only prose carries one here — accepted, but as the least trusted rung.
        assert_eq!(
            isbn_from_listing(&listings[1]),
            Some(("9780099590088".to_string(), IsbnLocation::Body))
        );
    }

    #[test]
    fn isbn_ladder_prefers_the_handle_when_it_is_the_isbn() {
        let listing = ShopifyListing {
            handle: "9780749397050".to_string(),
            title: "Name of the Rose".to_string(),
            price_cents: Some(40_000),
            sku: Some("9788497592581".to_string()),
            barcode: None,
            body: None,
        };

        // Handle wins over a (here deliberately different) sku.
        assert_eq!(
            isbn_from_listing(&listing),
            Some(("9780749397050".to_string(), IsbnLocation::Handle))
        );
    }

    #[test]
    fn handle_is_isbn_requires_the_whole_handle_not_a_substring() {
        // Bridge Books has an ISBN *inside* 37/50 handles without the handle being
        // the ISBN. Treating that as addressable-by-ISBN yields 404s — measured:
        // /products/9781049281483.js returned 404 there.
        let embedded = ShopifyListing {
            handle: "some-title-9781049281483-paperback".to_string(),
            title: "T".to_string(),
            price_cents: None,
            sku: None,
            barcode: None,
            body: None,
        };
        let exact = ShopifyListing {
            handle: "9780749397050".to_string(),
            ..embedded.clone()
        };

        assert_eq!(handle_is_isbn_ratio(std::slice::from_ref(&embedded)), 0.0);
        assert_eq!(handle_is_isbn_ratio(std::slice::from_ref(&exact)), 1.0);
        assert_eq!(handle_is_isbn_ratio(&[exact, embedded]), 0.5);
        assert_eq!(handle_is_isbn_ratio(&[]), 0.0);

        // ...but the ISBN is still extractable from that handle for indexing.
        let listing = ShopifyListing {
            handle: "some-title-9781049281483-paperback".to_string(),
            title: "T".to_string(),
            price_cents: None,
            sku: None,
            barcode: None,
            body: None,
        };
        assert_eq!(
            isbn_from_listing(&listing),
            Some(("9781049281483".to_string(), IsbnLocation::Handle))
        );
    }

    #[test]
    fn woo_reads_minor_unit_strings() {
        let p = woo_search(BOOKLOUNGE_SEARCH, "9780008717360", "ZAR")
            .unwrap()
            .expect("sku matches");
        assert_eq!(p.price_cents, 24_500, "\"24500\" is already cents");
        assert_eq!(p.currency, "ZAR");
        assert_eq!(p.in_stock, Some(true));
    }

    #[test]
    fn woo_matches_the_requested_isbn_not_merely_the_first_result() {
        // A search can return several products; taking [0] would attribute one
        // book's price to another.
        let body = r#"[
          {"name":"Wrong Book","sku":"9789999999999","is_in_stock":true,
           "prices":{"price":"9900","currency_code":"ZAR"}},
          {"name":"Right Book","sku":"9780008717360","is_in_stock":true,
           "prices":{"price":"24500","currency_code":"ZAR"}}
        ]"#;

        let p = woo_search(body, "9780008717360", "ZAR").unwrap().unwrap();
        assert_eq!(p.price_cents, 24_500);
        assert_eq!(p.title.as_deref(), Some("Right Book"));
    }

    #[test]
    fn woo_reports_no_match_rather_than_an_error() {
        // "This shop does not carry this ISBN" is an answer, not a failure — the
        // caller turns it into NOT_STOCKED.
        assert_eq!(
            woo_search(BOOKLOUNGE_SEARCH, "9789999999999", "ZAR").unwrap(),
            None
        );
    }

    #[test]
    fn woo_falls_back_when_currency_code_is_missing() {
        // Documented upstream WooCommerce bug (open issue, May 2025).
        let body = r#"[{"name":"X","sku":"9780008717360","prices":{"price":"1000"}}]"#;
        let p = woo_search(body, "9780008717360", "ZAR").unwrap().unwrap();
        assert_eq!(p.currency, "ZAR");
    }

    #[test]
    fn hyphenated_skus_still_match() {
        let body = r#"[{"name":"X","sku":"978-0-00-871736-0",
                        "prices":{"price":"1000","currency_code":"ZAR"}}]"#;
        assert!(woo_search(body, "9780008717360", "ZAR").unwrap().is_some());
    }

    #[test]
    fn classify_shopify_promises_direct_only_when_handles_are_isbns() {
        // Exclusive Books: handle == sku == ISBN on 50/50 sampled products, and
        // /products/<isbn>.js returned 200. Direct lookup is available, and a 404
        // there means "not stocked".
        let eb: Vec<_> = (0..10)
            .map(|i| ShopifyListing {
                handle: format!("978074939705{i}"),
                title: "T".to_string(),
                price_cents: Some(40_000),
                sku: Some(format!("978074939705{i}")),
                barcode: None,
                body: None,
            })
            .collect();

        let cap = classify_shopify(&eb);
        assert_eq!(cap.price_source, PriceSource::ShopifyProductsJson);
        assert_eq!(cap.isbn_location, IsbnLocation::Handle);
        assert_eq!(cap.lookup_mode, LookupMode::Direct);
    }

    #[test]
    fn classify_shopify_demands_an_index_when_the_isbn_only_lives_in_sku() {
        // Wordsworth / Stellenbosch: sku carries it, handle does not. Promising
        // Direct here would 404 on every lookup — measured.
        let sku_only: Vec<_> = (0..10)
            .map(|i| ShopifyListing {
                handle: format!("some-book-title-{i}"),
                title: "T".to_string(),
                price_cents: Some(21_500),
                sku: Some(format!("978072326366{i}")),
                barcode: None,
                body: None,
            })
            .collect();

        let cap = classify_shopify(&sku_only);
        assert_eq!(cap.isbn_location, IsbnLocation::Sku);
        assert_eq!(cap.lookup_mode, LookupMode::LocalIndex);
    }

    #[test]
    fn classify_shopify_reports_none_when_no_product_carries_an_isbn() {
        // Ike's Books: 0/50 sampled products had an ISBN anywhere. Recording that as
        // a fact stops it being retried as a misconfiguration.
        let no_isbn: Vec<_> = (0..5)
            .map(|i| ShopifyListing {
                handle: format!("second-hand-find-{i}"),
                title: "Some Old Book".to_string(),
                price_cents: Some(18_000),
                sku: None,
                barcode: None,
                body: Some("<p>A lovely used copy.</p>".to_string()),
            })
            .collect();

        let cap = classify_shopify(&no_isbn);
        assert_eq!(cap.isbn_location, IsbnLocation::None);
        assert_eq!(cap.lookup_mode, LookupMode::LocalIndex);
    }

    #[test]
    fn classify_shopify_prefers_the_location_that_covers_most_products() {
        // Coverage is partial nearly everywhere, so the winner is the most common
        // location rather than whichever the first product happened to use.
        let mut listings = vec![ShopifyListing {
            handle: "odd-one-out".to_string(),
            title: "T".to_string(),
            price_cents: None,
            sku: None,
            barcode: None,
            body: Some("ISBN 9780099590088".to_string()),
        }];

        for i in 0..5 {
            listings.push(ShopifyListing {
                handle: format!("title-{i}"),
                title: "T".to_string(),
                price_cents: None,
                sku: Some(format!("978072326366{i}")),
                barcode: None,
                body: None,
            });
        }

        assert_eq!(classify_shopify(&listings).isbn_location, IsbnLocation::Sku);
    }

    #[test]
    fn classify_shopify_reports_nothing_usable_for_an_empty_catalogue() {
        assert_eq!(classify_shopify(&[]), Capability::none());
    }

    #[test]
    fn classify_woo_uses_native_search_when_skus_are_isbns() {
        // Book Lounge: sku is an ISBN on 30/30, and ?search=<isbn> returned exactly
        // one correct hit. No local index needed.
        let cap = classify_woo(BOOKLOUNGE_SEARCH);
        assert_eq!(cap.price_source, PriceSource::WooStoreApi);
        assert_eq!(cap.isbn_location, IsbnLocation::Sku);
        assert_eq!(cap.lookup_mode, LookupMode::NativeSearch);
    }

    #[test]
    fn classify_woo_cannot_search_by_isbn_when_skus_are_not_isbns() {
        // Love Books: the Store API works but 0/30 skus were ISBNs, so there is
        // nothing to search by.
        let body = r#"[{"name":"X","sku":"LB-00123","prices":{"price":"1000"}}]"#;
        let cap = classify_woo(body);
        assert_eq!(cap.price_source, PriceSource::WooStoreApi);
        assert_eq!(cap.isbn_location, IsbnLocation::None);
        assert_eq!(cap.lookup_mode, LookupMode::LocalIndex);
    }

    #[test]
    fn decimal_conversion_edge_cases() {
        assert_eq!(decimal_string_to_cents("215.00"), Some(21_500));
        assert_eq!(decimal_string_to_cents("215"), Some(21_500));
        assert_eq!(decimal_string_to_cents("215.5"), Some(21_550));
        assert_eq!(decimal_string_to_cents("215.567"), Some(21_556));
        assert_eq!(decimal_string_to_cents("0.99"), Some(99));
        assert_eq!(decimal_string_to_cents("not a price"), None);
    }
}
