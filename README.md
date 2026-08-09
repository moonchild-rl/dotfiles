# Dotfiles

My Dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Setup on a new machine

Clone the repository and cd into its directory.

Create symlinks for one or more packages:

```bash
stow <package_name(s)>
```

For example:

```bash
stow kitty niri zsh
```

## Updating symlinks after changes

Restow packages:

```bash
stow -R <package_name(s)>
```

## Removing symlinks

Delete the symlinks:

```bash
stow -D <package_name(s)>
```
