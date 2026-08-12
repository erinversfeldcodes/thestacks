//! Reading a shop's sitemap, under a budget that keeps it polite.
//! Guessing paths costs the shop a full render per miss (a Shopify 404
//! measured ~250KB); the sitemap is declared in robots.txt (already
//! fetched for compliance), ~10KB, and states which pages exist. The walk
//! never descends into catalogue-sized child sitemaps, reports what it
//! skipped (so "found nothing" ≠ "declined to look"), and marks
//! `truncated` when the budget ended it early.

use std::time::Duration;

/// What kind of sitemap document this is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DocKind {
    /// `<sitemapindex>` — the `<loc>`s are other sitemaps.
    Index,
    /// `<urlset>` — the `<loc>`s are pages.
    UrlSet,
    /// Neither root element was found. Deliberately distinct from an empty document: "this is not a
    /// sitemap" (a bot-challenge page, an HTML 404, a redirect body) must not be mistaken for "this
    /// sitemap lists nothing", or a shop that never served us a sitemap gets recorded as having no
    /// pages.
    Unknown,
}

/// A parsed sitemap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SitemapDoc {
    pub kind: DocKind,
    /// Every `<loc>` value, in document order, de-duplicated.
    pub locs: Vec<String>,
}

/// Whether an index child is worth fetching when looking for editorial pages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChildKind {
    /// Names itself as pages. Fetch it.
    Page,
    /// Names itself as products, collections, blog posts, tags and so on. **Never fetch.** These are
    /// the enormous ones, and an events page is not in them.
    Excluded,
    /// Carries no type in its name (`/sitemap1.xml`). We cannot tell what it holds, so it is fetched
    /// only if budget allows and only after every `Page` child.
    Unlabelled,
}

/// Substrings that mark a child as *not* worth fetching. Checked before the page tokens, because a
/// name can contain both (`product-pages-sitemap.xml`) and in that case the expensive reading wins.
const EXCLUDED_TOKENS: &[&str] = &[
    "product",
    "collection",
    "blog",
    "post",
    "article",
    "category",
    "tag",
    "author",
    "brand",
    "vendor",
    "variant",
    "image",
    "video",
    "review",
    "attachment",
];

/// Substrings that mark a child as editorial pages. Shopify emits `sitemap_pages_1.xml`;
/// Yoast/WordPress emits `page-sitemap.xml`.
const PAGE_TOKENS: &[&str] = &["page"];

/// Sort an index child by whether it can plausibly contain an events page.
///
/// Compared case-insensitively against the whole URL rather than just its filename: some shops put
/// the type in a directory (`/sitemaps/pages/1.xml`).
pub fn classify_child(url: &str) -> ChildKind {
    let lower = url.to_ascii_lowercase();

    if EXCLUDED_TOKENS.iter().any(|t| lower.contains(t)) {
        return ChildKind::Excluded;
    }
    if PAGE_TOKENS.iter().any(|t| lower.contains(t)) {
        return ChildKind::Page;
    }
    ChildKind::Unlabelled
}

/// Extract the `<loc>` values and the document's kind.
///
/// Hand-rolled rather than pulling in an XML crate. Two reasons, and the second is the real one:
/// a sitemap's shape is a flat list of `<loc>` elements, and the `scraper` crate already in these
/// dependencies is an *HTML5* parser — pointing it at XML gets an HTML-coerced tree, which is a
/// subtler wrong than not parsing at all.
///
/// Handles the forms actually seen in the wild: attributes on the root element, `CDATA` sections,
/// XML entity escapes (a sitemap URL with a query string carries `&amp;`), and whitespace inside
/// the element.
pub fn parse(xml: &str) -> SitemapDoc {
    let kind = if xml.contains("<sitemapindex") {
        DocKind::Index
    } else if xml.contains("<urlset") {
        DocKind::UrlSet
    } else {
        DocKind::Unknown
    };

    let mut locs = Vec::new();
    let mut rest = xml;

    while let Some(open) = rest.find("<loc") {
        rest = &rest[open + 4..];

        let Some(gt) = rest.find('>') else { break };
        rest = &rest[gt + 1..];

        let Some(close) = rest.find("</loc>") else {
            break;
        };
        let raw = &rest[..close];
        rest = &rest[close + 6..];

        let value = unescape(strip_cdata(raw).trim());
        if !value.is_empty() && !locs.contains(&value) {
            locs.push(value);
        }
    }

    SitemapDoc { kind, locs }
}

fn strip_cdata(s: &str) -> &str {
    s.trim()
        .strip_prefix("<![CDATA[")
        .and_then(|inner| inner.strip_suffix("]]>"))
        .unwrap_or(s)
}

/// The five predefined XML entities. `&amp;` last is not stylistic — unescaping it first would turn
/// `&amp;lt;` into `&lt;` and then into `<`, inventing markup the document never contained.
fn unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

/// How much traffic one discovery run may cost a shop — a consumable
/// value, not a config constant: `sitemap_urls` cannot issue a request
/// without `spend`ing from it, so politeness is structural rather than
/// remembered at each call site. Caps both requests AND bytes — a request
/// cap alone bounds the wrong thing when one child sitemap can be tens of
/// megabytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CrawlBudget {
    requests_left: u32,
    bytes_left: u64,
}

/// What a budget said when asked for permission.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Spend {
    /// Go ahead, and read at most this many bytes.
    Allowed { byte_limit: u64 },
    /// Nothing left. The caller stops and reports what it already has.
    Exhausted,
}

impl CrawlBudget {
    /// The default allowance for one discovery run: an index, two page children, and change.
    ///
    /// 4 requests × 2 MB. For scale: the index we measured was 10 KB, so this is roughly 200× the
    /// expected cost of a successful run — generous enough that a legitimately chatty sitemap is not
    /// truncated, and small enough that the pathological case (a product sitemap reached through an
    /// unlabelled child) is hung up on long before it hurts.
    pub fn for_discovery() -> Self {
        Self {
            requests_left: 4,
            bytes_left: 8 * 1024 * 1024,
        }
    }

    pub fn new(requests: u32, bytes: u64) -> Self {
        Self {
            requests_left: requests,
            bytes_left: bytes,
        }
    }

    /// Ask for permission to make one request, and get the byte ceiling that comes with it.
    ///
    /// Decrements the request count on approval — the request is charged when it is *authorised*,
    /// not when it succeeds. A failed fetch still cost the shop the work of answering, so refunding
    /// it on error would turn a broken store into an unbounded retry loop.
    pub fn spend(&mut self) -> Spend {
        if self.requests_left == 0 || self.bytes_left == 0 {
            return Spend::Exhausted;
        }
        self.requests_left -= 1;
        Spend::Allowed {
            byte_limit: self.bytes_left,
        }
    }

    /// Record bytes actually transferred, saturating at zero.
    pub fn charge_bytes(&mut self, bytes: u64) {
        self.bytes_left = self.bytes_left.saturating_sub(bytes);
    }

    pub fn requests_left(&self) -> u32 {
        self.requests_left
    }

    pub fn bytes_left(&self) -> u64 {
        self.bytes_left
    }
}

/// How long to pause between the documents of one walk.
///
/// Separate from the per-domain rate limiter, which is a *ceiling* across all work. This is the
/// courtesy inside a single burst: three sitemap fetches issued back to back look exactly like the
/// beginning of a scrape to whatever bot protection sits in front of the shop, and is what
/// happens when it decides that is what we are.
pub const INTER_DOCUMENT_DELAY: Duration = Duration::from_millis(500);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_index_is_distinguished_from_a_urlset() {
        let index = r#"<?xml version="1.0"?>
            <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
              <sitemap><loc>https://shop.test/sitemap_pages_1.xml</loc></sitemap>
              <sitemap><loc>https://shop.test/sitemap_products_1.xml</loc></sitemap>
            </sitemapindex>"#;

        let doc = parse(index);
        assert_eq!(doc.kind, DocKind::Index);
        assert_eq!(
            doc.locs,
            vec![
                "https://shop.test/sitemap_pages_1.xml",
                "https://shop.test/sitemap_products_1.xml"
            ]
        );

        let urlset = r#"<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
              <url><loc>https://shop.test/pages/events</loc><lastmod>2026-07-01</lastmod></url>
            </urlset>"#;

        let doc = parse(urlset);
        assert_eq!(doc.kind, DocKind::UrlSet);
        assert_eq!(doc.locs, vec!["https://shop.test/pages/events"]);
    }

    #[test]
    fn a_document_that_is_not_a_sitemap_is_unknown_not_empty() {
        for not_a_sitemap in [
            "<!DOCTYPE html><html><head><title>Verifying your connection...</title></head></html>",
            "",
            "   ",
            "{\"error\":\"forbidden\"}",
        ] {
            assert_eq!(
                parse(not_a_sitemap).kind,
                DocKind::Unknown,
                "parsed as a sitemap: {not_a_sitemap:?}"
            );
        }
    }

    #[test]
    fn locs_survive_cdata_entities_attributes_and_whitespace() {
        let xml = r#"<sitemapindex>
              <sitemap><loc><![CDATA[https://shop.test/a.xml]]></loc></sitemap>
              <sitemap><loc>
                  https://shop.test/b.xml
              </loc></sitemap>
              <sitemap><loc>https://shop.test/c.xml?page=1&amp;lang=en</loc></sitemap>
              <sitemap><loc xml:lang="en">https://shop.test/d.xml</loc></sitemap>
            </sitemapindex>"#;

        assert_eq!(
            parse(xml).locs,
            vec![
                "https://shop.test/a.xml",
                "https://shop.test/b.xml",
                "https://shop.test/c.xml?page=1&lang=en",
                "https://shop.test/d.xml",
            ]
        );
    }

    #[test]
    fn amp_is_unescaped_last_so_no_markup_is_invented() {
        assert_eq!(unescape("&amp;lt;"), "&lt;");
        assert_eq!(unescape("a&amp;b"), "a&b");
    }

    #[test]
    fn duplicate_locs_are_reported_once() {
        let xml = "<sitemapindex><sitemap><loc>https://shop.test/a.xml</loc></sitemap>\
                   <sitemap><loc>https://shop.test/a.xml</loc></sitemap></sitemapindex>";
        assert_eq!(parse(xml).locs, vec!["https://shop.test/a.xml"]);
    }

    #[test]
    fn a_truncated_document_yields_what_it_had_rather_than_panicking() {
        let xml = "<sitemapindex><sitemap><loc>https://shop.test/a.xml</loc></sitemap>\
                   <sitemap><loc>https://shop.test/b.xm";
        let doc = parse(xml);
        assert_eq!(doc.kind, DocKind::Index);
        assert_eq!(doc.locs, vec!["https://shop.test/a.xml"]);
    }

    #[test]
    fn shopify_and_yoast_page_sitemaps_are_recognised() {
        for url in [
            "https://shop.test/sitemap_pages_1.xml",
            "https://shop.test/page-sitemap.xml",
            "https://shop.test/sitemaps/pages/1.xml",
            "https://shop.test/SITEMAP_PAGES_1.XML",
        ] {
            assert_eq!(
                classify_child(url),
                ChildKind::Page,
                "not recognised: {url}"
            );
        }
    }

    #[test]
    fn catalogue_sized_children_are_never_fetched() {
        for url in [
            "https://shop.test/sitemap_products_1.xml",
            "https://shop.test/product-sitemap.xml",
            "https://shop.test/sitemap_collections_1.xml",
            "https://shop.test/sitemap_blogs_1.xml",
            "https://shop.test/post-sitemap.xml",
            "https://shop.test/category-sitemap.xml",
            "https://shop.test/author-sitemap.xml",
        ] {
            assert_eq!(
                classify_child(url),
                ChildKind::Excluded,
                "would have been fetched: {url}"
            );
        }
    }

    #[test]
    fn an_ambiguous_name_is_excluded_rather_than_fetched() {
        assert_eq!(
            classify_child("https://shop.test/product-pages-sitemap.xml"),
            ChildKind::Excluded
        );
    }

    #[test]
    fn an_untyped_child_is_unlabelled_rather_than_assumed_either_way() {
        for url in [
            "https://shop.test/sitemap1.xml",
            "https://shop.test/sitemap.xml?p=2",
        ] {
            assert_eq!(
                classify_child(url),
                ChildKind::Unlabelled,
                "wrongly classified: {url}"
            );
        }
    }

    #[test]
    fn a_budget_stops_authorising_requests_when_spent() {
        let mut budget = CrawlBudget::new(2, 1_000);

        assert!(matches!(budget.spend(), Spend::Allowed { .. }));
        assert!(matches!(budget.spend(), Spend::Allowed { .. }));
        assert_eq!(
            budget.spend(),
            Spend::Exhausted,
            "a third request was authorised against a budget of two"
        );
    }

    #[test]
    fn spending_bytes_also_exhausts_the_budget() {
        let mut budget = CrawlBudget::new(10, 1_000);

        assert!(matches!(
            budget.spend(),
            Spend::Allowed { byte_limit: 1_000 }
        ));
        budget.charge_bytes(1_000);

        assert_eq!(budget.spend(), Spend::Exhausted);
        assert!(
            budget.requests_left() > 0,
            "the test proved nothing: it ran out of requests, not bytes"
        );
    }

    #[test]
    fn the_byte_limit_shrinks_as_the_walk_proceeds() {
        let mut budget = CrawlBudget::new(4, 1_000);

        assert!(matches!(
            budget.spend(),
            Spend::Allowed { byte_limit: 1_000 }
        ));
        budget.charge_bytes(600);
        assert!(matches!(budget.spend(), Spend::Allowed { byte_limit: 400 }));
    }

    #[test]
    fn overcharging_bytes_cannot_wrap_around() {
        let mut budget = CrawlBudget::new(4, 100);
        budget.charge_bytes(5_000);

        assert_eq!(budget.bytes_left(), 0);
        assert_eq!(budget.spend(), Spend::Exhausted);
    }

    #[test]
    fn a_charge_is_not_refunded_when_a_fetch_fails() {
        let mut budget = CrawlBudget::new(1, 10_000);
        let _ = budget.spend();
        assert_eq!(budget.requests_left(), 0);
        assert_eq!(budget.spend(), Spend::Exhausted);
    }
}
