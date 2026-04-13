# Put this after: eval "$(zoxide init zsh)"
z() {
  __zoxide_z "$@" || return

  # only show output in an interactive terminal (not scripts, not piped)
  [[ -o interactive && -t 1 ]] || return 0

  # simple, readable listing
  eza --group-directories-first --icons=auto
  # if you prefer a bit more detail, use:
  # eza -lah --group-directories-first --icons=auto --git
}
