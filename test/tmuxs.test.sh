#!/usr/bin/env bash

# bin/tmuxs のユニットテスト (実 tmux 不要)。2 グループを 1 ファイルに統合。
#   * 管理サブコマンド系: __kill / __list / __preview / __cleanup / __switch
#   * イベント/フック系  : tmuxs waiting|running|idle|remove
#
# PATH 先頭の偽 tmux が mutating 呼び出しをログ + 一時ファイルに記録し、query
# (display-message / capture-pane / list-sessions / list-panes / show) を
# 一時ファイル・env で答えるので実 tmux server を触らない。
# 偽 tmux の状態 (@tmuxs_* option 等) は FAKE_STATE_DIR 配下に永続化し、
# hook の複数回起動 (別プロセス) 間でも tmux server のように状態を共有する。
#
#   test/tmuxs   # 全テスト実行 (実 tmux 不要)

# tmpdir 配下に偽 tmux を生成し、$PATH 先頭に差し込む。
# FAKE_TMUX_LOG / FAKE_STATE_DIR を偽 tmux が参照できるよう export する。
#
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmuxs_bin=$(cd "${script_dir}/../bin" && pwd)/tmuxs

setup_fake_tmux() {
  fakebin="${tmpdir}/bin"
  mkdir -p "${fakebin}"
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_TMUX_LOG="${tmpdir}/calls.log"
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_STATE_DIR="${tmpdir}/tmuxstate"
  mkdir -p "${FAKE_STATE_DIR}"
  write_fake_tmux
  chmod +x "${fakebin}/tmux"
}

# テスト用 git。グローバル設定を無効化してあるので identity を毎回渡す。
tgit() {
  git -c user.email=t@example.com -c user.name=t "$@"
}

# list のリポジトリ判定は実物の git に問い合わせるので、tmpdir 配下に本物の
# リポジトリ・worktree・git 管理外ディレクトリを用意する。
# 開発者の git 環境に左右されないよう、探索の上限とグローバル設定の無効化は
# main が済ませてある (TMPDIR が git 管理下でも管理外ディレクトリが親を拾わない)。
# サブシェル関数 + set -e にして、途中で失敗したら非ゼロで抜ける。
setup_test_repos() (
  set -e
  mkdir -p "${repos}" "${tmpdir}/plain"
  local r
  for r in alpha beta; do
    tgit init -q -b main "${repos}/${r}"
    tgit -C "${repos}/${r}" commit -q --allow-empty -m init
  done
  # bin/git_worktree と同じ '<repo>-worktree/<branch>' 配置。
  tgit -C "${repos}/alpha" worktree add -q "${repos}/alpha-worktree/br1" -b br1
  # common dir が '<repo>/.git' にならない 2 配置。
  #   submodule => '<super>/.git/modules/sub' / bare => '<repo>.git'
  tgit init -q -b main "${repos}/super"
  tgit -C "${repos}/super" commit -q --allow-empty -m init
  tgit -C "${repos}/super" -c protocol.file.allow=always \
    submodule add -q ../alpha sub
  tgit init -q --bare "${repos}/bare.git"
  # list のマーク列用。.tasks.md の front matter で done を出し分ける worktree と、
  # front matter を持たない親リポの .tasks.md (= 印を出さない側)。
  tgit -C "${repos}/alpha" worktree add -q "${repos}/alpha-worktree/done" -b brdone
  tgit -C "${repos}/alpha" worktree add -q "${repos}/alpha-worktree/undone" -b brundone
  printf -- '---\ntitle: t\ndone: true\n---\n\n- [ ] rest\n' \
    >"${repos}/alpha-worktree/done/.tasks.md"
  printf -- '---\ntitle: t\ndone: false\n---\n' \
    >"${repos}/alpha-worktree/undone/.tasks.md"
  printf -- '- [ ] plain\n' >"${repos}/beta/.tasks.md"
)

# ANSI エスケープだけを落とす (タブ区切りは残す)。
strip_ansi() {
  sed -e $'s/\033\\[[0-9;]*m//g'
}

# __list の生出力。色そのものを検証するテストはこちらを使う。
run_list() {
  PATH="${fakebin}:${PATH}" "${tmuxs_bin}" __list
}

# __list の生出力から ANSI エスケープを落としたもの。
list_plain() {
  run_list | strip_ansi
}

# マーカーを全消しする。list 系テストの前処理 (reset は hook 系専用)。
clear_markers() {
  rm -f "${TMUXS_MARKER_DIR}"/* 2>/dev/null || true
}

# list 用 FAKE_PANES を組む。引数は (session pane_id path) の 3 つ組の繰り返し。
# 二重引用符の中では \t が展開されないため printf で組む。
set_fake_panes() {
  FAKE_PANES=$(printf '%s\t%s\t%s\n' "$@")
  export FAKE_PANES
}

# 偽 tmux 本体を書き出す。mutating 呼び出しはログ/状態へ記録し、query は env で答える。
write_fake_tmux() {
  cat >"${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
log=${FAKE_TMUX_LOG:?}
state=${FAKE_STATE_DIR:?}
case "$1" in
  display-message) printf '%s\n' "${FAKE_CURRENT:-}" ;;
  capture-pane)    printf '%s\n' "${FAKE_CAPTURE:-}" ;;
  list-sessions)   printf '%s\n' "${FAKE_SESSIONS:-}" | grep -v '^$' || true ;;
  list-panes)      printf '%s\n' "$*" >>"$log"
                   printf '%s\n' "${FAKE_PANES:-}" | grep -v '^$' || true ;;
  show)
    cat "${state}/${3#@}" 2>/dev/null || true
    ;;
  set)
    if [[ $2 == -gu ]]; then
      rm -f "${state}/${3#@}"
      printf 'set %s %s\n' "$2" "$3" >>"${log}"
    else
      printf '%s' "$4" >"${state}/${3#@}"
      printf 'set %s %s %s\n' "$2" "$3" "$4" >>"${log}"
    fi
    ;;
  switch-client | kill-session | select-window | select-pane) printf '%s\n' "$*" >>"$log" ;;
  *) printf 'UNHANDLED %s\n' "$*" >>"$log" ;;
esac
FAKE
}

# desc / expected / actual を比較し、呼び出し元 main の pass・fail カウンタを更新する。
check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ ${expected} != "${actual}" ]]; then
    fail=$((fail + 1))
    printf 'FAIL - %s\n  expected: %q\n  actual:   %q\n' "${desc}" "${expected}" "${actual}"
    return
  fi
  pass=$((pass + 1))
  printf 'ok   - %s\n' "${desc}"
}

# 偽 tmux のログをクリアし、tmuxs __kill を fakebin 経由で実行する。
run_kill() {
  local target="$1"
  : >"${FAKE_TMUX_LOG}"
  PATH="${fakebin}:${PATH}" "${tmuxs_bin}" __kill "${target}"
}

# イベントエントリ (`tmuxs <state>`) を fakebin 経由で別プロセス起動する。
run_hook() {
  PATH="${fakebin}:${PATH}" "${tmuxs_bin}" "$@"
}

# 各 hook テスト前の共通リセット。マーカー・偽 tmux 状態・ログ・pane env を初期化する。
reset() {
  clear_markers
  rm -f "${FAKE_STATE_DIR}"/* 2>/dev/null || true
  # tmux.conf 相当: 通常 status-style を seed (band_on がこれを退避し band_off で復元)。
  printf 'bg=colour234,fg=blue,default' >"${FAKE_STATE_DIR}/status-style"
  : >"${FAKE_TMUX_LOG}"
  # lint-ignore: uppercase tmuxs / tmux が読む env 名は呼ばれる側が決める
  export TMUX_PANE='%5' TMUX='fake' FAKE_PANES='%5'
}

marker_content() {
  cat "${TMUXS_MARKER_DIR}/$1" 2>/dev/null || printf '__NONE__'
}

# tmux user option (@tmuxs_*) の現在値。未設定は __NONE__。
opt() {
  cat "${FAKE_STATE_DIR}/${1#@}" 2>/dev/null || printf '__NONE__'
}

# ============================================================================
# 管理サブコマンド系 (__kill / __list / __preview / __cleanup / __switch)
# ============================================================================

# 1. kill 対象が現在セッション以外: そのまま kill (switch しない)
test_kill_other_session() {
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_CURRENT=A FAKE_SESSIONS=$'A\nB'
  run_kill 'B:0'
  check 'kill 対象が現在セッション以外: kill-session のみ' \
    'kill-session -t B' "$(cat "${FAKE_TMUX_LOG}")"
}

# 2. kill 対象が現在セッション かつ 他セッション有: switch 後に kill (順序込み)
test_kill_current_session_with_other() {
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_CURRENT=A FAKE_SESSIONS=$'A\nB'
  run_kill 'A:1'
  check 'kill 対象が現在セッション: switch-client 後に kill-session' \
    $'switch-client -t B\nkill-session -t A' "$(cat "${FAKE_TMUX_LOG}")"
}

# 3. kill 対象が現在セッション かつ 唯一: switch せず kill
test_kill_only_session() {
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_CURRENT=A FAKE_SESSIONS=$'A'
  run_kill 'A:0'
  check 'kill 対象が唯一セッション: switch せず kill-session' \
    'kill-session -t A' "$(cat "${FAKE_TMUX_LOG}")"
}

# 4. list は session を列挙し、名前幅で左寄せ、Nwin/Mpane、attach 中のみ "*"。
#    マーカー無し時は色を付けない。行頭は fzf 用の隠しフィールド (素のセッション名)。
#    (FAKE_SESSIONS: name nwin attached(1 or 空) / FAKE_PANES: session pane_id path)
test_list_pads_and_marks_attached() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'0\t3\t\n13\t1\t1\n4\t3\t'
  set_fake_panes \
    0 '%1' "${repos}/alpha" \
    0 '%2' "${repos}/alpha" \
    13 '%3' "${repos}/alpha" \
    4 '%4' "${repos}/alpha" \
    4 '%5' "${repos}/alpha" \
    4 '%6' "${repos}/alpha"

  check 'list 出力: 左寄せ + Nwin Mpane + attach の * (色なし)' \
    $'\talpha\n0\t  0   3w2p\n13\t  13  1w1p *\n4\t  4   3w3p' "$(list_plain)"
}

# 5. __preview は session の全 window×pane をヘッダ付きで縦積みキャプチャする
#    (FAKE_PANES はタブ区切り: active widx pidx wname cmd pid、active pane に *)
test_preview_stacks_panes() {
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_PANES=$'1\t1\t1\tzsh\tclaude\t%0\n0\t1\t2\tzsh\tzsh\t%72\n1\t2\t1\tbash\tbash\t%15'
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_CAPTURE='SCREENDUMP'

  # ANSI(青背景含む)と横幅パディングの末尾空白を除去してテキストだけ検証する。
  local out
  out=$(PATH="${fakebin}:${PATH}" "${tmuxs_bin}" __preview '4' |
    strip_ansi | sed -e 's/[[:space:]]*$//')
  check '__preview: 全 pane をヘッダ付きで縦積み (active pane に *)' \
    $'4: win=zsh / 1.1 claude [/] *\nSCREENDUMP\n\n4: win=zsh / 1.2 zsh [/]\nSCREENDUMP\n\n4: win=bash / 2.1 bash [/] *\nSCREENDUMP' \
    "${out}"
}

# 6. cleanup は現存しない pane_id のマーカーのみ削除する。
test_cleanup_removes_dead_markers() {
  clear_markers
  printf 'idle' >"${TMUXS_MARKER_DIR}/%1"
  printf 'running' >"${TMUXS_MARKER_DIR}/%2"
  printf 'waiting' >"${TMUXS_MARKER_DIR}/%99"
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_PANES=$'%1\n%2'

  PATH="${fakebin}:${PATH}" "${tmuxs_bin}" __cleanup

  local remain
  remain=$(cd "${TMUXS_MARKER_DIR}" && printf '%s ' * | sort)
  check 'cleanup: 死んだ pane (%99) のマーカーのみ削除' \
    '%1 %2 ' "${remain}"
}

# 7. list は waiting を含む session を上位へ並べ、状態色で背景強調する。
#    C は running(%3) と idle(%4) を持つが優先度で running に集約される。
#    D は idle のみ。A はマーカー無し(色なし)。
test_list_state_color_and_sort() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'A\t1\t\nB\t1\t\nC\t1\t\nD\t1\t'
  set_fake_panes \
    A '%1' "${repos}/alpha" \
    B '%2' "${repos}/alpha" \
    C '%3' "${repos}/alpha" \
    C '%4' "${repos}/alpha" \
    D '%5' "${repos}/alpha"
  printf 'waiting' >"${TMUXS_MARKER_DIR}/%2"
  printf 'running' >"${TMUXS_MARKER_DIR}/%3"
  printf 'idle' >"${TMUXS_MARKER_DIR}/%4"
  printf 'idle' >"${TMUXS_MARKER_DIR}/%5"

  local raw stripped
  raw=$(run_list)
  stripped=$(printf '%s' "${raw}" | strip_ansi)

  check 'list: waiting(B) を上位へ並べ替え + 状態集約 (C=running)' \
    $'\talpha\nB\t  B  1w1p\nA\t  A  1w1p\nC\t  C  1w2p\nD\t  D  1w1p' "${stripped}"
  check 'list: B 行に waiting 背景色 (#E5AF1E)' yes \
    "$(printf '%s' "${raw}" | grep -q '48;2;229;175;30' && echo yes || echo no)"
  check 'list: C 行に running 背景色 (#799478)' yes \
    "$(printf '%s' "${raw}" | grep -q '48;2;121;148;120' && echo yes || echo no)"
  check 'list: D 行に idle 背景色 (#4E4E4E)' yes \
    "$(printf '%s' "${raw}" | grep -q '48;2;78;78;78' && echo yes || echo no)"
}

# 8. __preview はマーカー保持 pane のヘッダ帯を状態色に塗る。
test_preview_state_band() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_PANES=$'1\t1\t1\tzsh\tclaude\t%0\n1\t2\t1\tbash\tbash\t%15'
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_CAPTURE='SCREENDUMP'
  printf 'waiting' >"${TMUXS_MARKER_DIR}/%0"

  local raw
  raw=$(PATH="${fakebin}:${PATH}" "${tmuxs_bin}" __preview '4')

  check '__preview: waiting pane(%0) のヘッダ帯に waiting 色' yes \
    "$(printf '%s' "${raw}" | grep -q '48;2;229;175;30' && echo yes || echo no)"
  check '__preview: マーカー無し pane(%15) は従来の青背景帯 (44)' yes \
    "$(printf '%s' "${raw}" | grep -q '1;30;44' && echo yes || echo no)"
}

# 9. __switch は選択セッションへ switch 後、waiting pane があればそこへ focus を移す。
#    running(%2) は無視し waiting(%3) へ attach (switch-client => select-window => select-pane)。
#    (FAKE_PANES タブ区切り: window_index pane_id)
test_switch_focuses_waiting_pane() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_PANES=$'1\t%1\n1\t%2\n2\t%3'
  printf 'running' >"${TMUXS_MARKER_DIR}/%2"
  printf 'waiting' >"${TMUXS_MARKER_DIR}/%3"

  : >"${FAKE_TMUX_LOG}"
  PATH="${fakebin}:${PATH}" "${tmuxs_bin}" __switch 'A'

  local got
  got=$(grep -E '^(switch-client|select-window|select-pane)' "${FAKE_TMUX_LOG}")
  check '__switch: waiting pane(%3) へ focus (switch-client => select-window => select-pane)' \
    $'switch-client -t A\nselect-window -t A:2\nselect-pane -t %3' "${got}"
}

# 10. waiting が無ければ (running/idle のみでも) focus を動かさず switch-client のみ。
#     tmux の last-active pane を維持する。
test_switch_no_waiting_keeps_active() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_PANES=$'1\t%1\n2\t%2'
  printf 'running' >"${TMUXS_MARKER_DIR}/%1"
  printf 'idle' >"${TMUXS_MARKER_DIR}/%2"

  : >"${FAKE_TMUX_LOG}"
  PATH="${fakebin}:${PATH}" "${tmuxs_bin}" __switch 'A'

  local got
  got=$(grep -E '^(switch-client|select-window|select-pane)' "${FAKE_TMUX_LOG}")
  check '__switch: waiting 無し (running/idle のみ) は switch-client のみ (focus 移動なし)' \
    'switch-client -t A' "${got}"
}

# 11. list はセッションをリポジトリ単位でグループ化する。
#     worktree (alpha-worktree/br1) は親 alpha へ畳み、git 管理外は末尾の
#     (no repo) へ集約する。グループはセッション数の多い順。
test_list_groups_by_repository() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'awt\t1\t\nsolo\t1\t\nbeta\t2\t\nalpha\t1\t1'
  set_fake_panes \
    awt '%1' "${repos}/alpha-worktree/br1" \
    solo '%2' "${tmpdir}/plain" \
    beta '%3' "${repos}/beta" \
    beta '%4' "${repos}/beta" \
    alpha '%5' "${repos}/alpha"

  check 'list: repo 見出しでグループ化 (worktree は親へ / 管理外は末尾)' \
    $'\talpha\nawt\t  awt    1w1p\nalpha\t  alpha  1w1p *\n\tbeta\nbeta\t  beta   2w2p\n\t(no repo)\nsolo\t  solo   1w1p' \
    "$(list_plain)"
}

# 12. waiting を含むグループを最上位へ上げ、グループ内でも waiting を先頭にする。
#     セッション数は同数 (各 2) なので、waiting が無ければ名前順で alpha が先。
test_list_waiting_group_first() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'alpha\t1\t\nawt\t1\t\nbeta\t1\t\nbeta2\t1\t'
  set_fake_panes \
    alpha '%1' "${repos}/alpha" \
    awt '%2' "${repos}/alpha-worktree/br1" \
    beta '%3' "${repos}/beta" \
    beta2 '%4' "${repos}/beta"
  printf 'waiting' >"${TMUXS_MARKER_DIR}/%4"

  local raw
  raw=$(run_list)

  check 'list: waiting を含む beta 群を最上位へ (群内も waiting 先頭)' \
    $'\tbeta\nbeta2\t  beta2  1w1p\nbeta\t  beta   1w1p\n\talpha\nalpha\t  alpha  1w1p\nawt\t  awt    1w1p' \
    "$(printf '%s' "${raw}" | strip_ansi)"
  check 'list: 見出し行には状態色を付けない (waiting 色はセッション行のみ 1 箇所)' \
    1 "$(printf '%s\n' "${raw}" | grep -c '48;2;229;175;30')"
}

# 13. list 幅 (TMUXS_LIST_COLS) を超えるセッション名を切り詰め、Nw Mp * を右端へ収める。
#     幅 20 => インデント 2 + 名前 12 + 区切り 2 + '1w1p' 4。
test_list_truncates_to_width() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'verylongsessionname\t1\t\nab\t1\t'
  set_fake_panes \
    verylongsessionname '%1' "${repos}/alpha" \
    ab '%2' "${repos}/alpha"

  local out
  out=$(TMUXS_LIST_COLS=20 list_plain)
  check 'list: 幅超過のセッション名を切り詰め Nw Mp を右端へ収める' \
    $'\talpha\nverylongsessionname\t  verylongse..  1w1p\nab\t  ab            1w1p' \
    "${out}"
  check 'list: 整形後の行が list 幅 (20) に収まる' 20 \
    "$(printf '%s\n' "${out}" | tail -n1 | cut -f2- | awk '{print length($0)}')"
}

# 14. (no repo) はセッション数が最多でも末尾に来る。
#     管理外 3 件 vs alpha 1 件。件数だけで並べると管理外が先頭へ浮く。
test_list_no_repo_group_last() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'a\t1\t\nb\t1\t\nc\t1\t\nz\t1\t'
  set_fake_panes \
    a '%1' "${tmpdir}/plain" \
    b '%2' "${tmpdir}/plain" \
    c '%3' "${tmpdir}/plain" \
    z '%4' "${repos}/alpha"

  check 'list: (no repo) は最多件数でも末尾' \
    $'\talpha\nz\t  z  1w1p\n\t(no repo)\na\t  a  1w1p\nb\t  b  1w1p\nc\t  c  1w1p' \
    "$(list_plain)"
}

# 15. common dir が '<repo>/.git' でない配置でもリポジトリ名を取り違えない。
#     1 段上るのは末尾が .git のときだけ。submodule は modules、
#     bare は親ディレクトリ名になってしまう。
test_list_repo_name_edge_layouts() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'sm\t1\t\nbr\t1\t'
  set_fake_panes \
    sm '%1' "${repos}/super/sub" \
    br '%2' "${repos}/bare.git"

  check 'list: submodule は sub / bare は bare (modules・親ディレクトリ名にしない)' \
    $'\tbare\nbr\t  br  1w1p\n\tsub\nsm\t  sm  1w1p' \
    "$(list_plain)"
}

# 16. 全角を含むセッション名でも表示幅で桁を揃える (bash の ${#s} は文字数のため)。
#     '実施してみる' は 6 文字だが表示幅 12。
test_list_aligns_fullwidth_name() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'ab\t1\t\n実施してみる\t1\t'
  set_fake_panes \
    ab '%1' "${repos}/alpha" \
    実施してみる '%2' "${repos}/alpha"

  check 'list: 全角セッション名を表示幅 12 で数えて桁を揃える' \
    $'\talpha\nab\t  ab            1w1p\n実施してみる\t  実施してみる  1w1p' \
    "$(list_plain)"
}

# 17. 全角名の切り詰め。幅 19 => 名前列 11。'実施してみるテスト' は表示幅 18 なので
#     表示幅 8 まで詰めて '..' を足し、半角 1 個ぶんの余りを空白で埋める。
#     切り詰めを文字数で数えると桁が 1 ずれるため、要件 8 と 9 の交差を固定する。
test_list_truncates_fullwidth_name() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'実施してみるテスト\t1\t\nab\t1\t'
  set_fake_panes \
    実施してみるテスト '%1' "${repos}/alpha" \
    ab '%2' "${repos}/alpha"

  check 'list: 全角名を表示幅で切り詰め、余り 1 桁を空白で埋める' \
    $'\talpha\n実施してみるテスト\t  実施して..   1w1p\nab\t  ab           1w1p' \
    "$(TMUXS_LIST_COLS=19 list_plain)"
}

# 18. list 幅が極端に狭くても名前列は min_name_cols (8) より下げない。
#     幅 10 だと計算上は 2 桁になるが 8 でクランプし、行は幅を超える。
test_list_clamps_min_name_width() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'verylongname\t1\t'
  set_fake_panes verylongname '%1' "${repos}/alpha"

  check 'list: 極小幅でも名前列を 8 桁で止める' \
    $'\talpha\nverylongname\t  verylo..  1w1p' \
    "$(TMUXS_LIST_COLS=10 list_plain)"
}

# 19. セッション内の pane がリポジトリ違いのパスを持つ場合、列挙順で最初の
#     pane のパスで群を決める (最後の pane を採ると beta 群になる)。
test_list_uses_first_pane_path() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'mix\t1\t'
  set_fake_panes \
    mix '%1' "${repos}/alpha" \
    mix '%2' "${repos}/beta"

  check 'list: 群の判定は最初の pane の作業パス' \
    $'\talpha\nmix\t  mix  1w2p' "$(list_plain)"
}

# 19b. .tasks.md の front matter が done: true のセッションだけ左端に印を出す。
#      done: false と front matter 無しは 2 桁の空白のままで、桁は揃う。
test_list_marks_done_task() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS=$'wtdone\t1\t\nwtundone\t1\t\nbeta\t1\t'
  set_fake_panes \
    wtdone '%1' "${repos}/alpha-worktree/done" \
    wtundone '%2' "${repos}/alpha-worktree/undone" \
    beta '%3' "${repos}/beta"

  check 'list: .tasks.md が done: true のセッションにだけ ✅ を出す' \
    $'\talpha\nwtdone\t\u2705wtdone    1w1p\nwtundone\t  wtundone  1w1p\n\tbeta\nbeta\t  beta      1w1p' \
    "$(list_plain)"
}

# 20. セッションが 1 つも無い場合は空出力で正常終了する。
test_list_empty() {
  clear_markers
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_SESSIONS='' FAKE_PANES=''

  local out rc
  out=$(list_plain)
  rc=$?
  check 'list: セッション 0 件なら空出力' '' "${out}"
  check 'list: セッション 0 件でも exit 0' 0 "${rc}"
}

# ============================================================================
# イベント/フック系 (tmuxs waiting|running|idle|remove)
# ============================================================================

# 15. tmux 外 (TMUX_PANE 未設定) では何もしない (no-op)。
test_no_op_outside_tmux() {
  reset
  unset TMUX_PANE
  run_hook waiting
  check 'tmux 外: マーカーを書かない' '__NONE__' "$(marker_content '%5')"
}

# 16. 各状態でマーカー内容が正しく書かれる。
test_marker_states() {
  reset
  run_hook running
  check 'running: マーカー内容 running' 'running' "$(marker_content '%5')"
  run_hook idle
  check 'idle: マーカー内容 idle' 'idle' "$(marker_content '%5')"
  run_hook waiting
  check 'waiting: マーカー内容 waiting' 'waiting' "$(marker_content '%5')"
}

# 17. remove はマーカーを削除する。
test_remove_deletes_marker() {
  reset
  run_hook idle
  run_hook remove
  check 'remove: マーカー削除' '__NONE__' "$(marker_content '%5')"
}

# 18. waiting -> running の遷移で待ち表示枠を点灯後に消灯する。
test_indicator_set_then_cleared() {
  reset

  run_hook waiting
  check 'waiting: @tmuxs_waiting に ⏳1 を点灯' yes \
    "$(opt @tmuxs_waiting | grep -q '⏳1' && echo yes || echo no)"

  run_hook running
  check 'running(waiting 解消): @tmuxs_waiting を消灯 (unset)' \
    '__NONE__' "$(opt @tmuxs_waiting)"
}

# 19. waiting 非関与の遷移 (running) では待ち表示枠に触れない (tmux IPC 抑制)。
test_indicator_untouched_without_waiting() {
  reset
  run_hook running
  check 'running(waiting 非関与): @tmuxs_waiting への set を発行しない' \
    '' "$(grep '@tmuxs_waiting' "${FAKE_TMUX_LOG}" || true)"
}

# 20. 複数 pane が waiting なら件数 N を点灯する。
test_indicator_counts_multiple() {
  reset
  # lint-ignore: uppercase 偽 tmux が読む env 名は fake 側と揃える必要があり小文字化できない
  export FAKE_PANES=$'%5\n%6'
  printf 'waiting' >"${TMUXS_MARKER_DIR}/%6" # 別 pane が既に waiting
  run_hook waiting                           # 自分 %5 も waiting => 計 2
  check '複数 waiting: @tmuxs_waiting に ⏳2' yes \
    "$(opt @tmuxs_waiting | grep -q '⏳2' && echo yes || echo no)"
}

# 21. 黄色帯モード ON (band_enabled=1): waiting で @tmuxs_band=1 + status-style を黄色帯へ
#     直接上書きし、解消で @tmuxs_band unset + 通常 status-style へ復元する。
test_band_set_then_cleared() {
  reset

  run_hook waiting
  check 'waiting(band ON): @tmuxs_band=1 を設定' '1' "$(opt @tmuxs_band)"
  check 'waiting(band ON): status-style を黄色帯へ直接上書き' \
    'bg=#E5AF1E,fg=#000000' "$(opt status-style)"

  run_hook running
  check 'running(waiting 解消): @tmuxs_band を unset' \
    '__NONE__' "$(opt @tmuxs_band)"
  check 'running(waiting 解消): status-style を通常へ復元' \
    'bg=colour234,fg=blue,default' "$(opt status-style)"
}

# 22. 退避元 status-style が空文字でも band ON->OFF で黄色が残らない (番兵で判定)。
test_band_empty_style_restore() {
  reset
  : >"${FAKE_STATE_DIR}/status-style" # 空 style 環境を再現

  run_hook waiting
  check 'band/empty: status-style を黄色帯へ' \
    'bg=#E5AF1E,fg=#000000' "$(opt status-style)"

  run_hook running
  check 'band/empty 解消: 空 style へ復元 (黄色が残らない)' \
    '' "$(opt status-style)"
}

main() {
  # 各テストを最後まで実行して集計するため、あえて -e は付けない。
  set -uo pipefail

  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064 # local 変数を EXIT 時に確実に消すため定義時に展開する
  trap "rm -rf '${tmpdir}'" EXIT

  # 実 marker (XDG_RUNTIME_DIR 配下) を触らないよう一時ディレクトリへ隔離する。
  # lint-ignore: uppercase tmuxs / tmux が読む env 名は呼ばれる側が決める
  export TMUXS_MARKER_DIR="${tmpdir}/markers"
  mkdir -p "${TMUXS_MARKER_DIR}"

  # git 探索が tmpdir より上へ出ないようにし、開発者のグローバル/システム設定
  # (commit.gpgsign, core.hooksPath, init.templateDir 等) も切り離す。
  # lint-ignore: uppercase git が読む env 名は git が決める
  export GIT_CEILING_DIRECTORIES="${tmpdir}"
  # lint-ignore: uppercase git が読む env 名は git が決める
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

  local fakebin
  local repos="${tmpdir}/repos"
  setup_fake_tmux
  setup_test_repos || {
    printf '==> Error: setup_test_repos に失敗した\n' >&2
    exit 1
  }

  local pass=0 fail=0

  # 管理サブコマンド系は TMUX 未設定の素の環境で動かすため hook 系より先に実行する
  # (hook 系の reset が TMUX='fake' 等を export して環境を汚すのを避ける)。
  test_kill_other_session
  test_kill_current_session_with_other
  test_kill_only_session
  test_list_pads_and_marks_attached
  test_preview_stacks_panes
  test_cleanup_removes_dead_markers
  test_list_state_color_and_sort
  test_preview_state_band
  test_switch_focuses_waiting_pane
  test_switch_no_waiting_keeps_active
  test_list_groups_by_repository
  test_list_waiting_group_first
  test_list_truncates_to_width
  test_list_no_repo_group_last
  test_list_repo_name_edge_layouts
  test_list_aligns_fullwidth_name
  test_list_truncates_fullwidth_name
  test_list_clamps_min_name_width
  test_list_uses_first_pane_path
  test_list_marks_done_task
  test_list_empty

  # イベント/フック系 (各テストは reset で TMUX='fake' / TMUX_PANE='%5' を export)。
  test_no_op_outside_tmux
  test_marker_states
  test_remove_deletes_marker
  test_indicator_set_then_cleared
  test_indicator_untouched_without_waiting
  test_indicator_counts_multiple
  test_band_set_then_cleared
  test_band_empty_style_restore

  printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
  [[ ${fail} -eq 0 ]]
}

main "$@"
