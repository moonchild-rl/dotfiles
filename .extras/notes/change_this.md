alias code='flatpak run com.visualstudio.code --new-window'

but actually remove the flatpak and install it via RPM

---

move dms from dotfiles/niri to its correct place and unstow/restow it.
dms is machine generated and probably does not need to be in dotfiles/stow.

niri xkb:options might want this (then with de layout)

```
xkb {
    layout "us,de"
    variant "altgr-intl,"
    options "caps:escape,altwin:swap_lalt_lwin,grp:win_space_toggle,eurosign:e,grp_led:caps,compose:menu"
}
```
