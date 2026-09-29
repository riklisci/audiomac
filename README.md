# AudioMac

Registra lo schermo del Mac (intero o una singola finestra) insieme all'audio interno del Mac e al microfono,
cosa che lo strumento di sistema (⌘⇧5) non permette.

- Schermo intero o singola finestra, H.264 o HEVC, 30/60 fps
- Audio del Mac e microfono su due tracce separate, con muto in tempo reale
- Livelli audio dei due ingressi sempre visibili
- File `.mov` salvati in `~/Movies`

## Compatibilità

macOS 11 Big Sur e successivi, Intel e Apple Silicon.

| macOS | Video | Audio del Mac |
|---|---|---|
| 13+ | ScreenCaptureKit | ScreenCaptureKit |
| 12.3 – 12.x | ScreenCaptureKit | driver AudioMac Loopback |
| 11 – 12.2 | CGDisplayStream / istantanee finestra | driver AudioMac Loopback |

Su macOS 11–12 l'audio interno si cattura con il driver virtuale **AudioMac Loopback**, incluso nell'app e
installabile dall'app stessa (richiede la password di amministratore).

## Compilazione

```bash
./build.sh
```

Oppure apri `AudioMac.xcodeproj` in Xcode. L'app risultante è in `build/Release/AudioMac.app`.

Per provare su un macOS recente il percorso usato da Big Sur/Monterey:

```bash
defaults write com.rikdev.audiomac ForceLegacyCapture -bool YES
```

## Permessi

Al primo avvio concedi *Registrazione schermo (e audio di sistema)* e *Microfono* in
Impostazioni di Sistema → Privacy e sicurezza.
