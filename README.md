# Muzika

An unofficial YouTube Music client for jailbroken iOS 6 (universal, iPad and iPhone) that plays your **Apple Music
playlists** too, in the skeuomorphic look of the iOS 6 years. English and Czech. A second build runs on iOS 14-17
(arm64, rootless jailbreaks and TrollStore).

## What it does

- **YouTube Music without an account**: Home (Quick picks, mixes, charts), Explore (new releases, charts, moods and
  genres), search with suggestions and filters (songs, videos, albums, artists, playlists), album, artist and playlist
  pages, song radio (endless, as YouTube Music plays it), shuffle, repeat, autoplay, the lock screen and headphone
  controls, background audio, gapless playback.
- **Playback**: synced lyrics (LRCLIB, else YouTube Music's text; tap a line to jump there), the queue to reorder and
  trim, "play next" / "add to queue" for whole albums and playlists, the same loudness for every song (YouTube's own
  measure of each), crossfade (3-12 s), a sleep timer (minutes or the end of the song), a data saver (48 kbit/s
  HE-AAC on mobile data), and the queue with the place in the song kept between launches.
- **Downloads**: songs, albums and playlists kept on the device to play without the internet (Wi-Fi only if you want).
- **Your library on the device**: liked songs (the thumb), your own playlists (create, add to, reorder, rename),
  saved albums, artists and playlists, recently played, downloads. Links of Spotify playlists and albums and of YouTube
  playlists become your own playlists ("Import a link").
- **Apple Music**: connect your library and its playlists, all its songs, albums, artists and what you added lately
  show up in Muzika and play from YouTube Music. Every song is looked up by its ISRC (the code of the recording), else
  by title, artist and length; a wrong match can be fixed in the song's menu ("Choose the YouTube version"). Songs can
  be added to your Apple Music playlists (or a new one), and the thumb goes with Apple Music's "love" both ways. Apple
  Music's charts (top songs, daily top 100s, playlists, albums) are in Explore, and public playlists and albums can be
  imported by their link, without any account.
- **iPad**: a sidebar, and in landscape "Up next" or the lyrics in a panel beside the content.

## How it works

- Browsing: YouTube Music's own web API (`music.youtube.com/youtubei/v1`, client `WEB_REMIX`).
- Sound: straight from YouTube, no server of ours in between. The player API asked as YouTube's visionOS app, with the
  visitor id YouTube Music hands out, answers with audio addresses that serve the whole file to the device's own
  connection (so it works anywhere). When one upload's audio is still not served in full, another upload of the same
  recording plays (and is remembered). Muzika downloads the AAC audio (itag 140, fragmented MP4), reads the MP4 boxes
  itself and decodes with the system's AudioConverter.
- Apple Music: the API `music.apple.com` itself uses, with the web player's developer token (read from its script,
  renewed by itself) and your own `media-user-token` cookie. The token is sent from a computer's browser through a
  little page the device serves on your Wi-Fi while the connect screen is open (or pasted). It stays on the device.
- Spotify links: the public embed page of a playlist or album lists its songs (a very long playlist may come only in part); they
  are looked up on YouTube like Apple Music songs.
- Its own TLS (Mbed TLS) and HTTP stack, as iOS 6 cannot talk to today's servers.

## Building

Theos on GitHub Actions (`.github/workflows/build.yml`): armv7 for iOS 6 and arm64 for iOS 14-17; the packages land in
the rolling `ci-build` prerelease. `tools/gh-push.ps1` pushes without a local git, `tools/gh-build.ps1` waits for the
build and installs it (`tools/local.json` holds the repository, the token and the device addresses; it never leaves the
machine).

Muzika is an unofficial app. It is not made, endorsed or supported by Google, YouTube or Apple.
