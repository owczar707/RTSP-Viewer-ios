# iphone-refresher

Samodzielny „mini-AltServer” dla Linuksa. Co kilka dni sam podpisuje RTSP Viewer darmowym Apple ID
i instaluje go na iPhonie **przez Wi-Fi**, żeby aplikacja nigdy nie wygasła (podpis z darmowego
konta jest ważny 7 dni).

Program jest zbudowany na bibliotece [isideload](https://github.com/nab138/isideload), której używa
też iloader. Gdy Apple coś zmieni w logowaniu, zwykle wystarczy podbić wersję `isideload` w
`Cargo.toml` (i zgodnie z nią `idevice`), przebudować program i ewentualnie zmienić
`anisette_url` / `client_info` w konfiguracji.

## Polecenia

| Polecenie | Co robi |
|---|---|
| `iphone-refresher check [ip]` | łączy się z iPhone'em przez Wi-Fi (bez logowania do Apple) i wypisuje jego nazwę |
| `iphone-refresher setup` | pyta o Apple ID, hasło, IP iPhone'a i ścieżkę do IPA, zapisuje je i instaluje aplikację |
| `iphone-refresher install` | instaluje aplikację z zapisanymi ustawieniami; uruchomione ręcznie może zapytać o 2FA i o certyfikat do unieważnienia |
| `iphone-refresher auto` | tryb dla timera: odświeża tylko, gdy od ostatniego sukcesu minęły ponad 4 dni, nigdy o nic nie pyta |
| `iphone-refresher status` | pokazuje, kiedy było ostatnie udane odświeżenie |

## Pliki (`~/.config/iphone-refresher`, uprawnienia 700)

- `config.json` – ustawienia, w tym hasło Apple ID (uprawnienia 600)
- `pairing.plist` – plik parowania iPhone'a, skopiowany z komputera, któremu iPhone ufa
  (Windows: `C:\ProgramData\Apple\Lockdown\<UDID>.plist`)
- `state/anisette` – tożsamość „urządzenia” dla Apple; dzięki niej logowanie nie wymaga ponownie 2FA
- `state/sideloader` – klucz i certyfikat deweloperski
- `state/last_success` – czas ostatniego udanego odświeżenia

## Wymagania po stronie iPhone'a

- w iTunes włączone „Synchronizuj z tym iPhone'em przez Wi-Fi” (bez tego iPhone nie przyjmuje połączeń z sieci),
- iPhone w tej samej sieci co serwer, ze stałym adresem IP („Prywatny adres Wi-Fi”: Stały lub Wyłączony).

## Instalacja na serwerze (Debian)

```bash
sudo apt install build-essential pkg-config libssl-dev
curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
cargo build --release
sudo install -m 755 target/release/iphone-refresher /usr/local/bin/
sudo install -m 644 systemd/iphone-refresher.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now iphone-refresher.timer
iphone-refresher setup   # raz, ręcznie, w terminalu
```

Usługa w `systemd/iphone-refresher.service` działa jako użytkownik `claude`; zmień `User=`,
jeśli używasz innego.

Logi: `journalctl -u iphone-refresher.service`
