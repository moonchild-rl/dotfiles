sudo dnf copr enable monkeygold/nautilus-open-any-terminal
sudo dnf install nautilus-open-any-terminal

gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal kitty

nautilus -q

------

To get exactly "Open in Kitty":
Patch the installed extension file and change:

```
LOCAL_LABEL = _("Open {} Here")
```

to:

```
LOCAL_LABEL = _("Open in {}")
```

You can find the installed file with:

```
rpm -ql nautilus-open-any-terminal | grep '\.py$'
```

Should be: 

```
/usr/share/nautilus-python/extensions/nautilus_open_any_terminal.py
```

Then edit the relevant Python file with sudo, restart Nautilus:

```
nautilus -q
```

Note: a package update may overwrite your edit.

-------

To prevent Zellij on startup (when set in .zshrc with possible NO_ZELLIJ variable):

```
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal custom
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal custom-local-command 'env NO_ZELLIJ=1 kitty'
nautilus -q
```

Change
```
"custom": Terminal(_("Terminal"), command_arguments=[]),
```
to
```
"custom": Terminal(_("Kitty"), command_arguments=[]),
```

-----

Maybe remove GNOME Terminal's Nautilus entry on Fedora:

```
sudo dnf remove gnome-terminal-nautilus
nautilus -q
```

-----

To have a shortcut

```
mkdir -p ~/.local/share/nautilus/scripts ~/.config/nautilus

cat > ~/.local/share/nautilus/scripts/open-kitty-here <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

uri="${NAUTILUS_SCRIPT_CURRENT_URI:-}"

if [[ "$uri" == file://* ]]; then
  dir="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1][7:]))' "$uri")"
else
  dir="$PWD"
fi

env NO_ZELLIJ=1 kitty --detach --directory "$dir"
EOF

chmod +x ~/.local/share/nautilus/scripts/open-kitty-here
```

Then bind it (F4 in this case):

```
cat > ~/.config/nautilus/scripts-accels <<'EOF'
F4 open-kitty-here
EOF

nautilus -q
```
