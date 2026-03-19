# Changelog

W tym pliku prowadzona jest historia zmian modułu `OFFLINE_BUNDLE`.

## [0.1.0] - 2026-03-19

### Added
- Dodano moduł `OFFLINE_BUNDLE` jako źródło release dla paczki offline ekosystemu ITGO.
- Dodano plik `bundle.version` z wersją modułu offline bundle.
- Dodano `release.manifest.psd1` do publikacji paczki w modelu zgodnym z pozostałymi modułami.
- Dodano `README.md` opisujący budowanie i użycie paczki offline.
- Dodano artefakt `itgo-offline-bundle.tar.gz` jako publikowalną paczkę offline.

### Changed
- Rozdzielono rolę katalogu roboczego `dist` i modułu release `OFFLINE_BUNDLE`.
- Paczka offline jest budowana w `dist`, a publikowalny artefakt trafia do `OFFLINE_BUNDLE`.

### Compatibility
- Moduł jest zgodny z obecnym modelem publikacji opartym o `release.manifest.psd1`.

### Breaking changes
- brak
