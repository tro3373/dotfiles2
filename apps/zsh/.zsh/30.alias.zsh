##############################################
# Alias
##############################################
case "${OSTYPE}" in
  darwin*)
    #alias ls="ls -G -w"
    alias ls='ls -F --color=auto'
    alias xcode='open -a Xcode' # コマンドラインからXcode起動
    # alias gvim='open -a MacVim'     # コマンドラインからMacVim起動
    alias sudo='sudo -E ' # E: 環境変数のリセット無効(sudo vim で個人設定反映など)
    ;;
  linux*)
    alias ls='ls -F --color=auto'
    alias pbcopy='xsel --clipboard --input'       # Mac OS-Xのpbcopyの代わり
    alias pbpaste='xsel --clipboard --output'     # Mac OS-Xのpbpasteの代わり
    alias tmux-copy='tmux save-buffer - | pbcopy' # tmuxのコピーバッファとクリップボードを連携
    alias tmux='tmux -2'                          # Ubuntu12.04で256を使用するため
    alias git='nocorrect git'                     # Ubuntuで_gitと誤解されるため
    alias sudo='sudo -E '                         # E: 環境変数のリセット無効(sudo vim で個人設定反映など)
    if [[ -e /etc/arch-release ]]; then
      # y は yazi (末尾の y 関数) に譲ったため AUR ヘルパは yy
      if has yay; then
        alias yy=yay
      elif has yaourt; then
        alias yy=yaourt
      fi
      if has powerpill; then
        alias p='sudo powerpill'
      else
        alias p='sudo pacman'
      fi
    fi
    ;;
  freebsd*)
    alias ls="ls -G -w"
    ;;
  cygwin*)
    alias ls='ls -F --color=auto'
    alias apt-get='apt-cyg'         # apt-get emulate
    alias tmux='tmux -2'            # 256Color有効化
    alias sudo='echo "No sudo...";' # sudo がないので、エイリアスで逃げる
    ;;
  msys*)
    alias ls='ls -F --color=auto'
    alias pbcopy='cat - >/dev/clipboard'
    alias pbpaste='cat /dev/clipboard'
    alias tmux='tmux -2'            # 256Color有効化
    alias sudo='echo "No sudo...";' # sudo がないので、エイリアスで逃げる
    # alias nvim=$(which vim)
    alias vim=gvim
    alias git="PATH=/usr/bin winpty git"
    alias tig="PATH=/usr/bin winpty tig"
    ;;
esac

if has exa; then
  # alias ls="exa"
  function my_ls() {
    if [[ $* == "-ltra" ]]; then
      command exa -las modified
      return
    fi
    command exa "$@"
  }
  alias ls="my_ls"
fi
# eza の -F/--classify は値を取るオプションのため、末尾に置くと後続のパスを食う
alias l="ls -lh --classify=auto"
alias ll="ls -lah --classify=auto"
alias la="ls -a"
alias lf="ls --classify=auto"
alias lg="lazygit"
alias du="du -h"
alias df="df -h"
alias su="su -l"
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias tree='tree --charset ascii'
alias pod='nocorrect pod'
alias where="command -v"
alias diff="diff -Nru"
alias diffs="diff -Nru --strip-trailing-cr"
alias gp="git pull --rebase"
alias gb="git branch -vv"
alias gc="git commit"
alias gr="git remote -v"
alias gre="git_reset"
alias grr="git_reset -r"
alias gs="git status"
alias gn="git_no_merges"
alias li="linear"
# alias gt="git tag"
# alias gt="git_worktree"
gt() {
  if [[ $1 == '-e' ]]; then
    git_worktree "$@"
    return
  fi
  local out
  out=$(git_worktree "$@") || return
  [[ -z $out ]] && return
  if [[ -d $out ]]; then
    wlog "==> Changing directory to: $out"
    cd -- "$out"
    return
  fi
  echo "$out"
}
modd() {
  res=$(git_select_modified_directory "$@")
  [[ -z $res ]] && return
  wlog "==> Changing directory to: $res"
  cd -- "$res"
}
if has git-sim; then
  alias gsm="git-sim"
fi
if has sync_src; then
  alias ssn="sync_src"
fi
if has nvim; then
  alias vim="nvim"
fi
if has aws; then
  alias awsl='aws --endpoint-url=http://localhost:4566'
fi
if has piknik; then
  alias pc='piknik -copy'
  alias pp='piknik -paste'
  # NOTE:
  # - Move: Copy the content of the clipboard to the piknik storage and clear the clipboard.
  #   Retrieve the content of the clipboard, spit it to the standard output and clear the clipboard.
  #   Not necessarily in this order. Only one lucky client will have the privilege to see the content.
  alias pm='piknik -move'
  alias pz='piknik -copy < /dev/null'
  pf() { piknik -copy <$1; }
fi
alias_with_compdef() {
  local cmd=$1
  if ! has $cmd; then
    return
  fi
  local alias=$2
  local defname="${3:-_files}"
  alias $alias=$cmd
  compdef $defname $alias=$cmd
}
alias_with_compdef terraform tf
# alias v=vim
alias vi=vim
alias f="find -name"
alias j="jobs -l"
alias cddot="cd $DOTPATH"
alias history="history -i"
alias_with_compdef git g _git
alias_with_compdef docker d
alias_with_compdef systemctl s _systemctl
alias_with_compdef make m _make
# alias_with_compdef code c
# if has claude && has specstory; then
#   alias claude="specstory claude"
# fi
alias_with_compdef claude c
alias_with_compdef cursor r
alias_with_compdef tasks t
alias_with_compdef flutter fl
alias_with_compdef speedtest st
alias codeimg="germanium"
alias germ="germanium"
alias tb="tmux_buffer"
if has mmv; then
  mmv() {
    if [[ $# -ne 0 ]]; then
      command mmv "$@"
      return
    fi
    command mmv ./*
  }
fi

gm() {
  [[ -z $* ]] && echo "Specify commit message" 1>&2 && return
  git commit -m "$*"
}

# --------------------------------------------------------
# ag 設定
# --------------------------------------------------------
if has ag; then
  if [ "${OSTYPE}" = "msys" ]; then
    # . が最後につかないと固まるので暫定
    org_ag=$(which ag)
    function mymsys_ag() {
      $org_ag -S $* .
    }
    alias ag="mymsys_ag"
  else
    # Smart Case による検索を有効に設定する
    alias ag='ag -S'
  fi
  alias agh='ag --hidden'
fi

# --------------------------------------------------------
# pt 設定
# --------------------------------------------------------
if has pt; then
  if [ "${OSTYPE}" = "msys" ]; then
    # . が最後につかないと固まるので暫定
    org_pt=$(which pt)
    function mymsys_pt() {
      winpty $org_pt -S $* .
    }
    alias pt="mymsys_pt"
  else
    # Smart Case による検索を有効に設定する
    alias pt='pt -S'
  fi
  alias pth='pt --hidden'
fi

# --------------------------------------------------------
# rg 設定
# --------------------------------------------------------
if has rg; then
  alias rg='rg -S'
  rgf() {
    local args="$@"
    rg --files | rg -S "$args"
  }
fi

if has rga; then
  rga-fzf() {
    RG_PREFIX="rga --files-with-matches"
    local file
    file="$(
      FZF_DEFAULT_COMMAND="$RG_PREFIX '$1'" \
        fzf --sort --preview="[[ ! -z {} ]] && rga --pretty --context 5 {q} {}" \
        --phony -q "$1" \
        --bind "change:reload:$RG_PREFIX {q}" \
        --preview-window="70%:wrap"
    )" &&
      echo "opening $file" &&
      open "$file"
  }
fi

# --------------------------------------------------------
# fzf 設定
# --------------------------------------------------------
if has fzf; then
  # Setting ag as the default source for fzf
  if has rg; then
    export FZF_DEFAULT_COMMAND='rg --files --hidden --follow --glob "!.git/*"'
  elif has pt; then
    export FZF_DEFAULT_COMMAND='pt --hidden -g ""'
  elif has ag; then
    export FZF_DEFAULT_COMMAND='ag --hidden -g ""'
  fi
  if [[ -n $FZF_DEFAULT_COMMAND ]]; then
    # To apply the command to CTRL-T as well
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  fi
fi

if has shfmt; then
  alias shfmt="shfmt -i 2 -ci -s"
fi

# http://qiita.com/yuku_t/items/4ffaa516914e7426419a
function ssh() {
  [[ ! -e $HOME/.ssh/socks ]] && mkdir -p $HOME/.ssh/socks
  TERM=xterm
  local window_name=$(tmux_ssh_dog -p "$@")
  command ssh "$@"
  tmux_ssh_dog -r "$window_name" "$@"
}

alias tmux_a='tmux set-option -g prefix C-a'
alias tmux_b='tmux set-option -g prefix C-b'

## --------------------------------------------------------
## gtags (Pygments)
## --------------------------------------------------------
#if type pip > /dev/null 2>&1; then
#    if pip list | grep Pygments > /dev/null 2>&1; then
#        # System has Pygments.
#        # Which plugin parser in use? => type 'gtags --debug'.
#        export GTAGSLABEL=pygments
#    fi
#fi

## EnterKey bindings
##
#_success_enter() {
#  zle accept-line
#  if [[ -z "$BUFFER" ]]; then
#      :
#  fi
#}
#zle -N _success_enter
#bindkey "\C-m" _success_enter

#
# 'cd ..' する
#
function cd_up() {
  cd ../
  zle reset-prompt # redraw prompt
}
zle -N cd_up              # redist `cd_up` as widget
bindkey '^f' vi-kill-line # デフォルトのキーバインド(^U)を変更
bindkey '^u' cd_up
function tb() {
  ~/.dot/bin/tmux_buffer
}
zle -N tb
bindkey '^v' tb
function _prp() {
  ~/.dot/bin/prp
}
zle -N _prp
bindkey '^[m' _prp # Alt-m

function supported() {
  local cmd="$*"
  if ! has $cmd; then
    echo "Not supported(No $cmd command exist)" 1>&2
    return 1
  fi
  return 0
}
function cd_dir() {
  local d="$*"
  if [ -n "$d" ]; then
    BUFFER="cd $d"
    zle accept-line # execute buffer string
  fi
  zle -R -c # refresh
}
function cd_src_root() {
  # 選択 + tmux セッション移動の本体は bin/cd-src-root に集約 (SSOT)。
  # tmux 外 / 現セッションが数字名のときだけパスが返るので cd する。
  # LBUFFER (カーソル左のバッファ) を fzf の初期クエリとして渡す。
  local src=$(cd-src-root "$LBUFFER")
  [[ -n $src ]] && cd_dir "$src"
  zle -R -c
}
zle -N cd_src_root
bindkey '^]' cd_src_root

function _find_dirs() {
  find . -type d -maxdepth 5 2>/dev/null |
    grep -E -v '/\.' |
    grep -v 'node_modules' |
    grep -v 'bower_components'
}
function cd_under_d() {
  supported fzf || return
  # LBUFFER: 現在のカーソル位置よりも左のバッファ
  # RBUFFER: 現在のカーソル位置を含む右のバッファ
  local src=$(
    _find_dirs |
      fzf --query "$LBUFFER" --preview "ls -laF {}"
  )
  cd_dir "$src"
}
zle -N cd_under_d
bindkey '^k' cd_under_d

function _paste_img() {
  has paste_img || return
  paste_img -d "$(pwd)"
  zle reset-prompt # redraw prompt
}
zle -N _paste_img
bindkey '^[p' _paste_img

rm_cache() {
  # rm -rf ~/.cache/zsh
  find ~/.cache/zsh/ -type f |
    fzf -m \
      --preview 'echo {}; echo "----------------------------------------"; head -100 {}' \
      --select-1 \
      --exit-0 \
      --bind 'ctrl-l:toggle-all,ctrl-g:toggle-preview' |
    xargs rm -v
}

fpath() {
  echo "${fpath[@]}" | tr ' ' '\n'
}

# yazi を起動し、終了時のカレントディレクトリをシェルに引き継ぐ (yazi 公式 wrapper)
y() {
  supported yazi || return
  local tmp
  tmp=$(mktemp -t "yazi-cwd.XXXXXX") || return
  yazi "$@" --cwd-file="$tmp"
  local cwd
  IFS= read -r -d '' cwd <"$tmp"
  [[ -n $cwd && $cwd != "$PWD" ]] && builtin cd -- "$cwd"
  # mktemp の一時ファイルなので trash ではなく rm (毎回ゴミ箱に溜めない)
  rm -f -- "$tmp"
}

# insert-date() {
#   LBUFFER+=$(date +%Y%m%d)
# }
# zle -N insert-date
# bindkey '^;' insert-date
