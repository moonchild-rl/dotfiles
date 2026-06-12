alias n='nvim'
alias nv='nvim'
alias cd='z'
alias cat='bat --paging=never'
alias ls='eza --group-directories-first --icons=auto'
alias lt='ls --icons --tree --level 2'
alias hl='rg -p --passthru'
alias ff='fastfetch'
alias neofetch='fastfetch'
alias icat='kitten icat'
alias yt='yt-dlp -f "bv*+ba/b" --format-sort-reset -S "height:720,+size,+br"'
alias lg='lazygit'
alias train='terminal-rain --thunder --sound'

# Zellij
alias zj='zellij'
alias zjl='zellij list-sessions'
alias zjm='zellij attach --create main'

# Kill/restart the active "main" session so config/layout/plugin changes are picked up.
alias zjk='zellij kill-session main'

# Delete dead/resurrectable sessions from cache.
alias zjd='zellij delete-all-sessions'
