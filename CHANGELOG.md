# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.13.0] - Unreleased

### Breaking

- Require Elixir 1.17 or newer (previously 1.10).
- Allow `httpoison ~> 3.0` (hackney 4.x), which fixes several hackney security
  advisories ([#70](https://github.com/keepcosmos/readability/pull/70)).
  httpoison 3 requires OTP 27+. Hex does not take your OTP version into account
  when resolving dependencies, so on OTP 26 or older pin it in your own project:
  `{:httpoison, "~> 2.0"}`.

- Require `floki ~> 0.30`. The previous `~> 0.24` floor did not compile, since
  `Floki.parse_fragment!/1` does not exist in older versions.

### Added

- `published_at` field in the summary returned by `Readability.summarize/2`, and `Readability.published_at/1`
  ([#58](https://github.com/keepcosmos/readability/pull/58)).

### Fixed

- `Readability.title/1` and `Readability.published_at/1` now accept raw HTML
  strings ([#60](https://github.com/keepcosmos/readability/pull/60)).
- Incorrect node format for the doctype when Floki uses the `html5ever` parser
  ([#66](https://github.com/keepcosmos/readability/pull/66)).
- Regex escape errors on Elixir 1.18 ([#69](https://github.com/keepcosmos/readability/pull/69)).

### Changed

- The Hex package no longer bundles locally generated `doc/` files.
- Updated development dependencies and CI (Elixir 1.17–1.20, OTP 27–29).

## [0.12.1] - 2024-01-11

### Changed

- The default title selector is now `h1`.

## [0.12.0] - 2023-12-13

### Changed

- Up to 100x faster on large pages by caching queries ([#53](https://github.com/keepcosmos/readability/pull/53)).
- Allow `httpoison ~> 1.8 or ~> 2.0`.

### Fixed

- `<font>` tags were incorrectly replaced with `<1span>` during normalization.
- Deprecation warnings from newer Floki versions.

For older releases, see [Hex](https://hex.pm/packages/readability/versions) and the [commit history](https://github.com/keepcosmos/readability/commits/master).

[0.13.0]: https://github.com/keepcosmos/readability/compare/v0.12.1...v0.13.0
[0.12.1]: https://github.com/keepcosmos/readability/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/keepcosmos/readability/releases/tag/v0.12.0
