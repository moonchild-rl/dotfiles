# Put lines here that source programs
# Deno
[[ -f "$HOME/.deno/env" ]] && source "$HOME/.deno/env"

# broot
if [[ -r "$HOME/.config/broot/launcher/bash/br" ]]; then
  source "$HOME/.config/broot/launcher/bash/br"
fi
