# Gnome Key bindings

### Fix if Win+5 opens an App instead of the next Workspace

Disable favorite Apps

```bash
for i in {1..9}; do
  gsettings set org.gnome.shell.keybindings switch-to-application-$i "[]"
done
```

Then the Extension `Space Bar` handles switching to Workspaces with Super+Number

### Open Files (nautilus) in new windows

Set custom shortcut with
```
nautilus --new-window
```
so it opens a new window every time. Even if the home folder is already open.

## Tweaks

Keyboard > Additional Layout Options >

### Alt and Win behavior
Alt is swapped with Win

### Caps Lock behavior
Make Caps Lock an additional Esc (or disabled)

### Switching to another Layout
Win+Space (at the very bottom)
