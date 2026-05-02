# GNOME extension settings

`App Icons Taskbar` was exported through the App Icons Taskbar extension preferences.

Restore it through the extension’s own import/load button or via:

```bash
dconf load /org/gnome/shell/extensions/aztaskbar/ < "$HOME/dotfiles/.extras/gnome/extensions/App Icons Taskbar"
```

[Optional] `dconf` backup:

```bash
dconf dump /org/gnome/shell/extensions/aztaskbar/ > "$HOME/dotfiles/.extras/gnome/extensions/app-icons-taskbar.dconf"
```
