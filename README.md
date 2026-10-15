# Muzika

An unofficial YouTube Music client for jailbroken iOS 6 (universal, iPad and iPhone) that plays your **Apple Music
playlists** too, in the skeuomorphic look of the iOS 6 years. English and Czech. A second build runs on iOS 14-17
(arm64, rootless jailbreaks and TrollStore).

## What it does

- **YouTube Music without an account**: Home (Quick picks, mixes, charts), Explore (new releases, charts, moods and
  genres), search with suggestions and filters (songs, videos, albums, artists, playlists), album, artist and playlist
  pages, song radio (endless, as YouTube Music plays it), lyrics, queue, shuffle, repeat, autoplay, the lock screen
  and headphone controls, background audio, gapless playback.
- **Your library on the device**: liked songs (the thumb), saved albums, artists and playlists, recently played.
- **Apple Music**: connect your library and its playlists show up in Muzika and play from YouTube Music. Every song is
  looked up by its ISRC (the code of the recording), else by title, artist and length; a wrong match can be fixed in
  the song's menu ("Choose the YouTube version"). Public Apple Music playlists and albums can be imported by their link
  without any account.

## How it works

- Browsing: YouTube Music's own web API (`music.youtube.com/youtubei/v1`, client `WEB_REMIX`).
- Sound: YouTube serves its audio files in full only to its own clients, so the audio helper of the family (yt-dlp on a
  Raspberry Pi, `/yt/resolve`, the same one Tubie uses) hands out full-length addresses. Muzika downloads the AAC
  audio (itag 140, fragmented MP4), reads the MP4 boxes itself and decodes with the system's AudioConverter.
- Apple Music: the API `music.apple.com` itself uses, with the web player's developer token (read from its script,
  renewed by itself) and your own `media-user-token` cookie. The token is sent from a computer's browser through a
  little page the device serves on your Wi-Fi while the connect screen is open (or pasted). It stays on the device;
  Muzika only reads playlists.
- Its own TLS (Mbed TLS) and HTTP stack, as iOS 6 cannot talk to today's servers.

## Building

Theos on GitHub Actions (`.github/workflows/build.yml`): armv7 for iOS 6 and arm64 for iOS 14-17; the packages land in
the rolling `ci-build` prerelease. `tools/gh-push.ps1` pushes without a local git, `tools/gh-build.ps1` waits for the
build and installs it (`tools/local.json` holds the repository, the token and the device addresses; it never leaves the
machine).

Muzika is an unofficial app. It is not made, endorsed or supported by Google, YouTube or Apple.
