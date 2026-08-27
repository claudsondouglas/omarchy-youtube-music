# Design QA

- Source visual truth: local design exploration (not committed)
- Implementation screenshot: local final compact-player capture (not committed)
- Combined comparison: local side-by-side QA capture (not committed)
- Viewport: 3840 × 2160 Omarchy desktop, top bar, dark theme
- Source pixels: 1367 × 1153
- Implementation pixels: 3840 × 2160
- Density normalization: both images were proportionally resized and centered on separate 1400 × 1000 canvases, then joined horizontally for one comparison input. The original implementation capture was also inspected at full resolution for typography, icons, and image quality.
- State: live now-playing state with a persisted three-track queue; the current track is omitted from “Up next,” leaving two upcoming rows.

## Findings

No actionable P0, P1, or P2 differences remain.

- Fonts and typography: the implementation uses Omarchy’s configured UI family and preserves the reference hierarchy: strong track title, subdued artist, compact timestamps, and smaller queue metadata. The bar intentionally uses a single truncated title line.
- Spacing and layout rhythm: the vertical artwork → metadata → progress → transport → queue sequence matches the source. The implementation intentionally anchors to the bar instead of floating in the desktop center, fitting the requested integrated mini-player behavior.
- Colors and visual tokens: near-black surfaces, off-white text, muted grays, and a single restrained green accent match the target. The green outlined play control now matches the selected direction.
- Image quality and asset fidelity: the implementation uses live YouTube thumbnails rather than mock album assets. YouTube’s 16:9 artwork may include letterboxing inside the square crop; this is an expected source-data constraint, not a placeholder.
- Copy and content: product label, search prompt, now-playing metadata, timestamps, and “Up next” are present and match the intended product language.
- Accessibility: high-contrast text and transport controls remain legible against the dark surface; selected/current rows use both color and weight.

## Focused Evidence

No separate crop was required because the original 3840 × 2160 implementation capture clearly resolves the search field, title hierarchy, timestamps, compact transport icons, and queue rows. Those areas were inspected at original resolution in addition to the normalized comparison.

## Interaction Verification

- Live YouTube search contract returned playable results.
- Queue next advanced from index 1 to 2.
- Queue previous returned from index 2 to 1.
- Stop left the player in a stable idle-now-playing state with no audio process running.
- The top-bar player reflects persisted track metadata and exposes previous, play/pause, and next.
- The top-bar player is in the left layout group after workspaces; its decorative waveform was removed.
- Shell summon opens the anchored player after the bar finishes mounting.
- `Super + Ctrl + Shift + M` is registered as key `M` with modifier mask `69`.
- Focused `Super + K` expands and collapses search without closing the player;
  outside the player it retains Omarchy's standard Keybindings menu action.
- Omarchy plugin validation and Bash syntax validation pass.
- Final Quickshell log contains no YouTube Music QML errors.
- `hyprctl configerrors` is empty.

## Comparison History

1. Initial redesign capture found P2 layering and hierarchy issues: nested fullscreen windows stacked dimming surfaces, several display sizes resolved to undefined tokens, and the current track appeared inside “Up next.”
2. The player moved to Omarchy’s native `PopupCard`, undefined font tokens were replaced with supported display sizes, the background artwork treatment was reduced, the current queue item was removed from “Up next,” and search placeholder visibility was corrected.
3. Post-fix evidence shows one crisp popover, a matching bar capsule, correct outlined transport styling, stable queue rows, and no duplicate scrim.
4. Compact refinement reduced the popover from 620 × 900 to 400 × 540 logical pixels, reduced the bar capsule from 402 to 214 logical pixels, removed decorative bar audio bars, and moved the widget from the center layout group to the left.

## Follow-up Polish

- P3: A future metadata provider could prefer square album artwork over YouTube’s video thumbnail when available.
- P3: The popover could add click-to-seek and a volume slider without changing its current hierarchy.

## Implementation Checklist

- [x] Match selected compact vertical composition
- [x] Add integrated top-bar now-playing capsule
- [x] Synchronize playback and queue state
- [x] Verify search, navigation, stop, shortcut, and shell routing
- [x] Validate visual comparison and runtime logs

final result: passed
