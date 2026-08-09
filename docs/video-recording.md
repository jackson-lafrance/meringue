# macOS proof video recording

## Chosen tool

Use macOS's built-in `/usr/sbin/screencapture` video mode. It is already installed, scriptable, and supports a fixed duration and display selection without adding a package, account, daemon, or harness dependency. `bin/meringue-record` is a small wrapper that targets display 1 by default and uses it with audio disabled by default.

Other options were considered:

| Option | Assessment |
| --- | --- |
| `screencapture` | **Chosen:** safest and easiest to reproduce from an agent shell; no installation or third-party state. |
| QuickTime/Screenshot toolbar | Built in, but manual and difficult to repeat exactly from an agent workflow. |
| OBS | Strong scenes and audio controls, but a large GUI setup with persistent state that is unnecessary for terminal proof. |
| Homebrew `ffmpeg` with AVFoundation | Powerful and automatable, but adds a dependency and device/codec configuration; use it only when post-processing or system audio is required. |

## One-time macOS permission

Give the terminal application that launches the helper (Terminal, iTerm, Alacritty, etc.) access under **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen that terminal. `--microphone` additionally requires Microphone permission. A headless SSH session cannot provide the WindowServer access this tool needs.

## Recording Meringue or PR behavior

Use two visible terminals so the recorder does not occupy the terminal running the demonstration:

```sh
# Terminal 1: the proof subject
bundle exec meringue demo

# Terminal 2: from the Meringue checkout
bin/meringue-record \
  --duration 45 \
  --display 1 \
  --show-clicks \
  --output "$HOME/Desktop/meringue-pr-proof.mov"
```

After starting the second command, focus Terminal 1 and perform the deterministic demo steps. The command returns after the requested duration and writes a QuickTime-compatible `.mov`. Use `--cursor` when pointer movement matters. Do not enable `--microphone` unless narration is needed; the helper intentionally does not capture audio by default.

For a PR proof, keep the Meringue dashboard, focused worker workspace, or browser opened by the existing delivery-PR action visible while recording. Avoid exposing tokens, private repository content, or unrelated notifications. Store videos outside the checkout unless they are intentionally being delivered as an artifact.

## Integration and limitations

No kernel, harness, state, or TUI integration is required: the helper records the visible macOS display and does not inspect or mutate Meringue state. Existing demo commands, focused worker sessions, and verified PR-opening actions are the integration points. The wrapper is included in the repository's `bin/` tools and has no Ruby or Homebrew dependency.

The recording is pixel-based, fixed-duration, and limited to the selected display. It does not capture system audio, terminal scrollback that is not visible, or a headless session. Screen Recording permission is controlled by macOS and cannot be granted safely by the repository. Use OBS or `ffmpeg` only when these limitations justify their additional setup.
