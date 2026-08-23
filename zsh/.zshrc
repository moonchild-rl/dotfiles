# First block are commands that have to go before instant prompt
# Show system info at shell startup
if (( $+commands[fastfetch] )); then
  fastfetch
fi

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# If you come from bash you might have to change your $PATH.
export PATH=$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Theme
ZSH_THEME=""
if [[ -r "${ZSH_CUSTOM:-$ZSH/custom}/themes/powerlevel10k/powerlevel10k.zsh-theme" ]] ||
   [[ -r "$ZSH/themes/powerlevel10k/powerlevel10k.zsh-theme" ]]; then
  ZSH_THEME="powerlevel10k/powerlevel10k"
else
  print -u2 "zsh: Powerlevel10k theme was not found. Continuing without an Oh My Zsh theme."
fi

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Add wisely, as too many plugins slow down shell startup.
plugins=(git sudo fzf fzf-tab zsh-autosuggestions fast-syntax-highlighting)

source "$ZSH/oh-my-zsh.sh"

# For using end key after paste without putting in a suggestion (Space also works)
bindkey '\eOF' .end-of-line

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
elif (( $+commands[nvim] )); then
  export EDITOR='nvim'
elif (( $+commands[vim] )); then
  export EDITOR='vim'
else
  export EDITOR='nano'
fi

# Compilation flags
# export ARCHFLAGS="-arch $(uname -m)"

# Make less nicer
export LESS='-RFXM -S -i -J --mouse'
export LESSHISTFILE='-'

# Set personal aliases, overriding those provided by Oh My Zsh libs,
# plugins, and themes. Aliases can be placed here, though Oh My Zsh
# users are encouraged to define aliases within a top-level file in
# the $ZSH_CUSTOM folder, with .zsh extension. Examples:
# - $ZSH_CUSTOM/aliases.zsh

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
if [[ -r "$HOME/.p10k.zsh" ]]; then
  source "$HOME/.p10k.zsh"
else
  print -u2 "zsh: $HOME/.p10k.zsh was not found."
fi

# To make zoxide work
if (( $+commands[zoxide] )); then
  eval "$(zoxide init zsh)"
fi

# Atuin shell history
if (( $+commands[atuin] )); then
  eval "$(atuin init zsh --disable-ctrl-r --disable-up-arrow)"

  _atuin_redraw() {
    # Refresh syntax highlighting plugins after programmatically changing BUFFER.
    if (( $+functions[_fast-highlight] )); then
      _fast-highlight 2>/dev/null || true
    elif (( $+functions[_zsh_highlight] )); then
      _zsh_highlight 2>/dev/null || true
    fi

    zle -R
  }

  # Reset prompt used to prevent prompt disappearing after exiting fzf with escape
  _atuin_full_redraw() {
    # Refresh syntax highlighting plugins after programmatically changing BUFFER.
    if (( $+functions[_fast-highlight] )); then
      _fast-highlight 2>/dev/null || true
    elif (( $+functions[_zsh_highlight] )); then
      _zsh_highlight 2>/dev/null || true
    fi

    zle reset-prompt
    zle -R
    return 0
  }

  # Make Ctrl-R use fzf but with atuin's db
  atuin_fzf_history_widget() {
    local selected
    local -a fzf_opts

    fzf_opts=(
      --read0
      --height=40%
      --layout=default
      --scheme=history
      --bind='ctrl-r:toggle-sort,alt-r:toggle-raw'
      --wrap
      --wrap-sign=$'\t↳ '
      --highlight-line
      --multi
      --query "$LBUFFER"
    )

    selected="$(
      atuin history list --cmd-only --print0 |
        perl -0 -e 'print reverse <>' |
        perl -0 -ne 'print if !$seen{$_}++' |
        fzf "${fzf_opts[@]}"
    )"

    if [[ -n "$selected" ]]; then
      BUFFER="$selected"
      CURSOR=${#BUFFER}
    fi

    _atuin_full_redraw
  }

  zle -N atuin_fzf_history_widget
  bindkey '^R' atuin_fzf_history_widget

  # This block restores normal up-arrow behavior but with atuin's db.
  typeset -ga _atuin_arrow_history=()
  typeset -gi _atuin_arrow_index=0
  typeset -g  _atuin_arrow_saved_buffer=""

  _atuin_arrow_load_history() {
    _atuin_arrow_history=()

    local cmd
    while IFS= read -r -d $'\0' cmd; do
      [[ -n "$cmd" ]] && _atuin_arrow_history+=("$cmd")
    done < <(
      atuin history list --cmd-only --print0 2>/dev/null |
        perl -0 -e '
          @cmds = <>;
          @cmds = @cmds[-1000..-1] if @cmds > 1000;
          print reverse @cmds;
        ' |
        perl -0 -ne 'print if !$seen{$_}++'
    )
  }

  _atuin_arrow_up() {
    # First Up press for this prompt: load recent Atuin history.
    if (( _atuin_arrow_index == 0 )); then
      _atuin_arrow_saved_buffer="$BUFFER"
      _atuin_arrow_load_history
    fi

    if (( ${#_atuin_arrow_history} == 0 )); then
      _atuin_redraw
      return 0
    fi

    if (( _atuin_arrow_index < ${#_atuin_arrow_history} )); then
      (( _atuin_arrow_index++ ))
      BUFFER="${_atuin_arrow_history[$_atuin_arrow_index]}"
      CURSOR=${#BUFFER}
    fi

    _atuin_redraw
  }

  _atuin_arrow_down() {
    if (( _atuin_arrow_index > 1 )); then
      (( _atuin_arrow_index-- ))
      BUFFER="${_atuin_arrow_history[$_atuin_arrow_index]}"
      CURSOR=${#BUFFER}
    elif (( _atuin_arrow_index == 1 )); then
      _atuin_arrow_index=0
      BUFFER="$_atuin_arrow_saved_buffer"
      CURSOR=${#BUFFER}
    fi

    _atuin_redraw
  }

  _atuin_arrow_reset() {
    _atuin_arrow_index=0
    _atuin_arrow_saved_buffer=""
    _atuin_arrow_history=()
  }

  zle -N _atuin_arrow_up
  zle -N _atuin_arrow_down

  bindkey '^[[A' _atuin_arrow_up
  bindkey '^[OA'  _atuin_arrow_up
  bindkey '^[[B' _atuin_arrow_down
  bindkey '^[OB'  _atuin_arrow_down

  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _atuin_arrow_reset

  # Grey zsh_autosuggestions
  ZSH_AUTOSUGGEST_STRATEGY=(atuin completion)

  # Do not use the completion strategy once the current buffer contains a URL.
  ZSH_AUTOSUGGEST_COMPLETION_IGNORE='*://*'

  # Make Tab do nothing. No local file/dir completion and no errors/hangs.
  _downloader_wrapper_no_completion() {
    return 0
  }
  compdef _downloader_wrapper_no_completion burl

  # Disable zsh_history
  unset HISTFILE
fi

# Load modular zsh fragments in sorted order
for f in ~/.config/zsh/rc.d/*.zsh(N); do
  source "$f"
done

# Source file with private components for .zshrc on moonstation only
if [[ "${HOST%%.*}" == "moonstation" ]] &&
   [[ -r "$HOME/Sync/Ricing/.zshrc-private.zsh" ]] &&
   [[ "${TERM_PROGRAM:-}" != "vscode" ]]; then
  source "$HOME/Sync/Ricing/.zshrc-private.zsh"
fi

# Auto-start Zellij for interactive local shells only
# Uncomment the following line to enable Zellij autostart:
# ZSH_STARTUP_ZELLIJ=1
if [[ "${ZSH_STARTUP_ZELLIJ:-0}" == "1" ]] &&
   [[ -o interactive ]] &&
   [[ -z "$ZELLIJ" ]] &&
   [[ -z "$SSH_CONNECTION" ]] &&
   [[ -z "$SSH_TTY" ]] &&
   [[ "$TERM_PROGRAM" != "vscode" ]] &&
   (( $+commands[zellij] )); then
  zellij attach --create main
fi
