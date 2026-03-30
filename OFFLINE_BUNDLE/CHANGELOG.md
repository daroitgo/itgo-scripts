# Changelog

W tym pliku prowadzona jest historia zmian modułu `OFFLINE_BUNDLE`.

## 0.1.4 - 2026-03-25
- przebudowano pakiet offline po zmianach w `UPGBUILDER` do wersji `0.1.2`,
- zaktualizowano payload `MASTER` do wersji `1.2.4`,
- odświeżono artefakt `itgo-offline-bundle.tar.gz` i manifest/checksumy zgodnie z aktualnym stanem payloadów.

## [0.1.3] - 2026-03-19

### Fixed
- Przebudowano paczkę `itgo-offline-bundle.tar.gz` po wykryciu błędu CRLF w wygenerowanym `install.sh`, który powodował przekazanie do `MASTER` argumentu użytkownika z końcowym znakiem `\r`.
- Potwierdzono, że nowy artefakt zachowuje plik `install.sh` w postaci zgodnej ze źródłowym `offline-install.sh`.

### Compatibility
- Zachowano model publikacji modułu `OFFLINE_BUNDLE` przez `release.manifest.psd1`.

### Breaking changes
- brak

## [0.1.2] - 2026-03-19

### Changed
- Przebudowano paczkę `itgo-offline-bundle.tar.gz` po podniesieniu `MASTER` do `1.2.3`.
- Zaktualizowano zawartość paczki o `UPGBUILDER 0.1.1`.

### Compatibility
- Zachowano model publikacji modułu `OFFLINE_BUNDLE` przez `release.manifest.psd1`.

### Breaking changes
- brak

## [0.1.1] - 2026-03-19

### Added
- Dodano pierwszy otagowany release modułu `OFFLINE_BUNDLE`.
- Dodano pliki modułu:
  - `README.md`
  - `CHANGELOG.md`
  - `bundle.version`
  - `release.manifest.psd1`
  - `itgo-offline-bundle.tar.gz`

### Changed
- Builder publikuje finalny artefakt bezpośrednio do `OFFLINE_BUNDLE`, bez używania katalogu `dist` jako oficjalnej lokalizacji.
- Przebudowano paczkę `itgo-offline-bundle.tar.gz` po podniesieniu `MASTER` do `1.2.2`.

### Fixed
- Uproszczono workflow budowania paczki offline przez przeniesienie stagingu do katalogu tymczasowego systemu.
- Usunięto podwójną logikę lokalizacji artefaktu, tak aby `OFFLINE_BUNDLE` było jedynym oficjalnym miejscem paczki w repozytorium.

### Compatibility
- Zachowano model publikacji modułu `OFFLINE_BUNDLE` przez `release.manifest.psd1`.

### Breaking changes
- brak

## [0.1.0] - 2026-03-19

### Added
- Wewnętrzny baseline prac nad modułem `OFFLINE_BUNDLE` w repo DEV.
- Dodano moduł `OFFLINE_BUNDLE` jako źródło release dla paczki offline ekosystemu ITGO.
- Dodano plik `bundle.version` z wersją modułu offline bundle.
- Dodano `release.manifest.psd1` do publikacji paczki w modelu zgodnym z pozostałymi modułami.
- Dodano `README.md` opisujący budowanie i użycie paczki offline.
- Dodano artefakt `itgo-offline-bundle.tar.gz` jako publikowalną paczkę offline.

### Changed
- Rozdzielono rolę katalogu roboczego `dist` i modułu release `OFFLINE_BUNDLE`.
- Paczka offline była budowana w `dist`, a publikowalny artefakt trafiał do `OFFLINE_BUNDLE`.

### Compatibility
- Moduł został przygotowany do publikacji w modelu opartym o `release.manifest.psd1`.

### Breaking changes
- brak

### Note
- Wersja `0.1.0` opisuje etap bazowy w DEV i nie posiada opublikowanego taga release `offline_bundle-0.1.0`.