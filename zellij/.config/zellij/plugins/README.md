## Zellij zjstatus plugin

My Zellij `rounded` layout expects the `zjstatus` plugin to exist at:

```text
~/.config/zellij/plugins/zjstatus.wasm
```

On a fresh machine, install it with:

```sh
mkdir -p ~/.config/zellij/plugins

curl -L --fail \
  -o ~/.config/zellij/plugins/zjstatus.wasm \
  https://github.com/dj95/zjstatus/releases/latest/download/zjstatus.wasm
```
or for a specfic version (0.21.0 works for zellij version 0.42.2):

```sh
curl -L --fail \
  -o ~/.config/zellij/plugins/zjstatus.wasm \
  https://github.com/dj95/zjstatus/releases/download/v0.21.0/zjstatus.wasm
```

Then check the Zellij config:

```sh
zellij setup --check
```

Restart the running Zellij session so the plugin/layout is loaded again:

```sh
zellij kill-sessions main
zellij attach --create main
```

If Zellij errors on startup after installing these dotfiles, the most likely reason is that `zjstatus.wasm` has not been downloaded yet.

