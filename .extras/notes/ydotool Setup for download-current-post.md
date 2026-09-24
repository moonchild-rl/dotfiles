# ydotool Setup for `download-current-post`

For Fedora Workstation / GNOME.

## Install

```bash
sudo dnf install ydotool
```

## Get UID and GID

```bash
id -u
id -g
```

Example:

```text
1000
1000
```

Use those values below.

## Configure `ydotoold`

```bash
sudo systemctl edit ydotool.service
```

Paste:

```ini
[Service]
RuntimeDirectory=ydotool
RuntimeDirectoryMode=0755

ExecStart=
ExecStart=/usr/bin/ydotoold --socket-path=/run/ydotool/socket --socket-perm=0660 --socket-own=1000:1000 --mouse-off
```

Replace `1000:1000` with your actual `UID:GID` if different.

## Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ydotool.service
```

---

## Verify

```bash
systemctl is-enabled ydotool.service
systemctl is-active ydotool.service
```

Expected:

```text
enabled
active
```

Check the socket:

```bash
stat -c '%A %U:%G %n' \
    /run/ydotool \
    /run/ydotool/socket
```

The socket should look approximately like:

```text
srw-rw---- USER:USER /run/ydotool/socket
```

Test access:

```bash
YDOTOOL_SOCKET=/run/ydotool/socket \
    ydotool key 29:1 29:0

echo $?
```

Expected:

```text
0
```

## Script requirement

`download-current-post` should contain:

```bash
export YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/run/ydotool/socket}"
```

Then test the complete setup with:

```text
Win+Shift+D
```

## Notes

- No `ydotool` group membership is required with this setup.
- `/run/ydotool/socket` is temporary and is recreated automatically on boot by `ydotool.service`.
- Do not use `chmod 666` on the socket.
- On another machine, always check `id -u` and `id -g` instead of assuming `1000:1000`.
