# Changelog

All notable changes to BetterKnownInstalled (BKI) are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v1.6.1] — 2026-09-11
`versionCode 1610`

### Changed
- **Rewrote the `packages.xml` patching engine.** The 8-pass `sed` pipeline
  (with its line-split → modify → collapse round-trip) is replaced by a single
  streaming `awk` pass that walks the file once and edits one
  `<package>…</package>` element at a time. Fewer full-file rewrites, and the
  output is byte-minimal: everything outside patched user apps is preserved
  verbatim (no more reformatting of the whole file).
- **`uninstall.sh` restored to the same engine.** Restore now uses the
  streaming walker instead of line-based normalization + `tr '\n' ' '`
  collapse, and strips/re-injects all installer-related attribute variants
  (`-int`/`-bool` included) before writing back atomically with verification.
- Consolidated shared helpers (`ensure_abx_tools`, `restore_perms`,
  `wait_for_data`) into `util_functions.sh`.
- Added `updateJson` to `module.prop` for OTA update notifications.

### Fixed
- **Invalid XML on multi-line `packages.xml`:** when the system writes package
  attributes wrapped across lines, the old pipeline injected a duplicate
  `installer` attribute (and skipped the wrapped attributes entirely),
  producing a file Package Manager could reject.
- **`packages.xml` grew on every boot:** the old normalization was not
  idempotent. The new pre-split and patch are fixed points — a second run is
  byte-identical (verified by the harness).
- **Multi-line packages were silently skipped** by `metadata.db` build/scan
  and by the old restore.
- ABX typed attribute variants (`installerUid-int`, `packageSource-int`,
  `isOrphaned-bool`, `installInitiatorUninstalled-bool`) are now handled
  everywhere (patch, DB, restore) instead of only in some passes.

### Added
- `tools/bki_debug.sh`: an offline regression harness. It dot-sources the real
  module/uninstall functions and validates them against a `packages.xml` of
  your choice (uid resolution, DB build/prune/update, patch semantics,
  duplicate-attribute and well-formedness checks, end-to-end `process_xml`,
  byte-identical idempotency, and a restore round-trip). Nothing outside its
  temp work dir is touched.

## [v1.6.0]
- `metadata.db`: original installer metadata is captured on first boot and
  re-applied/maintained on subsequent boots (prune removed apps, append new
  ones) instead of re-processing everything every boot.
- Restore-on-uninstall: original per-app values are written back from
  `metadata.db` when the module is removed.
- Safety copies (`packages.xml.safety`, `/data/local/tmp/BKI_restore_backups`)
  for crash recovery.
- ABX ⇄ text XML conversion via bundled `abx2xml`/`xml2abx` binaries
  (aarch64, armv7aeabi, i686, x86_64, riscv64).

[v1.6.1]: https://github.com/Pixel-Props/BetterKnownInstalled/compare/v1.6.0...v1.6.1
