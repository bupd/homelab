#!/usr/bin/env bash
# Runs as alarm on a Pi (piped by deploy.sh --shell). zsh and nvim from brew.
# Login shell stays /usr/bin/bash on purpose: brew's zsh lives in /home/linuxbrew,
# and if it ever broke, a zsh login shell would lock out ssh. Interactive bash
# execs zsh instead; NO_ZSH=1 bash skips it.
set -euo pipefail
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
export HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1

for f in zsh neovim zoxide fzf git; do
  brew list --formula "$f" >/dev/null 2>&1 || brew install -q "$f"
done

if ! cmp -s ~/.zshrc.homelab ~/.zshrc 2>/dev/null; then
  [ -f ~/.zshrc ] && cp ~/.zshrc "$HOME/.zshrc.bak.$(date +%s)"
  cp ~/.zshrc.homelab ~/.zshrc
  echo "updated ~/.zshrc"
fi

marker="# >>> exec zsh (homelab) >>>"
if ! grep -qF "$marker" ~/.bashrc; then
  cat >> ~/.bashrc <<'EOT'

# >>> exec zsh (homelab) >>>
export EDITOR=nvim
export SUDO_EDITOR=/home/linuxbrew/.linuxbrew/bin/nvim
# Interactive shells hop into brew's zsh; fall back to bash if it is missing or broken.
if [[ $- == *i* && -z "${ZSH_VERSION:-}" && -z "${NO_ZSH:-}" ]] \
   && /home/linuxbrew/.linuxbrew/bin/zsh -c true 2>/dev/null; then
  exec /home/linuxbrew/.linuxbrew/bin/zsh -l
fi
# <<< exec zsh (homelab) <<<
EOT
  echo "added zsh hop to ~/.bashrc"
fi
echo "shell ok"
