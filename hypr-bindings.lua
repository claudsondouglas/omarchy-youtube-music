-- Load from ~/.config/hypr/bindings.lua with:
-- pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.itsdotdev.youtube-music/hypr-bindings.lua")

o.window(
  { class = "^org.quickshell$", title = "^YouTube Music Player$" },
  {
    tag = "-default-opacity",
    float = true,
    size = { 400, 540 },
    move = { 10, 38 },
    rounding = 8,
    focus_on_activate = true,
    opacity = "0.98 0.98",
  }
)

o.window(
  { class = "^org.quickshell$", title = "^YouTube Music Player$" },
  { tag = "+youtube-music-player" }
)

o.bind(
  "SUPER + CTRL + SHIFT + M",
  "YouTube Music",
  "omarchy-shell shell toggle io.github.itsdotdev.youtube-music '{}'"
)

-- Omarchy normally opens its keybindings menu with Super+K. Keep that action
-- everywhere except the focused player window, where the same chord toggles
-- the compact search control.
hl.unbind("SUPER + K")
o.bind(
  "SUPER + K",
  "Keybindings / YouTube Music search",
  os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.itsdotdev.youtube-music/bin/cmd-k"
)
