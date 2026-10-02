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
  przełączniku wyciszenia ustawionym na „cicho”. Przycisk w lewym dolnym rogu wycisza dźwięk,
  a ustawienie jest zapamiętywane.
- **Nadrabianie utraconej transmisji**: RTP idzie przez TCP, więc przy krótkiej przerwie w
  sieci (np. 2 s) dane nie przepadają, tylko docierają z opóźnieniem. Odtwarzacz puszcza je
  wtedy w tempie 1,5× (2× przy opóźnieniu powyżej 4 s), aż wróci do czasu rzeczywistego. Dźwięk
  przyspiesza razem z obrazem i zachowuje normalną wysokość tonu. Jeśli opóźnienie przekroczy
  12 s, odtwarzacz przeskakuje od razu do bieżącej chwili.
- **Zoom**: rozsunięcie palców przybliża do 8×, przeciąganie przesuwa obraz, a dwukrotne
  stuknięcie przybliża lub przywraca widok.
- **Nakładka odtwarzacza**:
  - prawy górny róg: kółko ładowania przy łączeniu i zacięciu obrazu, ikona stop przy braku
    połączenia, czerwona plakietka ▶ LIVE na żywo, pomarańczowa ⏩ 1.5× przy nadrabianiu,
  - prawy dolny róg: przycisk pełnego ekranu. Na iPhonie obrócenie telefonu też włącza i
    wyłącza pełny ekran.
- Ekran nie wygasa podczas oglądania. Po zminimalizowaniu aplikacji strumień jest zatrzymywany,
  a po powrocie wznawiany.

Obsługiwane kodeki: wideo **H.264** i **H.265/HEVC**, dźwięk **AAC**, **G.711** i **L16**.
Wspierane jest uwierzytelnianie Basic i Digest, a także `rtsps://` (TLS).

Jeśli kamera nie wysyła dźwięku, sprawdź w jej panelu WWW, czy dźwięk jest włączony dla danego
strumienia. W Hikvision i Dahua to ustawienie zwykle jest domyślnie wyłączone dla strumienia
głównego. Używany format dźwięku widać na ekranie odtwarzacza w wierszu *Dźwięk*.


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
