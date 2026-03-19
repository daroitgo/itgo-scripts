# Changelog

W tym pliku prowadzona jest historia zmian modułu `OFFLINE_BUNDLE`.

## [0.1.2] - 2026-03-19

### Changed
- Przebudowano paczkę `itgo-offline-bundle.tar.gz` po podniesieniu `MASTER` do `1.2.3`.
- Zaktualizowano zawartość paczki o `UPGBUILDER 0.1.1`.

### Compatibility
- Zachowano model publikacji modułu `OFFLINE_BUNDLE` przez `release.manifest.psd1`.

### Breaking changes
- brak

## [0.1.1] - 2026-03-19

### Changed
- Przebudowano paczkę `itgo-offline-bundle.tar.gz` po podniesieniu `MASTER` do `1.2.2`.
- Builder publikuje teraz finalny artefakt bezpośrednio do `OFFLINE_BUNDLE`, bez używania katalogu `dist` jako oficjalnej lokalizacji.

### Fixed
- Uproszczono workflow budowania paczki offline przez przeniesienie stagingu do katalogu tymczasowego systemu.
- Usunięto podwójną logikę lokalizacji artefaktu, tak aby `OFFLINE_BUNDLE` było jedynym oficjalnym miejscem paczki w repo.

### Compatibility
- Zachowano model publikacji modułu `OFFLINE_BUNDLE` przez `release.manifest.psd1`.

### Breaking changes
- brak

## [0.1.0] - 2026-03-19

### Added
- Dodano moduł `OFFLINE_BUNDLE` jako źródło release dla paczki offline ekosystemu ITGO.
- Dodano plik `bundle.version` z wersją modułu offline bundle.
- Dodano `release.manifest.psd1` do publikacji paczki w modelu zgodnym z pozostałymi modułami.
- Dodano `README.md` opisujący budowanie i użycie paczki offline.
- Dodano artefakt `itgo-offline-bundle.tar.gz` jako publikowalną paczkę offline.

### Changed
- Rozdzielono rolę katalogu roboczego `dist` i modułu release `OFFLINE_BUNDLE`.
- Paczka offline jest budowana w katalogu roboczym, a publikowalny artefakt trafia do `OFFLINE_BUNDLE`.

### Compatibility
- Moduł jest zgodny z obecnym modelem publikacji opartym o `release.manifest.psd1`.

### Breaking changes
- brak
