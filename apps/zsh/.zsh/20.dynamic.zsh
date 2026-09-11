_dynamic() {
  [[ ! -e $CACHE_D ]] && mkdir -p $CACHE_D

  _cache_load whoami
  if is_msys; then
    export WINHOME=/c/Users/$WHOAMI
    export MSYS=winsymlinks:nativestrict # enable symbolic link in admined msys
  fi
  if is_wsl; then
    export WSL=1
    unsetopt BG_NICE # (niceness)Background 優先度を上げる(BG_NICEのdefaultは低優先度)
    export WINHOME=/mnt/c/Users/$WHOAMI
  fi

  _dynamic_exports
  export GEN_PATH_F=$CACHE_D/path
  _cache_load path
  export GEN_MANPATH_F=$CACHE_D/manpath
  _cache_load manpath
  _cache_load lscolors

  _cache_loads sheldon uv direnv gh glab gog sops
}

_cache_loads() {
  for src in "$@"; do
    has $src || continue
    _cache_load $src
  done
}

_cache_load() {
  local _src=$1
  local target="$CACHE_D/$_src"
  local cat_fn="_cat_$_src"
  if [[ -e $target ]]; then
    source $target
    return
  fi
  echo "===> calling $cat_fn.." 1>&2
  eval "$cat_fn" >$target.tmp
  mv $target.tmp $target
}

_cat_whoami() {
  _me=$(is_wsl && cmd.exe /c "echo %USERNAME%" 3>/dev/null | tr -d '\r' || whoami)
  echo "export WHOAMI=$_me"
}

_dynamic_exports() {
  _dynamic_exports_android
}

_dynamic_exports_android() {
  local _android_homes=("Android/Sdk" "Library/Android/sdk")
  echo "${_android_homes[@]}" |
    tr " " "\n" |
    while read -r line; do
      local _android_home=${HOME}/$line
      [[ ! -e $_android_home ]] && continue
      export ANDROID_HOME=$_android_home
      return
    done
}

add_path() {
  # for .works.zsh
  [[ -e $GEN_PATH_F ]] && return
  export PATH="$@:$PATH"
}

add_manpath() {
  # for .works.zsh
  [[ -e $GEN_MANPATH_F ]] && return
  export MANPATH="$@:$MANPATH"
}

_cat_path() {
  #------------------------------------------------------
  # NOTE: add_path: Added later has high priority
  #------------------------------------------------------

  # For Win.
  add_path "/mingw64/bin" # for silver searcher ag in msys
  add_path "/mnt/c/Program Files (x86)/Google/Chrome/Application"
  add_path "/mnt/c/Program Files/Google/Chrome/Application"
  # add_path $HOME/win/tools/sublime-text-3
  # add_path $HOME/win/tools/atom/resources/app/apm/bin
  add_path "${HOME}/win/scoop/shims" # scoop

  # For Mac gnu command tools
  if is_mac; then
    find /opt/homebrew/opt/*/libexec/gnubin -type d 2>/dev/null |
      while read -r line; do
        add_path "$line"
      done
  fi

  # add_path ${JAVA_HOME}/bin # for java
  # add_path ${M2_HOME}/bin # for maven

  # For Android
  if [[ -n $ANDROID_HOME ]]; then
    add_path ${ANDROID_HOME}/tools
    add_path ${ANDROID_HOME}/tools/bin
    add_path ${ANDROID_HOME}/platform-tools
    add_path ${ANDROID_HOME}/cmdline-tools/latest/bin
  fi
  add_path ${HOME}/win/AppData/Local/Android/Sdk/platform-tools # for Android Win. Use adb command in windows
  add_path ${HOME}/android-studio/bin                           # for android

  # add main env path
  add_path /usr/local/sbin
  add_path /usr/local/bin
  add_path /snap/bin
  add_path /opt/bin                  # for docker-machine
  add_path /usr/local/heroku/bin     # for heroku
  add_path /opt/google-cloud-cli/bin # for gcloud

  # add_path ${HOME}/.fzf/bin
  # add_path ${HOME}/.anyenv/bin
  add_path $GOBIN
  add_path $CARGO_HOME/bin
  add_path ${HOME}/.cargo/bin
  add_path ${HOME}/.local/bin
  # add_path $BUN_INSTALL/bin # install via asdf
  add_path "$HOME/.asdf/shims"
  add_path "$HOME/.npm-global/bin"

  add_path ${DOTPATH}/bin
  add_path ${HOME}/.ldot/bin
  add_path ${HOME}/.local-bin
  add_path ${HOME}/bin

  # NOTE: Load .works.zsh to execute add_path.
  # 90.additional.zsh load .works.zsh again.
  load_zsh ~/.works.zsh

  echo "export PATH=$(echo "$PATH" | _uniq_path)"
}

_cat_manpath() {
  # For Mac sed
  # add_manpath "/usr/local/opt/coreutils/libexec/gnuman"
  # add_manpath "/usr/local/opt/findutils/libexec/gnuman"
  # add_manpath "/usr/local/opt/gnu-sed/libexec/gnuman"
  # add_manpath "/usr/local/opt/gnu-tar/libexec/gnuman"
  # add_manpath "/usr/local/opt/grep/libexec/gnuman"
  # add_manpath "/usr/local/opt/gnu-indent/libexec/gnuman"
  # add_manpath "/usr/local/opt/gnu-which/libexec/gnuman"
  if is_mac; then
    find /opt/homebrew/opt/*/libexec/gnuman -type d 2>/dev/null |
      while read -r line; do
        add_manpath "$line"
      done
  fi
  # [[ -z $MANPATH ]] && echo "echo hoge" && return
  # [[ -z $MANPATH ]] && echo "export" && return
  _tmp=$(echo "$MANPATH" | _uniq_path)
  echo "export MANPATH=$_tmp:"
}

_uniq_path() {
  local _tmp=
  for _p in $(cat - | tr ":" " "); do
    [[ -z $_p ]] && continue
    [[ ! -e $_p ]] && continue
    echo ":$_tmp:" | grep ":$_p:" >&/dev/null && continue # add if not added
    echo "====> p: $_p" 1>&2
    [[ -n $_tmp ]] && _tmp="$_tmp:"
    _tmp="$_tmp$_p"
  done
  echo "$_tmp"
}

_cat_lscolors() {
  if [[ -L ${HOME}/.dircolors || -e ${HOME}/.dircolors ]]; then
    has dircolors && dircolors ${HOME}/.dircolors && return
    has gdircolors && gdircolors ${HOME}/.dircolors && return
  fi
  echo "export LSCOLORS=exfxcxdxbxegedabagacad"
}

_cat_sheldon() {
  sheldon source
}

_cat_direnv() {
  direnv hook zsh
}

# _cat_anyenv() {
#   anyenv init -
# }

_cat_uv() {
  uv generate-shell-completion zsh
}

_cat_gh() {
  gh completion -s zsh
}

_cat_glab() {
  glab completion -s zsh
}

_cat_gog() {
  gog completion zsh
}

_cat_sops() {
  sops completion zsh
}

_dynamic
