sudo dnf copr enable monkeygold/nautilus-open-any-terminal
sudo dnf install nautilus-open-any-terminal

gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal kitty

nautilus -q

------

To get exactly:

```Open in Kitty```

for the background menu, you would need to patch the installed extension file and change:

```LOCAL_LABEL = _("Open {} Here")```

to:

```LOCAL_LABEL = _("Open in {}")```

You can find the installed file with:

```rpm -ql nautilus-open-any-terminal | grep '\.py$'```

Should be: ```/usr/share/nautilus-python/extensions/nautilus_open_any_terminal.py```

Then edit the relevant Python file with sudo, restart Nautilus:

```nautilus -q```

Note: a package update may overwrite your edit.
