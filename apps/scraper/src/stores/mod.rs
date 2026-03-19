use crate::config::ScraperConfig;
use crate::error::ScraperError;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, RwLock};

/// Registry of loaded store configurations, keyed by store ID.
///
/// Store ID is derived from the TOML file path relative to the scrapers root,
/// e.g. `za/exclusive_books` for `scrapers/za/exclusive_books.toml`.
#[derive(Debug, Clone)]
pub struct StoreRegistry {
    inner: Arc<RwLock<HashMap<String, ScraperConfig>>>,
}

impl StoreRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Load all TOML configs from `scrapers_dir` (recursive).
    /// Returns the count of successfully loaded configs.
    pub fn load_from_dir(&self, scrapers_dir: &Path) -> Result<usize, ScraperError> {
        let mut loaded = 0;
        self.load_dir_recursive(scrapers_dir, scrapers_dir, &mut loaded)?;
        Ok(loaded)
    }

    fn load_dir_recursive(
        &self,
        base: &Path,
        dir: &Path,
        count: &mut usize,
    ) -> Result<(), ScraperError> {
        let entries = std::fs::read_dir(dir)?;
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                self.load_dir_recursive(base, &path, count)?;
            } else if path.extension().and_then(|e| e.to_str()) == Some("toml") {
                let store_id = self.path_to_store_id(base, &path);
                match ScraperConfig::from_file(&path) {
                    Ok(config) => {
                        self.insert(store_id, config);
                        *count += 1;
                    }
                    Err(e) => {
                        tracing::warn!("skipping invalid config {:?}: {}", path, e);
                    }
                }
            }
        }
        Ok(())
    }

    fn path_to_store_id(&self, base: &Path, path: &Path) -> String {
        path.strip_prefix(base)
            .unwrap_or(path)
            .with_extension("")
            .to_string_lossy()
            .replace('\\', "/") // normalise on Windows
    }

    /// Insert or replace a store config by ID.
    pub fn insert(&self, id: String, config: ScraperConfig) {
        let mut guard = self.inner.write().expect("RwLock poisoned");
        guard.insert(id, config);
    }

    /// Get a store config by ID.
    pub fn get(&self, id: &str) -> Result<ScraperConfig, ScraperError> {
        let guard = self.inner.read().expect("RwLock poisoned");
        guard
            .get(id)
            .cloned()
            .ok_or_else(|| ScraperError::StoreNotFound(id.to_string()))
    }

    /// List all known store IDs.
    pub fn store_ids(&self) -> Vec<String> {
        let guard = self.inner.read().expect("RwLock poisoned");
        guard.keys().cloned().collect()
    }

    /// Return all store configs as a vector of (id, config) pairs.
    pub fn all(&self) -> Vec<(String, ScraperConfig)> {
        let guard = self.inner.read().expect("RwLock poisoned");
        guard.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
    }
}

impl Default for StoreRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn write_valid_toml(dir: &Path, filename: &str) {
        let content = r#"
[source]
name = "Test Store"
country = "ZA"
url = "https://example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"
currency = "ZAR"

[rate_limit]
requests_per_minute = 10
"#;
        std::fs::write(dir.join(filename), content).unwrap();
    }

    #[test]
    fn test_load_from_dir_counts_configs() {
        let tmp = TempDir::new().unwrap();
        let za_dir = tmp.path().join("za");
        std::fs::create_dir_all(&za_dir).unwrap();
        write_valid_toml(&za_dir, "store_a.toml");
        write_valid_toml(&za_dir, "store_b.toml");

        let registry = StoreRegistry::new();
        let count = registry.load_from_dir(tmp.path()).unwrap();
        assert_eq!(count, 2);
    }

    #[test]
    fn test_get_known_store() {
        let registry = StoreRegistry::new();
        let config = ScraperConfig::from_toml_str(
            r#"
[source]
name = "My Store"
country = "ZA"
url = "https://example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"

[rate_limit]
requests_per_minute = 5
"#,
        )
        .unwrap();
        registry.insert("za/my_store".to_string(), config);
        assert!(registry.get("za/my_store").is_ok());
    }

    #[test]
    fn test_get_unknown_store_errors() {
        let registry = StoreRegistry::new();
        let result = registry.get("za/nonexistent");
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            ScraperError::StoreNotFound(_)
        ));
    }

    #[test]
    fn test_load_skips_invalid_toml() {
        let tmp = TempDir::new().unwrap();
        std::fs::write(tmp.path().join("bad.toml"), "this is not valid toml = = =").unwrap();
        write_valid_toml(tmp.path(), "good.toml");

        let registry = StoreRegistry::new();
        let count = registry.load_from_dir(tmp.path()).unwrap();
        // Only the valid one is counted; invalid is skipped with a warning.
        assert_eq!(count, 1);
    }
}
