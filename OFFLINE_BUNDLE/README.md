# OFFLINE_BUNDLE

Moduł `OFFLINE_BUNDLE` służy do budowania i publikacji paczki offline dla ekosystemu ITGO.

## Cel

Paczka offline pozwala uruchomić instalację `MASTER` i modułów zależnych na serwerach bez dostępu do GitHub RAW i bez bezpośredniego dostępu do internetu.

## Zawartość modułu

Katalog `OFFLINE_BUNDLE` zawiera:

- `bundle.version` - wersję modułu offline bundle
- `release.manifest.psd1` - manifest publikacji do PUBLIC
- `README.md` - opis działania modułu
- `CHANGELOG.md` - historia zmian modułu
- `itgo-offline-bundle.tar.gz` - finalną paczkę offline do publikacji i użycia

## Budowanie paczki

Budowanie odbywa się z repo DEV poleceniem:

    .\build-offline-bundle.ps1

Skrypt:
- tworzy staging w katalogu tymczasowym systemu,
- składa paczkę offline,
- zapisuje finalne archiwum bezpośrednio do:

    OFFLINE_BUNDLE\itgo-offline-bundle.tar.gz

## Użycie na serwerze offline

1. Skopiować `itgo-offline-bundle.tar.gz` na serwer.
2. Rozpakować archiwum.
3. Uruchomić jako root:

    tar -xzf itgo-offline-bundle.tar.gz
    cd itgo-offline-bundle
    sudo bash install.sh itgo

## Wersjonowanie

Wersja modułu `OFFLINE_BUNDLE` jest utrzymywana w pliku:

    OFFLINE_BUNDLE\bundle.version

## Publikacja do PUBLIC

Publikacja odbywa się tak samo jak dla pozostałych modułów:

    .\release-dev-to-public.ps1 -Module OFFLINE_BUNDLE

## Zalecany workflow po zmianach

1. Zmienić odpowiednie moduły.
2. Podbić wersje modułów, które realnie się zmieniły.
3. Uzupełnić changelogi.
4. Uruchomić:

    .\sync-master-module-versions.ps1

5. Uruchomić:

    .\sync-release-matrix.ps1

6. Zbudować paczkę:

    .\build-offline-bundle.ps1

7. Opublikować moduł offline bundle:

    .\release-dev-to-public.ps1 -Module OFFLINE_BUNDLE
