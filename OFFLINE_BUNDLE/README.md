# OFFLINE_BUNDLE

Moduł `OFFLINE_BUNDLE` służy do budowania i publikacji paczki offline dla ekosystemu ITGO.

## Cel

Paczka offline pozwala uruchomić instalację `MASTER` i modułów zależnych na serwerach bez dostępu do GitHub RAW i bez bezpośredniego dostępu do internetu.

## Zawartość paczki

Archiwum `itgo-offline-bundle.tar.gz` zawiera:

- `install.sh` - linuxowy launcher paczki offline
- `bundle.manifest.env` - manifest wersji paczki
- `checksums.sha256` - sumy kontrolne plików w bundle
- `payload/MASTER`
- `payload/STATUS`
- `payload/CLEANUP`
- `payload/TSEQ`
- `payload/DOWNLOADER_APP`
- `payload/UPGBUILDER` razem z `upgbuilder.map` i katalogiem `template`

## Budowanie paczki

Budowanie odbywa się z repo DEV poleceniem:

    .\build-offline-bundle.ps1

Skrypt tworzy staging:

    dist\itgo-offline-bundle\

oraz finalne archiwum:

    dist\itgo-offline-bundle.tar.gz

## Użycie na serwerze offline

1. Skopiować `itgo-offline-bundle.tar.gz` na serwer.
2. Rozpakować archiwum.
3. Uruchomić jako root:

    tar -xzf itgo-offline-bundle.tar.gz
    cd itgo-offline-bundle
    sudo bash install.sh itgo

## Wersjonowanie

Wersja modułu `OFFLINE_BUNDLE` jest utrzymywana w pliku:

    OFFLINE_BUNDLE/bundle.version

## Publikacja

Docelowo moduł `OFFLINE_BUNDLE` publikowany jest do repo PUBLIC tak samo jak pozostałe moduły release.
