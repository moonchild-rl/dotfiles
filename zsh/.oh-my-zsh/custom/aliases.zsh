alias n='nvim'
alias nv='nvim'
alias cd='z'
alias cat='bat --paging=never'
alias ls='eza --group-directories-first --icons=auto'
alias lt='ls --tree --level=10 --git-ignore --almost-all'
alias hl='rg -p --passthru'
alias ff='fastfetch'
alias neofetch='fastfetch'
alias icat='kitten icat'
alias yt='yt-dlp -f "bv*+ba/b" --format-sort-reset -S "height:720,+size,+br"'
alias ythd='yt-dlp -f "bv*+ba/b" --format-sort-reset -S "height:1080,+size,+br"'
alias lg='lazygit'
alias train='terminal-rain --thunder --sound'
alias wtr='curl wttr.in'
alias ats='atuin search -i'  # delete: Ctrl+O → Ctrl+D, or Ctrl+A → d
alias b='br'
alias cl='cargo install --list'

# Zellij
alias zj='zellij'
alias zjl='zellij list-sessions'
alias zjm='zellij attach --create main'
alias zjk='zellij kill-session main' # Kill/restart so config/layout/plugin changes are picked up.
alias zjd='zellij delete-all-sessions' # Delete dead/resurrectable sessions from cache.
