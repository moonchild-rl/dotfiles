# Dotfiles

Dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Setup on a new machine

Clone the repository & cd into it.

Create the symlinks:
```bash
stow backgrounds fuzzel kitty niri zsh
```

## Updating symlinks after changes

Restow:
```bash
stow -R backgrounds fuzzel kitty niri zsh
```

## Removing symlinks

To remove the symlinks for all packages:
```bash
stow -D backgrounds fuzzel kitty niri zsh
```
