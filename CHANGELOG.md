# Changelog

All notable changes to The Stacks will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Visibility model and marketplace schema
- Linting toolchain and design documentation
- dbt staging layer with verified migrations
- CI test coverage for core data pipeline
- Reusable local validation scripts (replaces GH workflow gates)
- Automated issue creation and PR update tooling
- Protobuf schema contracts with `buf` lint/breaking checks
- Event-driven architecture via Oban (no external message broker)
- GDPR-by-default data classification (4-tier model)
- ISBN hard gate — no book enters the system without verified ISBN

---

[Unreleased]: https://github.com/erinversfeldcodes/thestacks/commits/main
