# RTSP Viewer (iOS 26)

Aplikacja na iPhone/iPad do oglądania strumieni RTSP z kamer IP. Napisana w SwiftUI, bez
zewnętrznych bibliotek: ma własnego klienta RTSP, a wideo dekoduje sprzętowo przez
`AVSampleBufferDisplayLayer`.

## Funkcje

- **Zapisane strumienie**: adres RTSP, przyjazna nazwa i opcjonalny login/hasło (hasło trzymane
  w pęku kluczy iOS). Kolejność zmieniasz przyciskiem *Edytuj*, a przesunięcie wiersza w lewo
  pozwala go edytować lub usunąć.
- **Automatyczne wznawianie**: gdy połączenie zostanie zerwane, kamera przestanie wysyłać dane
  (8 s bez danych) albo nawiązywanie połączenia zawiesi się (10 s), aplikacja łączy się
  ponownie po 0,5 → 1 → 2 → 3 → 5 s i dalej ponawia co 5 s, aż się uda.
- **Dźwięk** w formatach AAC (MPEG4-GENERIC i MP4A-LATM), G.711 µ-law/A-law (PCMU/PCMA) oraz
  PCM L16, zsynchronizowany z obrazem (na podstawie raportów RTCP z kamery). Gra także przy
  przełączniku wyciszenia ustawionym na „cicho”.
- **Ręczny restart połączenia**: przycisk ⟳ w lewym dolnym rogu odtwarzacza zrywa połączenie,
  czyści bufor i łączy się z kamerą od nowa.
- **Nadrabianie utraconej transmisji**: RTP idzie przez TCP, więc przy krótkiej przerwie w
  sieci (np. 2 s) dane nie przepadają, tylko docierają z opóźnieniem. Odtwarzacz puszcza je
  wtedy szybciej, aż wróci do czasu rzeczywistego. Tempo zależy od zaległości ponad bufor:
  co najmniej 2,5 s daje 3×, co najmniej 1 s daje 2×, mniej daje 1,5×, a w miarę doganiania
  tempo spada stopniowo. Dźwięk przyspiesza razem z obrazem i zachowuje normalną wysokość tonu.
  Jeśli opóźnienie przekroczy 12 s albo przyspieszenie przez 3 s nie zmniejsza opóźnienia,
  odtwarzacz przeskakuje od razu do bieżącej chwili. Pod obrazem widać faktyczne tempo zegara
  odtwarzania i liczbę takich przeskoków.
- **Bufor 0,8 s** (0,9 s ze strumieniem audio) wygładza drobne wahania sieci, więc nie ma
  mikroprzycięć.
- **Zoom**: rozsunięcie palców przybliża do 8×, przeciąganie przesuwa obraz, a dwukrotne
  stuknięcie przybliża lub przywraca widok.
- **Nakładka odtwarzacza**:
  - prawy górny róg: kółko ładowania przy łączeniu i zacięciu obrazu, ikona stop przy braku
    połączenia, czerwona plakietka ▶ LIVE na żywo, pomarańczowa ⏩ 1.5× przy nadrabianiu,
  - w pełnym ekranie, pod plakietką stanu: procent baterii telefonu (zielona błyskawica przy
    ładowaniu, czerwona ikona przy ≤ 20%) oraz ikona połączenia (Wi-Fi, sieć komórkowa albo
    brak sieci). Siły sygnału Wi-Fi iOS nie udostępnia aplikacjom, więc nie jest pokazywana,
  - prawy dolny róg: przycisk pełnego ekranu. Na iPhonie obrócenie telefonu też włącza i
    wyłącza pełny ekran.
- Ekran nie wygasa podczas oglądania. Po zminimalizowaniu aplikacji strumień jest zatrzymywany,
  a po powrocie wznawiany.

Obsługiwane kodeki: wideo **H.264** i **H.265/HEVC**, dźwięk **AAC**, **G.711** i **L16**.
Wspierane jest uwierzytelnianie Basic i Digest, a także `rtsps://` (TLS).

Jeśli kamera nie wysyła dźwięku, sprawdź w jej panelu WWW, czy dźwięk jest włączony dla danego
strumienia. W Hikvision i Dahua to ustawienie zwykle jest domyślnie wyłączone dla strumienia
głównego. Używany format dźwięku widać na ekranie odtwarzacza w wierszu *Dźwięk*.

## Budowanie IPA przez GitHub Actions

1. Utwórz na GitHubie nowe repozytorium i wrzuć do niego **całą zawartość tego folderu**, łącznie
   z ukrytym katalogiem `.github`. Przykład z wiersza poleceń:
   ```bash
   git init
   git add .
   git commit -m "RTSP Viewer"
   git branch -M main
   git remote add origin https://github.com/<użytkownik>/<repozytorium>.git
   git push -u origin main
   ```
2. Push na `main` uruchamia workflow **Build IPA** (`.github/workflows/build-ipa.yml`). Możesz go
   też odpalić ręcznie: zakładka *Actions* → *Build IPA* → *Run workflow*.
3. Po zakończeniu pobierz artefakt **RTSPViewer-unsigned-ipa** ze strony przebiegu. GitHub
   pakuje go w ZIP, w środku jest plik `RTSPViewer-unsigned.ipa`.
4. Gdy wypchniesz tag `v*` (np. `git tag v1.0.0 && git push --tags`), IPA zostanie też dołączone
   do wydania (Release).

Workflow działa na runnerze `macos-26` z Xcode 26. Projekt Xcode jest generowany w locie z
pliku `project.yml` przez [XcodeGen](https://github.com/yonaskolb/XcodeGen), dlatego plików
`.xcodeproj` nie ma w repozytorium.

### Instalacja na telefonie

IPA jest **niepodpisane**. Podpiszesz je i zainstalujesz na przykład przez:
- **Sideloadly** albo **AltStore** (darmowe Apple ID, ważność 7 dni),
- własny certyfikat deweloperski (płatne konto Apple Developer),
- **TrollStore**, jeśli Twoja wersja iOS go obsługuje.

Bundle ID to `com.rtspviewer.app`; zmienisz go w `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`).

Przy pierwszym połączeniu iOS zapyta o zgodę na **dostęp do sieci lokalnej**. Bez niej kamery
w sieci LAN będą nieosiągalne (Ustawienia › Prywatność i ochrona › Sieć lokalna).

## Przykładowe adresy RTSP

| Producent | Adres |
|---|---|
| Hikvision | `rtsp://IP:554/Streaming/Channels/101` (102 = substream) |
| Dahua / IMOU | `rtsp://IP:554/cam/realmonitor?channel=1&subtype=0` |
| Reolink | `rtsp://IP:554/h264Preview_01_main` |
| TP-Link Tapo | `rtsp://IP:554/stream1` (stream2 = niższa jakość) |
| Ubiquiti UniFi | `rtsps://IP:7441/<token>` |

Jeśli hasło zawiera znaki specjalne (`@`, `:`, `/`, `#`), wpisz je w polu *Hasło* zamiast w adresie.

## Ograniczenia

- Nieobsługiwane formaty dźwięku: G.726, Opus i AAC z konfiguracją przesyłaną w strumieniu
  (LATM `cpresent=1`). Wtedy gra sam obraz, a w wierszu *Dźwięk* widać nazwę formatu.
- Mówienie do kamery (kanał zwrotny ONVIF) nie jest obsługiwane.
- Transport wyłącznie **RTP przez TCP** (interleaved). Obsługuje go praktycznie każda kamera
  IP i to on umożliwia nadrabianie. Kamery, które przyjmują wyłącznie UDP, nie zadziałają.
- Nadrobić można tylko przerwę, w trakcie której połączenie TCP przetrwało (do ok. 8 s). Po
  zerwaniu sesji kamera nie przechowuje utraconego obrazu, więc po wznowieniu odtwarzanie rusza
  od bieżącej chwili.

## Struktura

```
RTSPViewer/
├── App/        punkt wejścia, blokada orientacji (pełny ekran = poziomo)
├── Models/     CameraStream (SwiftData), KeychainStore
├── RTSP/       klient RTSP, SDP, autoryzacja Digest/Basic, RTP/RTCP, składanie H.264/H.265, AAC/G.711
├── Player/     StreamPlayer (wznawianie, watchdog, sesja audio)
│               MediaPipeline (wspólny zegar, bufor, nadrabianie), MediaTimeline (synchronizacja A/V)
│               VideoDecoder, AudioDecoder
└── Views/      lista, edytor, ekran odtwarzacza, zoom, nakładka ze statusem
```

Parametry bufora i nadrabiania są w `MediaPipeline.Tuning`, a limity czasu i opóźnienia
ponowień na górze `StreamPlayer`.
