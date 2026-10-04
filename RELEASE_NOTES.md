## What's New in Khua Player 0.7.0 (Build 12)

### 🌐 Open URL Network Video Streaming
- **Direct Network Playback**: Added support for streaming online video URLs (`http://`, `https://`, `rtmp://`, `rtsp://`) via `⌘ + U` or menu item **File -> Open Network URL...**.
- **High-Performance Streaming**: Leverages native libavformat network I/O with automatic reconnect (`reconnect_streamed`), 10-second request timeouts, and streaming buffer management.

### 🎙️ AI Subtitle Generation for Network Streams
- **Speech & Translation**: Generate real-time subtitles and translations for network streaming video on macOS using Apple's SpeechAnalyzer.
- **Sandboxed Subtitle Caching**: Subtitles generated for network videos are automatically saved in the private sandbox cache (`~/Library/Caches/app.khua.player/Captions/`).
- **Dynamic Token Stripping**: Normalizes URLs and strips CDN dynamic authentication tokens (e.g. `token`, `expires`, `auth_key`, `sign`) to reliably compute persistent SHA-256 media keys.
- **Auto-Discovery & Instant Reuse**: Re-opening previously played network URLs automatically discovers and loads existing cached `.srt` subtitles without re-transcription.
- **Export Subtitles**: Added **Subtitles -> Export Subtitle...** (`menu.captions.exportSubtitle`) to allow exporting active subtitles to local `.srt` files via `NSSavePanel`.
- **Background Completion Notifications**: Integrated macOS Notification Center (`UNUserNotificationCenter`) to notify users when unattended background transcription finishes.
- **Window Close Perception & Control**: Prompts users upon closing playback windows with active transcription, allowing seamless background execution or stopping with partial progress saved.
- **Partial Subtitle Preservation**: Interrupted tasks or quitting now preserves recognized segments into `.part.srt` instead of discarding progress.
- **Automatic Quota Pruning**: Background LRU and age-based pruning cleans up cached network subtitles older than 30 days or exceeding 100MB disk usage.

### 🌍 Localization
- All new network playback, Open URL dialog, and subtitle export features are fully localized across all **17 supported languages** (`de`, `en`, `es`, `fr`, `id`, `it`, `ja`, `ko`, `nl`, `pl`, `pt`, `ru`, `th`, `tr`, `vi`, `zh-Hans`, `zh-Hant`).

---

### Assets
- `Khua-0.7.0.dmg`: macOS Disk Image (drag-and-drop installer)
- `Khua-0.7.0.zip`: Standalone application zip archive
