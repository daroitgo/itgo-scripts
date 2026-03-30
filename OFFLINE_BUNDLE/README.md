# OFFLINE_BUNDLE

Moduł `OFFLINE_BUNDLE` służy do budowania i publikacji paczki offline dla ekosystemu ITGO.

## Cel

Paczka offline pozwala uruchomić instalację `MASTER` i dołączonych modułów na serwerach bez dostępu do GitHub RAW.

Głównym celem modułu jest dostarczenie lokalnego payloadu instalacyjnego, tak aby `MASTER` mógł pracować w trybie offline i pobierać artefakty z lokalnej paczki zamiast z internetu.

Moduł nie gwarantuje pełnej samowystarczalności wszystkich późniejszych działań ekosystemu, jeżeli dany moduł lub operator będzie później korzystał z zewnętrznych źródeł innych niż GitHub RAW.

## Zawartość modułu

Katalog `OFFLINE_BUNDLE` zawiera:

- `bundle.version` - wersję modułu `OFFLINE_BUNDLE`
- `release.manifest.psd1` - manifest publikacji do repozytorium PUBLIC
- `README.md` - opis działania modułu
- `CHANGELOG.md` - historia zmian modułu
- `itgo-offline-bundle.tar.gz` - finalną paczkę offline do publikacji i użycia

## Budowanie paczki

Budowanie odbywa się z repozytorium DEV poleceniem:

    .\build-offline-bundle.ps1

Skrypt budujący:
- tworzy staging w katalogu tymczasowym systemu,
- przygotowuje katalog `itgo-offline-bundle`,
- tworzy katalog `payload/` z artefaktami modułów,
- generuje plik `bundle.manifest.env` zawierający:
  - techniczny identyfikator `BUNDLE_VERSION`,
  - czas wygenerowania paczki,
  - wersje modułów dołączonych do payloadu,
- generuje plik `checksums.sha256`,
- kopiuje launcher `install.sh` na podstawie pliku źródłowego `offline-install.sh`,
- zapisuje finalne archiwum do:

    OFFLINE_BUNDLE\itgo-offline-bundle.tar.gz

## Moduły dołączane do paczki

Paczka offline zawiera artefakty release następujących modułów:

- `MASTER`
- `STATUS`
- `CLEANUP`
- `TSEQ`
- `DOWNLOADER_APP`
- `UPGBUILDER`

Zakres plików kopiowanych do paczki wynika z `release.manifest.psd1` każdego modułu.

## Struktura paczki offline

Po rozpakowaniu archiwum dostępny jest katalog:

    itgo-offline-bundle/

Typowa struktura obejmuje:
- `install.sh` - launcher instalacji offline,
- `bundle.manifest.env` - manifest paczki wygenerowany podczas builda,
- `checksums.sha256` - suma kontrolna plików paczki,
- `payload/` - artefakty modułów wymagane do instalacji offline.

## Działanie install.sh

Skrypt `install.sh`:
- przyjmuje nazwę użytkownika docelowego jako pierwszy parametr,
- ustawia `SOURCE_DIR` na lokalny katalog `payload`,
- weryfikuje obecność:
  - `payload/MASTER/master_installer.sh`
  - `payload/UPGBUILDER/template`
- uruchamia `MASTER`, przekazując mu lokalne źródło artefaktów zamiast GitHub RAW.

W praktyce `install.sh` jest cienkim launcherem trybu offline.
Właściwa logika instalacyjna pozostaje po stronie `MASTER`.

## Użycie na serwerze offline

1. Skopiować `itgo-offline-bundle.tar.gz` na serwer docelowy.
2. Rozpakować archiwum.
3. Przejść do katalogu paczki.
4. Uruchomić instalację jako `root`.

Przykład:

    tar -xzf itgo-offline-bundle.tar.gz
    cd itgo-offline-bundle
    sudo bash install.sh itgo

## Ograniczenia

Paczka offline eliminuje zależność od GitHub RAW przy instalacji modułów dołączonych do payloadu, ale nie oznacza pełnego trybu air-gap dla całego ekosystemu.

W szczególności:
- nie dostarcza artefaktów aplikacyjnych pobieranych później przez `DOWNLOADER_APP`,
- nie zastępuje zewnętrznych źródeł używanych później przez operatora lub inne moduły,
- nie gwarantuje lokalnej dostępności pakietów systemowych instalowanych opcjonalnie przez `MASTER`,
- zakłada zgodność payloadu z aktualnym `MASTER` oraz strukturą modułów publikowanych przez ich `release.manifest.psd1`.

## Wersjonowanie

Wersja modułu `OFFLINE_BUNDLE` jest utrzymywana w pliku:

    OFFLINE_BUNDLE\bundle.version

Niezależnie od wersji modułu, podczas budowania paczki generowany jest również techniczny identyfikator `BUNDLE_VERSION` w pliku `bundle.manifest.env`, oparty o znacznik czasu.

## Publikacja do PUBLIC

Publikacja odbywa się tak samo jak dla pozostałych modułów:

    .\release-dev-to-public.ps1 -Module OFFLINE_BUNDLE

## Zalecany workflow po zmianach

1. Wprowadzić zmiany w odpowiednich modułach.
2. Podbić wersje tych modułów, które rzeczywiście się zmieniły.
3. Uzupełnić changelogi modułowe.
4. Uruchomić:

    .\sync-master-module-versions.ps1

5. Uruchomić:

    .\sync-release-matrix.ps1

6. Zbudować paczkę offline:

    .\build-offline-bundle.ps1

7. Zweryfikować, że `OFFLINE_BUNDLE\itgo-offline-bundle.tar.gz` zawiera aktualny payload.
8. Opublikować moduł `OFFLINE_BUNDLE`:

    .\release-dev-to-public.ps1 -Module OFFLINE_BUNDLE