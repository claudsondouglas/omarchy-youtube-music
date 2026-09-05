# YouTube Music for Omarchy

A compact, keyboard-first YouTube music player for Omarchy Quattro. Search
YouTube, play audio without opening a browser tab, and move through the current
result queue from a native Omarchy overlay.

![YouTube Music player](preview.png)

## Features

- YouTube song, artist, and album search
- Audio-only playback through `mpv`
- Artwork, artist, and duration in the result list
- Play/pause, previous, and next controls
- Mix: an endless station built from any track, the way "Start radio" works in
  the YouTube Music app
- Opening a song from search replaces "up next" with that song's mix
- The queue plays through on its own, one track after the next
- Minimal top-bar now-playing player with artwork and previous/play/next controls
- Shared queue and playback state between the bar and full player
- Keyboard navigation
- Optional top-bar launcher

## Dependencies

The plugin requires `yt-dlp`, `mpv`, `socat`, and `jq`. They are present in a
standard Omarchy installation.

## Install

```sh
omarchy plugin add https://github.com/itsdotdev/omarchy-youtube-music.git --enable
```

Omarchy validates the manifest, installs the plugin, and places its widget in
the left section of the bar. To develop from a local checkout instead, run
`omarchy plugin add ./omarchy-youtube-music --enable`.

Open it from its bar icon or directly:

```sh
omarchy-shell shell toggle io.github.itsdotdev.youtube-music '{}'
```

To enable the plugin shortcuts, add this guarded loader to
`~/.config/hypr/bindings.lua`:

```lua
pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.itsdotdev.youtube-music/hypr-bindings.lua")
```

Then run `hyprctl reload`.

The loader adds these desktop shortcuts:

- `Super + Ctrl + Shift + M` toggles the player.
- `Super + K` toggles search only while the player window is focused. Everywhere
  else it retains Omarchy's standard Keybindings menu action.

Inside the player, press Enter to search or play the selected result, use the
arrow keys to move through results, and press Escape to close it. Click the
artwork or track title to open the player; the compact bar controls handle
previous, play/pause, and next.

The `((*))` button next to the transport controls builds a mix around the track
on air; the same button appears on each row of the list on hover. Picking a
track from the search results does it automatically, so "up next" becomes that
song's mix instead of the leftover search results. Once you are in a mix you
stay in it: it plays to the end unless you start another mix or search again.
Tracks already played stay in the list, dimmed, so you can go back to them.

## Notes

This plugin uses public YouTube search results and does not sign in to a Google
account. Playback availability follows YouTube and `yt-dlp`; regional,
age-restricted, or account-only videos may not play.

## Remove

```sh
omarchy plugin remove io.github.itsdotdev.youtube-music
```

## License

MIT
