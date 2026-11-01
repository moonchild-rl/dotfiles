## Gamescope

Gamescope is a lightweight compositor developed by Valve, also used as part of the Steam Deck's gaming environment. It runs a game inside a managed display environment instead of letting the game handle everything directly through niri.

This is especially useful for games that expect a conventional desktop window manager or X11 environment.

### Step 1: Install Gamescope

On Fedora Workstation, run:

```
sudo dnf install gamescope
```

Gamescope is available directly in Fedora's repositories.


### Step 2: Configure Game

Open Steam, go to your Library, right-click the Game, and select Properties.

Under General > Launch Options, enter:

```
gamescope -f -w 2560 -h 1440 -W 2560 -H 1440 --force-grab-cursor --backend sdl -- %command%
```

This is adapted directly from niri's official recommended configuration for fullscreen games.


Here is what each parameter does:

| Parameter             | Purpose                                                                                                              |
| --------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `-f`                  | Runs Gamescope fullscreen                                                                                            |
| `-w 2560 -h 1440`     | Sets the resolution presented to the game                                                                            |
| `-W 2560 -H 1440`     | Sets Gamescope's output resolution                                                                                   |
| `--force-grab-cursor` | Forces relative mouse input, preventing the cursor from escaping into other monitors                                 |
| `--backend sdl`       | Uses the SDL backend, which niri currently recommends due to mouse locking problems with Gamescope's Wayland backend |
| `-- %command%`        | Runs the game through Steam with its normal launch arguments                                                         |

The two most important options for your specific problem are `--force-grab-cursor` and `--backend sdl`.

### Step 3: Launch the game

Start the Game from Steam as usual.

In the game's settings, use 2560×1440 resolution. Start with its fullscreen setting, then try borderless fullscreen if needed.

Ideally, you should now have:

- Fullscreen gaming at your monitor's native 1440p resolution.
- Mouse movement that stays captured while aiming, including when turning continuously.
- No unwanted interaction with the monitor on the left.
- No 1080p-sized image surrounded by black space.

The game is effectively running in a fullscreen Gamescope window, with Gamescope managing the input and presentation.


## 4. Optional: Play at 1080p but fill the entire 1440p monitor

Another useful Gamescope feature is resolution scaling.

For example, if a game is too demanding at 1440p, you can render it at 1080p while still displaying it fullscreen on your 1440p monitor.

Use these Steam launch options:

```
gamescope -f -w 1920 -h 1080 -W 2560 -H 1440 --force-grab-cursor --backend sdl -- %command%
```

The game renders at 1920×1080, but Gamescope scales it to 2560×1440.

---

Gamescope is particularly useful when a game has problems with mouse capture, fullscreen behavior, resolutions or scaling. It also provides a consistent display environment for games originally designed around X11 behavior.

You can selectively enable it in each game's Steam launch options rather than using it globally.
