# togglefile.zsh
# 1=use, 0=don't at startup

case "${HOST%%.*}" in
  moonstation)
    ZSH_PROMPT=p10k
    ZSH_STARTUP_FASTFETCH=1
    ZSH_STARTUP_RANDOM_TLDR=0
    ZSH_STARTUP_MEOW=0
    ZSH_STARTUP_ZELLIJ=0
    ZSH_USE_ZOXIDE=1
    ZSH_USE_ATUIN=1
    ZSH_PRIVATE_FILE="$HOME/Sync/Ricing/.zshrc-private.zsh"
    ;;

  moonpad)
    ZSH_PROMPT=p10k
    ZSH_STARTUP_FASTFETCH=1
    ZSH_STARTUP_RANDOM_TLDR=0
    ZSH_STARTUP_MEOW=1
    ZSH_STARTUP_ZELLIJ=0
    ZSH_USE_ZOXIDE=1
    ZSH_USE_ATUIN=0
    ZSH_PRIVATE_FILE=""
    ;;

  starport|server-*|vps-*)
    ZSH_PROMPT=none
    ZSH_STARTUP_FASTFETCH=0
    ZSH_STARTUP_RANDOM_TLDR=0
    ZSH_STARTUP_MEOW=0
    ZSH_STARTUP_ZELLIJ=0
    ZSH_USE_ZOXIDE=0
    ZSH_USE_ATUIN=0
    ZSH_PRIVATE_FILE=""
    ;;
esac
