#!/bin/sh
set -eux

prefix=/home/linuxbrew/.linuxbrew
homebrew_ref="${HOMEBREW_REF:-}"

if [ -z "$homebrew_ref" ]; then
  homebrew_ref="$(
    git ls-remote --tags https://github.com/Homebrew/brew.git 'refs/tags/[0-9]*' \
      | sed 's#.*refs/tags/##' \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -V \
      | tail -n 1
  )"
fi

mkdir -p "$prefix/Homebrew" "$prefix/bin" "$prefix/sbin" "$prefix/Cellar" "$prefix/Caskroom" "$prefix/Frameworks" "$prefix/etc" "$prefix/include" "$prefix/lib" "$prefix/opt" "$prefix/share" "$prefix/var"
git clone --depth 1 --branch "$homebrew_ref" https://github.com/Homebrew/brew.git "$prefix/Homebrew"
ln -sfn ../Homebrew/bin/brew "$prefix/bin/brew"
ln -sfn "$prefix/bin/brew" /usr/local/bin/brew

cat > /etc/profile.d/homebrew.sh <<EOF
eval "\$($prefix/bin/brew shellenv)"
export HOMEBREW_NO_AUTO_UPDATE=1
EOF
chmod 0644 /etc/profile.d/homebrew.sh

chown -R 1000:1000 /home/linuxbrew

su bupd -c "eval \"\$($prefix/bin/brew shellenv)\" && export HOMEBREW_NO_AUTO_UPDATE=1 && brew --version && brew config"
