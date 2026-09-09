#!/usr/bin/env bash

# tasks の index.md ベース挙動のユニットテスト (実 git 使用・NW 不要)。
# 対象コマンドを subprocess 実行し、XDG_CONFIG_HOME と一時 git repo を差し替える。
# split は TASKS_GEN_META_CMD で LLM 生成を fake に差し替え、worktree/tmux に依存しない。
#
# 検証対象:
#   * link 先解決: not-worktree => {store_root}/{tasks_subdir}/{repo}/index.md
#   * config 無し/store_root 未設定/相対/~ => die・展開、既存 link は config 無しでも動作
#   * worktree で link 未生成 => 親リポ共有 base へ自己修復 (front matter 生成)
#   * split: {timestamp}_{name}/index.md(front matter) 生成、元リストは新形式参照行へ置換
#       参照行 = - [ ] [dir名](store_root 相対 path)
#   * split-all: 参照行を再 split せず終了 (無限ループ回帰)
#   * summary: front matter title 表示
#   * complete: front matter status: ✅️ + title ✅️ + 親参照 [x]
#   * complete: 通常サブタスク - [ ] => - [x]
#   * clean: 完了参照行を log_fmt へ転記 (削除せず残す。done 廃止)
#   * pr: pr を包んで成功時だけ status へ 🚀 を足す (並びは 🚀✅️ に正規化)
#
#   test/tasks   # 全テスト実行

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tasks_bin=$(cd "${script_dir}/../bin" && pwd)/tasks

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

# 隔離環境を用意。envdir/xdg/base/repo をグローバルに設定し、空 git repo を作る。
# $2 に repo の相対パス (例: myrepo-worktree/feature-x) を渡すと worktree パスを再現できる。
new_env() {
  local name="$1" repo_rel="${2:-myrepo}"
  envdir="${tmproot}/${name}"
  xdg="${envdir}/xdg"
  base="${envdir}/base"
  repo="${envdir}/${repo_rel}"
  meta_counter="${envdir}/meta_n"
  wt_log="${envdir}/wt.log"
  tmux_log="${envdir}/tmux.log"
  fzf_log="${envdir}/fzf.log"
  pr_log="${envdir}/pr.log"
  pr_exit=0
  mkdir -p "${repo}"
  git -C "${repo}" init -q
}

# config.env を新スキーマで書き出す。
# 引数: tasks_base (= store_root/tasks_subdir となる絶対パス。省略時 ${base})。
# store_root=dirname / tasks_subdir=basename へ分解し、tasks_store_dir が tasks_base に一致する。
write_config() {
  local tasks_base="${1:-${base}}"
  write_config_kv "$(dirname "${tasks_base}")" "$(basename "${tasks_base}")" \
    'logs/%Y/%Y-%m-01-log.md'
}

# config.env に store_root/tasks_subdir/log_fmt を verbatim で書き出す (検証用)。
write_config_kv() {
  mkdir -p "${xdg}/tasks"
  {
    printf 'store_root=%s\n' "$1"
    printf 'tasks_subdir=%s\n' "$2"
    printf "log_fmt='%s'\n" "$3"
  } >"${xdg}/tasks/config.env"
}

# repo 内で bin/tasks を実行。XDG_CONFIG_HOME と LLM 生成 fake を差し替える。
# run_tasks と同じ環境で終了コードだけを返す (stdout/stderr は捨てる)。
run_tasks_status() {
  run_tasks "$@" >/dev/null 2>&1
  printf '%s' "$?"
}

run_tasks() {
  (cd "${repo}" &&
    PATH="${fakebin}:${PATH}" \
      XDG_CONFIG_HOME="${xdg}" \
      TASKS_GEN_META_CMD="${fake_meta}" \
      FAKE_META_COUNTER="${meta_counter}" \
      FAKE_WT_LOG="${wt_log}" \
      FAKE_TMUX_LOG="${tmux_log}" \
      FAKE_FZF_LOG="${fzf_log}" \
      FAKE_PR_LOG="${pr_log}" \
      FAKE_PR_EXIT="${pr_exit:-0}" \
      "${tasks_bin}" "$@") 2>&1
}

# LLM 生成 fake: stdin を捨て、呼び出し毎に連番の branch/name/title を返す。
write_fake_meta() {
  fake_meta="${tmproot}/fake_meta"
  cat >"${fake_meta}" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
n_file="${FAKE_META_COUNTER:-/tmp/fake_meta_n}"
i=$(( $(cat "${n_file}" 2>/dev/null || echo 0) + 1 ))
echo "${i}" >"${n_file}"
printf '{"branch":"feature/test-%s","name":"test-task-%s","title":"Test Title %s"}\n' "${i}" "${i}" "${i}"
FAKE
  chmod +x "${fake_meta}"
}

# worktree/tmux の fake を fakebin へ書き出し PATH 先頭に差し込む (run_tasks 参照)。
# git_worktree -a <branch>: 実 worktree 規約と同じ <org>-worktree/<name> を mkdir し、
# パスを echo・呼び出しを FAKE_WT_LOG へ記録する (real git worktree/tmux 非依存)。
write_fake_bins() {
  fakebin="${tmproot}/fakebin"
  mkdir -p "${fakebin}"
  cat >"${fakebin}/git_worktree" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_WT_LOG:-/dev/null}"
mode= ; branch=
while [[ -n ${1:-} ]]; do
  case "$1" in
    -a) mode=add ;;
    -*) ;;
    *) [[ -z $branch ]] && branch="$1" ;;
  esac
  shift
done
[[ $mode == add ]] || exit 0
name=${branch//\//-}
org=$(realpath "$(dirname "$(git rev-parse --git-common-dir)")")
wt="${org}-worktree/${name}"
mkdir -p "$wt"
echo "$wt"
FAKE
  cat >"${fakebin}/tmux" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  has-session) exit 1 ;;
esac
exit 0
FAKE
  # fake fzf: stdin 全行を選択結果として返す (ctrl-l 全件選択 + enter 相当)。
  # 呼び出しを FAKE_FZF_LOG へ記録し、--all/Nth が fzf を経由しないことを検証可能にする。
  cat >"${fakebin}/fzf" <<'FAKE'
#!/usr/bin/env bash
echo "called" >>"${FAKE_FZF_LOG:-/dev/null}"
cat
FAKE
  # fake bat: 色/装飾を無視し stdin を素通し (preview のブロック境界/参照解決を検証)。
  cat >"${fakebin}/bat" <<'FAKE'
#!/usr/bin/env bash
cat
FAKE
  # fake pr: 引数を記録し、FAKE_PR_EXIT の値で成否を切り替える。
  # tasks pr は pr の成否だけを見て印を付けるので、PR の中身は再現しない。
  cat >"${fakebin}/pr" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_PR_LOG:-/dev/null}"
exit "${FAKE_PR_EXIT:-0}"
FAKE
  chmod +x "${fakebin}/git_worktree" "${fakebin}/tmux" "${fakebin}/fzf" \
    "${fakebin}/bat" "${fakebin}/pr"
}

# 1. config の tasks_subdir 配下 {tasks_subdir}/{repo}/index.md に link を生成する
test_creates_index_md_link() {
  new_env t1 myrepo
  write_config "${base}"

  run_tasks --summary >/dev/null 2>&1 || true

  check 'links: .tasks => {base}/myrepo' \
    "${base}/myrepo" "$(readlink "${repo}/.tasks")"

  local md_target
  md_target=$(readlink "${repo}/.tasks.md")
  check 'links: .tasks.md => {base}/myrepo/index.md' \
    "${base}/myrepo/index.md" "${md_target}"
}

# 2. config が無ければ die し、link を生成しない
test_dies_without_config() {
  new_env t2 myrepo

  local out rc
  out=$(run_tasks --summary)
  rc=$?

  check 'no-config: exit non-zero' '1' "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"
  check 'no-config: message points to config path' \
    '1' "$([[ ${out} == *config.env* ]] && echo 1 || echo 0)"
  check 'no-config: .tasks.md not created' \
    '1' "$([[ ! -e ${repo}/.tasks.md ]] && echo 1 || echo 0)"
}

# 3. store_root が未設定なら die する
test_dies_without_store_root() {
  new_env t3 myrepo
  write_config_kv '' 'tasks' 'logs/x.md'

  local out rc
  out=$(run_tasks --summary)
  rc=$?

  check 'no-store_root: exit non-zero' '1' "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"
  check 'no-store_root: message says "is not set"' \
    '1' "$([[ ${out} == *"is not set"* ]] && echo 1 || echo 0)"
}

# 3a2. tasks_subdir が未設定なら die する
test_dies_without_tasks_subdir() {
  new_env t3a2 myrepo
  write_config_kv "${base}" '' 'logs/x.md'

  local out rc
  out=$(run_tasks --summary)
  rc=$?

  check 'no-tasks_subdir: exit non-zero' '1' "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"
  check 'no-tasks_subdir: message says "is not set"' \
    '1' "$([[ ${out} == *"is not set"* ]] && echo 1 || echo 0)"
}

# 3a3. log_fmt が未設定なら die する
test_dies_without_log_fmt() {
  new_env t3a3 myrepo
  write_config_kv "$(dirname "${base}")" "$(basename "${base}")" ''

  local out rc
  out=$(run_tasks --summary)
  rc=$?

  check 'no-log_fmt: exit non-zero' '1' "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"
  check 'no-log_fmt: message says "is not set"' \
    '1' "$([[ ${out} == *"is not set"* ]] && echo 1 || echo 0)"
}

# 3b. 相対パスの store_root は絶対パスでないとして die する
test_dies_with_relative_store_root() {
  new_env t3b myrepo
  write_config_kv 'relative/root' 'tasks' 'logs/x.md'

  local out rc
  out=$(run_tasks --summary)
  rc=$?

  check 'relative-root: exit non-zero' '1' "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"
  check 'relative-root: message says "absolute path"' \
    '1' "$([[ ${out} == *"absolute path"* ]] && echo 1 || echo 0)"
}

# 3c. クォート付きリテラル ~ の store_root は $HOME 展開され受理される
test_accepts_quoted_tilde_store_root() {
  new_env t3c myrepo
  local fake_home="${envdir}/home"
  mkdir -p "${fake_home}"
  write_config_kv '"~/troot"' 'tasks' 'logs/x.md'

  local rc
  (cd "${repo}" &&
    HOME="${fake_home}" XDG_CONFIG_HOME="${xdg}" \
      TASKS_GEN_META_CMD="${fake_meta}" FAKE_META_COUNTER="${meta_counter}" \
      "${tasks_bin}" --summary) >/dev/null 2>&1
  rc=$?

  check 'tilde-root: exit zero (~ expanded, accepted)' '0' "${rc}"
  check 'tilde-root: .tasks => {fake_home}/troot/tasks/myrepo' \
    "${fake_home}/troot/tasks/myrepo" "$(readlink "${repo}/.tasks")"
}

# 4. config は全モード必須 (main で必ず load)。link 既生成でも config 無しは die する
test_requires_config_even_with_links() {
  new_env t4 myrepo
  mkdir -p "${repo}/.tasks"
  : >"${repo}/.tasks.md"

  local out rc
  out=$(run_tasks --summary)
  rc=$?

  check 'mandatory-config: exit non-zero without config' \
    '1' "$([[ ${rc} -ne 0 ]] && echo 1 || echo 0)"
  check 'mandatory-config: message points to config path' \
    '1' "$([[ ${out} == *config.env* ]] && echo 1 || echo 0)"
}

# 5. worktree で link 未生成なら親リポから自己修復し front matter 付き .tasks.md を生成
test_worktree_self_heals_links() {
  new_env t5 myrepo
  write_config "${base}"
  # 親リポを初期化 (.tasks/.tasks.md 生成) し、worktree add 用に 1 コミット作る。
  # .tasks/.tasks.md は untracked のまま放置 = worktree には引き継がれない。
  run_tasks --summary >/dev/null 2>&1 || true
  git -C "${repo}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  # 本物の linked worktree を作成 (パス命名は規約と無関係でよい)
  local wt="${envdir}/myrepo-worktree/feature-x"
  mkdir -p "$(dirname "${wt}")"
  git -C "${repo}" worktree add -q -b feature-x "${wt}" >/dev/null 2>&1

  local out rc
  out=$(cd "${wt}" &&
    XDG_CONFIG_HOME="${xdg}" TASKS_GEN_META_CMD="${fake_meta}" \
      FAKE_META_COUNTER="${meta_counter}" "${tasks_bin}" --summary)
  rc=$?

  check 'worktree-heal: exit zero (no die)' '0' "${rc}"
  check 'worktree-heal: .tasks => {base}/myrepo (shared with parent)' \
    "${base}/myrepo" "$(readlink "${wt}/.tasks")"
  local md_target
  md_target=$(readlink "${wt}/.tasks.md")
  check 'worktree-heal: .tasks.md => {base}/myrepo/{timestamp}_feature-x/index.md' \
    '1' "$([[ ${md_target} == "${base}/myrepo/"*"_feature-x/index.md" ]] && echo 1 || echo 0)"
  check 'worktree-heal: front matter branch is worktree branch' \
    '1' "$(grep -qx 'branch: feature-x' "${md_target}" 2>/dev/null && echo 1 || echo 0)"
  check 'worktree-heal: summary shows branch as title' \
    '1' "$([[ ${out} == *"[feature-x]"* ]] && echo 1 || echo 0)"
}

# 6. split: タスクを {timestamp}_{name}/index.md へ移し、元リストは参照行へ置換
test_split_creates_dir_and_reference() {
  new_env t6 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  printf '%s\n' '- [ ] First task body' >>"${base}/myrepo/index.md"

  run_tasks -s 1 >/dev/null 2>&1 || true

  local idx
  idx=$(find "${base}/myrepo" -mindepth 2 -name index.md -path '*_test-task-1/index.md' | head -1)
  check 'split: index.md created under {timestamp}_{name}' \
    '1' "$([[ -n ${idx} ]] && echo 1 || echo 0)"

  check 'split: front matter has title' \
    '1' "$([[ -n ${idx} ]] && grep -qx 'title: Test Title 1' "${idx}" && echo 1 || echo 0)"
  check 'split: front matter has branch' \
    '1' "$([[ -n ${idx} ]] && grep -qx 'branch: feature/test-1' "${idx}" && echo 1 || echo 0)"
  check 'split: front matter status は空' \
    '1' "$([[ -n ${idx} ]] && grep -qx 'status:' "${idx}" && echo 1 || echo 0)"
  check 'split: body preserved' \
    '1' "$([[ -n ${idx} ]] && grep -qF 'First task body' "${idx}" && echo 1 || echo 0)"

  # 新形式参照行: - [ ] [dir名](store_root 相対 path)。base=${envdir}/base, store_root=${envdir}
  # => path は base/myrepo/{ts}_test-task-1/index.md
  check 'split: parent reference is new format (title + store_root-relative path)' \
    '1' "$(grep -qE -- '^- \[ \] \[[^]]*_test-task-1\]\(base/myrepo/[^)]*_test-task-1/index.md\)$' "${base}/myrepo/index.md" 2>/dev/null && echo 1 || echo 0)"
  check 'split: original task line removed from parent' \
    '0' "$(grep -qF -- '- [ ] First task body' "${base}/myrepo/index.md" 2>/dev/null && echo 1 || echo 0)"
}

# 7. split-all 削除: -sa はもう split しない (機能撤去の回帰)
test_split_all_removed() {
  new_env t7 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  {
    printf '%s\n' '- [ ] Task one'
    printf '%s\n' '- [ ] Task two'
  } >>"${base}/myrepo/index.md"

  # -sa は廃止 (後継は -s --all)。未知オプションとして parse 時に die する。
  # 終了コードを検証し、対話モードへ落ちてハングする回帰を防ぐ。
  local rc=0
  run_tasks -sa >/dev/null 2>&1 || rc=$?

  local dir_count
  dir_count=$(find "${base}/myrepo" -mindepth 2 -name index.md 2>/dev/null | wc -l)
  check 'split-all-removed: -sa is rejected as invalid option' \
    '1' "${rc}"
  check 'split-all-removed: -sa creates no task dirs (feature gone)' \
    '0' "${dir_count}"
}

# 7a. split: index.md 生成に続けて worktree を作成し link を張る
test_split_creates_worktree() {
  new_env t7a myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  printf '%s\n' '- [ ] First task body' >>"${base}/myrepo/index.md"

  run_tasks -s 1 >/dev/null 2>&1 || true

  local wt="${envdir}/myrepo-worktree/feature-test-1"
  check 'split-wt: worktree dir created' \
    '1' "$([[ -d ${wt} ]] && echo 1 || echo 0)"
  check 'split-wt: git_worktree -a called for branch' \
    '1' "$(grep -q -- '-a feature/test-1' "${wt_log}" 2>/dev/null && echo 1 || echo 0)"
  check 'split-wt: worktree .tasks.md linked to split index.md' \
    '1' "$([[ -L ${wt}/.tasks.md ]] && echo 1 || echo 0)"
}

# 7b. spawn (未split): split (index.md + worktree) してから tmux 起動
test_spawn_splits_unsplit_then_tmux() {
  new_env t7b myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  printf '%s\n' '- [ ] Spawn me task' >>"${base}/myrepo/index.md"

  run_tasks --spawn 1 >/dev/null 2>&1 || true

  local idx
  idx=$(find "${base}/myrepo" -mindepth 2 -name index.md -path '*_test-task-1/index.md' | head -1)
  check 'spawn-unsplit: split index.md created' \
    '1' "$([[ -n ${idx} ]] && echo 1 || echo 0)"
  check 'spawn-unsplit: parent reference created from split' \
    '1' "$(grep -qE -- '^- \[ \] \[[^]]*_test-task-1\]\(' "${base}/myrepo/index.md" 2>/dev/null && echo 1 || echo 0)"
  check 'spawn-unsplit: worktree created' \
    '1' "$([[ -d ${envdir}/myrepo-worktree/feature-test-1 ]] && echo 1 || echo 0)"
  check 'spawn-unsplit: tmux session created' \
    '1' "$(grep -q 'new-session' "${tmux_log}" 2>/dev/null && echo 1 || echo 0)"
}

# 7c. spawn (split済み + worktree既存): worktree 作成 skip・tmux は起動。
# ensure_worktree は git worktree list を SSOT に既存判定するため本物の worktree を作る。
test_spawn_skips_existing_worktree() {
  new_env t7c myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  git -C "${repo}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local repo_base="${base}/myrepo"
  local dir="${repo_base}/20260101-000000_pre"
  local ref='base/myrepo/20260101-000000_pre/index.md'
  mkdir -p "${dir}"
  printf '%s\n' "- [ ] [20260101-000000_pre](${ref})" >>"${repo_base}/index.md"
  cat >"${dir}/index.md" <<EOF
---
title: Pre Split
branch: feature/foo
name: pre
status:
parent: ${repo_base}/index.md
---

- [ ] sub
EOF
  # 既存 worktree を本物で用意 (git worktree list に出る => ensure_worktree が skip)
  local wt="${envdir}/myrepo-worktree/feature-foo"
  mkdir -p "$(dirname "${wt}")"
  git -C "${repo}" worktree add -q -b feature/foo "${wt}" >/dev/null 2>&1

  run_tasks --spawn 1 >/dev/null 2>&1 || true

  check 'spawn-skip: git_worktree NOT called (worktree exists)' \
    '0' "$(grep -c -- '-a feature/foo' "${wt_log}" 2>/dev/null || echo 0)"
  check 'spawn-skip: tmux session still created' \
    '1' "$(grep -q 'new-session' "${tmux_log}" 2>/dev/null && echo 1 || echo 0)"
}

# 7e. spawn (既定=claude): tmux へ `claude "/task"` を送信する (後方互換の固定)
test_spawn_default_sends_claude_command() {
  new_env t7e myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  printf '%s\n' '- [ ] Claude spawn task' >>"${base}/myrepo/index.md"

  run_tasks --spawn 1 >/dev/null 2>&1 || true

  check 'spawn-default: send-keys launches claude "/task"' \
    '1' "$(grep -qF 'claude "/task"' "${tmux_log}" 2>/dev/null && echo 1 || echo 0)"
}

# 7f. spawn-codex: -spc は spawn として解釈され tmux へ `codex '$task'` を送信する。
# シングルクォートで対話シェルの $task 展開を防ぎ codex に literal を渡す (skill 起動構文)。
test_spawn_codex_sends_codex_command() {
  new_env t7f myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  printf '%s\n' '- [ ] Codex spawn task' >>"${base}/myrepo/index.md"

  run_tasks --spawn-codex 1 >/dev/null 2>&1 || true

  check 'spawn-codex: tmux session created' \
    '1' "$(grep -q 'new-session' "${tmux_log}" 2>/dev/null && echo 1 || echo 0)"
  check "spawn-codex: send-keys launches codex '\$task'" \
    '1' "$(grep -qF "codex '\$task'" "${tmux_log}" 2>/dev/null && echo 1 || echo 0)"
  check 'spawn-codex: does not launch claude' \
    '0' "$(grep -qF 'claude "/task"' "${tmux_log}" 2>/dev/null && echo 1 || echo 0)"
}

# 7d. split (Nth 未指定): fzf multi-select 全件選択を行番号降順で処理する。
# fake fzf が全候補を返す = ctrl-l 全件選択相当。降順処理で body 取り違えが起きない。
test_split_multi_select_all() {
  new_env t7d myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  {
    printf '%s\n' '- [ ] Alpha task body'
    printf '%s\n' '- [ ] Bravo task body'
  } >>"${base}/myrepo/index.md"

  # Nth 未指定 => fake fzf が全候補を選択 (multi-select 全件)
  run_tasks -s >/dev/null 2>&1 || true

  local dir_count ref_count
  dir_count=$(find "${base}/myrepo" -mindepth 2 -name index.md 2>/dev/null | wc -l)
  ref_count=$(grep -cE '^- \[ \] \[[^]]*\]\(' "${base}/myrepo/index.md" 2>/dev/null || echo 0)
  check 'split-multi: 全件が dir へ split' '2' "${dir_count}"
  check 'split-multi: 全件が参照行へ置換' '2' "${ref_count}"
  # 降順処理の正しさ: 各 body が取り違わらずそれぞれの split 先に入る
  check 'split-multi: Alpha body がいずれかの split 先に存在' \
    '1' "$(grep -rqlF 'Alpha task body' "${base}/myrepo"/*/index.md 2>/dev/null && echo 1 || echo 0)"
  check 'split-multi: Bravo body がいずれかの split 先に存在' \
    '1' "$(grep -rqlF 'Bravo task body' "${base}/myrepo"/*/index.md 2>/dev/null && echo 1 || echo 0)"
}

# 8. summary: front matter の title を返す
test_summary_reads_front_matter_title() {
  new_env t8 myrepo
  write_config "${base}"
  local dir="${base}/myrepo/20260101-000000_test-task"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<'EOF'
---
title: My Split Title
branch: feature/foo
name: test-task
status:
parent: /nonexistent/index.md
---

- [ ] sub
EOF

  local out
  out=$(run_tasks --summary -f "${dir}/index.md")
  check 'summary: shows front matter title' \
    '1' "$([[ ${out} == *"[My Split Title]"* ]] && echo 1 || echo 0)"
}

# 9. complete (front matter): status: ✅️ + title ✅️ + 親参照 [x] + log 転記
test_complete_front_matter_task() {
  new_env t9 myrepo
  write_config "${base}"
  local repo_base="${base}/myrepo"
  local dir="${repo_base}/20260101-000000_test-task"
  # store_root=${envdir}, base=${envdir}/base => ref は base/myrepo/... の相対パス
  local ref='base/myrepo/20260101-000000_test-task/index.md'
  mkdir -p "${dir}"
  printf '%s\n' "- [ ] [20260101-000000_test-task](${ref})" >"${repo_base}/index.md"
  cat >"${dir}/index.md" <<EOF
---
title: Done Me
branch: feature/foo
name: test-task
status:
parent: ${repo_base}/index.md
---

EOF

  run_tasks ok -f "${dir}/index.md" >/dev/null 2>&1 || true

  check 'complete-fm: status に ✅️ が入る' \
    '1' "$(grep -qx 'status: ✅️' "${dir}/index.md" && echo 1 || echo 0)"
  check 'complete-fm: title prefixed with mark' \
    '1' "$(grep -qE '^title: ✅️ Done Me' "${dir}/index.md" && echo 1 || echo 0)"
  check 'complete-fm: parent reference marked [x]' \
    '1' "$(grep -qF -- "- [x] [20260101-000000_test-task](${ref})" "${repo_base}/index.md" && echo 1 || echo 0)"

  # 内容日付 (参照行 ts = 2026-01) の log へ転記する (実行日でなく)
  local log
  log="${envdir}/logs/2026/2026-01-01-log.md"
  check 'complete-fm: 完了参照を内容日付 (2026-01) の log へ転記' \
    '1' "$(grep -qF -- "- [x] [20260101-000000_test-task](${ref})" "${log}" 2>/dev/null && echo 1 || echo 0)"
}

# 9b. complete (front matter): 参照行が worktree .tasks.md symlink 表記 (store_root 相対の
# index.md パスでない) でも、解決後の実パス一致で [x] 化する回帰防止。
test_complete_front_matter_task_worktree_ref() {
  new_env t9b myrepo
  write_config "${base}"
  local repo_base="${base}/myrepo"
  local dir="${repo_base}/20260101-000000_wt-task"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<EOF
---
title: WT Ref
branch: feature/foo
name: wt-task
status:
parent: ${repo_base}/index.md
---

EOF
  # worktree の .tasks.md symlink を本物で用意し、参照行はその symlink を指す。
  # store_root 相対 index.md パスとは別表記だが realpath は同一ファイルへ解決される。
  local wt="${envdir}/myrepo-worktree/feature-foo"
  mkdir -p "${wt}"
  ln -s "${dir}/index.md" "${wt}/.tasks.md"
  printf '%s\n' "- [ ] [feature-foo](${wt}/.tasks.md)" >"${repo_base}/index.md"

  run_tasks ok -f "${dir}/index.md" >/dev/null 2>&1 || true

  check 'complete-fm-wtref: status に ✅️ が入る' \
    '1' "$(grep -qx 'status: ✅️' "${dir}/index.md" && echo 1 || echo 0)"
  check 'complete-fm-wtref: worktree-symlink reference marked [x]' \
    '1' "$(grep -qF -- "- [x] [feature-foo](${wt}/.tasks.md)" "${repo_base}/index.md" && echo 1 || echo 0)"

  local y ym log
  y=$(date +%Y) && ym=$(date +%Y-%m)
  log="${envdir}/logs/${y}/${ym}-01-log.md"
  check 'complete-fm-wtref: 完了参照を log へ転記' \
    '1' "$(grep -qF -- "- [x] [feature-foo](${wt}/.tasks.md)" "${log}" 2>/dev/null && echo 1 || echo 0)"
}

# 10. complete (通常サブタスク): - [ ] => - [x]
test_complete_normal_task() {
  new_env t10 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  printf '%s\n' '- [ ] Plain task' >>"${base}/myrepo/index.md"

  run_tasks ok 1 >/dev/null 2>&1 || true

  check 'complete-normal: marked [x]' \
    '1' "$(grep -qF -- '- [x] Plain task' "${base}/myrepo/index.md" && echo 1 || echo 0)"
}

# 11. complete (通常): 参照行をスキップし実タスクを完了する (parse_skip_refs)
test_complete_skips_reference() {
  new_env t11 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  {
    printf '%s\n' '- [ ] [20260101-000000_x](20260101-000000_x/index.md)'
    printf '%s\n' '- [ ] Real task'
  } >>"${base}/myrepo/index.md"

  run_tasks ok 1 >/dev/null 2>&1 || true

  check 'complete-skip-ref: real task marked [x]' \
    '1' "$(grep -qF -- '- [x] Real task' "${base}/myrepo/index.md" && echo 1 || echo 0)"
  check 'complete-skip-ref: reference left untouched' \
    '1' "$(grep -qF -- '- [ ] [20260101-000000_x](20260101-000000_x/index.md)' "${base}/myrepo/index.md" && echo 1 || echo 0)"
}

# 12. clean: 完了参照行 (split 済み) は候補外。転記も削除もしない。
# split 済みタスクの完了記録は complete 側 (mark_parent_reference_done) が担う。
test_clean_excludes_done_reference() {
  new_env t12 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  # 完了参照2件・未完了参照・通常未完了タスクを混在 (どれも clean 候補にならない)
  {
    printf '%s\n' '- [ ] 通常の未完了タスク'
    printf '%s\n' '- [x] [20260101-000000_done1](base/myrepo/20260101-000000_done1/index.md)'
    printf '%s\n' '- [ ] [20260102-000000_pending](base/myrepo/20260102-000000_pending/index.md)'
    printf '%s\n' '- [x] [20260103-000000_done2](base/myrepo/20260103-000000_done2/index.md)'
  } >>"${base}/myrepo/index.md"

  run_tasks -c --all >/dev/null 2>&1 || true

  # log_fmt = store_root 起点 logs/%Y/%Y-%m-01-log.md。store_root => envdir
  local y ym log
  y=$(date +%Y) && ym=$(date +%Y-%m)
  log="${envdir}/logs/${y}/${ym}-01-log.md"

  check 'clean: 完了参照は log へ転記しない (候補外)' \
    '0' "$([[ -f ${log} ]] && grep -qE '_done[12]\]' "${log}" && echo 1 || echo 0)"
  check 'clean: 完了参照は index.md に残す' \
    '2' "$(grep -cE '_done[12]\]' "${base}/myrepo/index.md" 2>/dev/null || true)"
  check 'clean: 未完了参照は index.md に残す' \
    '1' "$(grep -qF -- '20260102-000000_pending' "${base}/myrepo/index.md" && echo 1 || echo 0)"
  check 'clean: 通常タスクは index.md に残す' \
    '1' "$(grep -qF -- '通常の未完了タスク' "${base}/myrepo/index.md" && echo 1 || echo 0)"
}

# 13. clean(normal): 未split 完了タスクを split し、関連ファイル移動・log 転記・参照保持
test_clean_splits_unsplit_completed_task() {
  new_env t13 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  # 本文が言及し src_dir に実在する関連ファイル (実命名規約 {TS}-...) は split 先へ移動。
  # 本文が言及しない src_dir の loose file は移動しない (dir 全掃きしない保証)。
  printf '%s\n' 'notes' >"${base}/myrepo/20260624-194043-big-task-implementation-notes.html"
  printf '%s\n' 'review' >"${base}/myrepo/20260624-194043-review-result.md"
  printf '%s\n' 'sibling' >"${base}/myrepo/other-task-note.md"
  cat >>"${base}/myrepo/index.md" <<'EOF'
- [x] Completed big task
  - [20260620_101010] 🎭 要件
    - 📓 実装ノート: 20260624-194043-big-task-implementation-notes.html
    - 📋 レビュー結果: 20260624-194043-review-result.md
  - [20260624_194043] 🎉 完了
    - did the thing
EOF

  run_tasks -c >/dev/null 2>&1 || true

  local dir idx
  dir="${base}/myrepo/20260624-194043_test-task-1"
  idx="${dir}/index.md"
  check 'clean-split: dir は最新 [ts] 20260624-194043 を使う' \
    '1' "$([[ -f ${idx} ]] && echo 1 || echo 0)"
  check 'clean-split: front matter status に ✅️' \
    '1' "$([[ -f ${idx} ]] && grep -qx 'status: ✅️' "${idx}" && echo 1 || echo 0)"
  check 'clean-split: title に ✅️ 付与' \
    '1' "$([[ -f ${idx} ]] && grep -qE '^title: ✅️ ' "${idx}" && echo 1 || echo 0)"
  check 'clean-split: body 保持' \
    '1' "$([[ -f ${idx} ]] && grep -qF 'did the thing' "${idx}" && echo 1 || echo 0)"
  check 'clean-split: 実装ノート HTML を split 先へ移動' \
    '1' "$([[ -f ${dir}/20260624-194043-big-task-implementation-notes.html ]] && echo 1 || echo 0)"
  check 'clean-split: レビュー結果 md を split 先へ移動' \
    '1' "$([[ -f ${dir}/20260624-194043-review-result.md ]] && echo 1 || echo 0)"
  check 'clean-split: 移動した関連ファイルを元 dir から除去' \
    '0' "$([[ -f ${base}/myrepo/20260624-194043-big-task-implementation-notes.html ]] && echo 1 || echo 0)"
  check 'clean-split: 本文が言及しない loose file は移動しない' \
    '1' "$([[ -f ${base}/myrepo/other-task-note.md ]] && echo 1 || echo 0)"

  # 内容日付 (ブロック内最新 ts = 2026-06-24) の log へ転記する (実行日でなく)
  local log
  log="${envdir}/logs/2026/2026-06-01-log.md"
  check 'clean-split: 参照を内容日付 (2026-06) の log へ転記' \
    '1' "$(grep -qE -- '_test-task-1\]' "${log}" 2>/dev/null && echo 1 || echo 0)"
  check 'clean-split: 完了ブロックを index.md から除去' \
    '0' "$(grep -qF -- 'Completed big task' "${base}/myrepo/index.md" && echo 1 || echo 0)"
  check 'clean-split: normal も参照行を index.md に残す' \
    '1' "$(grep -qE -- '_test-task-1\]\(' "${base}/myrepo/index.md" && echo 1 || echo 0)"
}

# 13b. clean: 1 行のみ (本文なし) の完了タスクは split せず生の行を log へ転記し、
# index.md からは削除する (dir も参照行も作らない)。
test_clean_single_line_no_split() {
  new_env t13b myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  # 本文なしの 1 行完了タスク (内容日付は行内 [ts] = 2026-06-24)
  printf '%s\n' '- [x] [20260624_194043] single line done task' >>"${base}/myrepo/index.md"

  run_tasks -c --all >/dev/null 2>&1 || true

  local log
  log="${envdir}/logs/2026/2026-06-01-log.md"
  check 'clean-single: split dir を作らない' \
    '0' "$(find "${base}/myrepo" -maxdepth 1 -type d -name '*_test-task-*' | wc -l)"
  check 'clean-single: 生の行を内容日付 (2026-06) の log へ転記' \
    '1' "$(grep -qF -- '- [x] [20260624_194043] single line done task' "${log}" 2>/dev/null && echo 1 || echo 0)"
  check 'clean-single: タスクを index.md から削除' \
    '0' "$(grep -qF -- 'single line done task' "${base}/myrepo/index.md" && echo 1 || echo 0)"
}

# 14. clean: タスク内に [ts] 無ければ clean 実行時 timestamp を使う
test_clean_timestamp_fallback_to_now() {
  new_env t14 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  cat >>"${base}/myrepo/index.md" <<'EOF'
- [x] No timestamp task
  - just done, no bracket ts
EOF

  run_tasks -c >/dev/null 2>&1 || true

  local today dir
  today=$(date +%Y%m%d)
  dir=$(find "${base}/myrepo" -maxdepth 1 -type d -name "${today}-*_test-task-1" | head -1)
  check 'clean-fallback: dir は clean 実行時 timestamp (今日)' \
    '1' "$([[ -n ${dir} ]] && echo 1 || echo 0)"
}

# 14b. clean: 内容日付が判定できない (ブロックに [ts] 無し) 場合は警告し実行日の log へ転記
test_clean_warns_when_entry_date_unknown() {
  new_env t14b myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  cat >>"${base}/myrepo/index.md" <<'EOF'
- [x] No timestamp task
  - just done, no bracket ts
EOF

  # run_tasks は stdout/stderr を 2>&1 で束ねて返す
  local out
  out=$(run_tasks -c --all)

  check 'clean-unknown: 内容日付不明で警告を出す' \
    '1' "$([[ ${out} == *"Cannot determine entry date"* ]] && echo 1 || echo 0)"

  # 内容日付不明時は実行日 (今日) の log へフォールバックして転記する
  local today_log
  today_log="${envdir}/logs/$(date +%Y)/$(date +%Y-%m)-01-log.md"
  check 'clean-unknown: 実行日の log へフォールバック転記' \
    '1' "$(grep -qE -- '_test-task-1\]' "${today_log}" 2>/dev/null && echo 1 || echo 0)"
}

# 15. clean: 未完了 - [ ] タスクは split 対象外で残す
test_clean_skips_pending_tasks() {
  new_env t15 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  cat >>"${base}/myrepo/index.md" <<'EOF'
- [ ] Pending plain task
- [x] Completed to split
  - [20260624_194043] 🎉 完了
EOF

  run_tasks -c >/dev/null 2>&1 || true

  check 'clean-skip: 未完了タスクは残す (split しない)' \
    '1' "$(grep -qF -- '- [ ] Pending plain task' "${base}/myrepo/index.md" && echo 1 || echo 0)"
  check 'clean-skip: 完了タスクは split 済み (ブロック消滅)' \
    '0' "$(grep -qF -- 'Completed to split' "${base}/myrepo/index.md" && echo 1 || echo 0)"
}

# 16. clean(worktree): 完了タスクを split・log 転記するが参照行は削除しない (再実行で重複なし)
test_clean_worktree_keeps_reference() {
  new_env t16 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  git -C "${repo}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  local wt="${envdir}/myrepo-worktree/feature-x"
  mkdir -p "$(dirname "${wt}")"
  git -C "${repo}" worktree add -q -b feature-x "${wt}" >/dev/null 2>&1

  # worktree の link 自己修復で index.md を生成
  (cd "${wt}" &&
    XDG_CONFIG_HOME="${xdg}" TASKS_GEN_META_CMD="${fake_meta}" \
      FAKE_META_COUNTER="${meta_counter}" "${tasks_bin}" --summary) >/dev/null 2>&1 || true

  local wt_md
  wt_md=$(readlink "${wt}/.tasks.md")
  cat >>"${wt_md}" <<'EOF'

- [x] Worktree done task
  - [20260624_194043] 🎉 完了
    - did it
EOF

  run_wt() {
    (cd "${wt}" &&
      PATH="${fakebin}:${PATH}" \
        XDG_CONFIG_HOME="${xdg}" TASKS_GEN_META_CMD="${fake_meta}" \
        FAKE_META_COUNTER="${meta_counter}" FAKE_FZF_LOG="${fzf_log}" \
        "${tasks_bin}" "$@") >/dev/null 2>&1
  }

  # worktree でも未 split 完了インラインタスクは clean で split+転記できる (手動 clean)
  run_wt -c --all || true

  check 'clean-wt: 参照行を index.md に残す (削除しない)' \
    '1' "$(grep -qE -- '^- \[x\] \[[^]]*_test-task-1\]\(' "${wt_md}" && echo 1 || echo 0)"

  # 内容日付 (ブロック内 ts = 2026-06-24) の log へ転記する
  local log
  log="${envdir}/logs/2026/2026-06-01-log.md"
  check 'clean-wt: 参照を内容日付 (2026-06) の log へ転記' \
    '1' "$(grep -qE -- '_test-task-1\]' "${log}" 2>/dev/null && echo 1 || echo 0)"

  run_wt -c --all || true
  check 'clean-wt: 再実行で log 重複なし (1 件)' \
    '1' "$(grep -cE -- '_test-task-[0-9]+\]' "${log}" 2>/dev/null || true)"
  check 'clean-wt: 再実行で split dir 増えず (再 split しない)' \
    '1' "$(find "${base}/myrepo" -maxdepth 1 -type d -name '*_test-task-*' | wc -l)"
  check 'clean-wt: 再実行後も参照行残存' \
    '1' "$(grep -qE -- '^- \[x\] \[[^]]*_test-task-1\]\(' "${wt_md}" && echo 1 || echo 0)"
}

# 17. clean --all: 未 split 完了タスクを全件 split+転記 (fzf 非経由・非対話で安全)
test_clean_all_flag() {
  new_env t17 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  # 内容日付は別の月にして log ファイルの振り分けを検証する (log_fmt は %Y-%m-01 = 月単位)
  cat >>"${base}/myrepo/index.md" <<'EOF'
- [x] Done one
  - [20260101_000000] 🎉 完了
- [x] Done two
  - [20260315_000000] 🎉 完了
EOF

  run_tasks -c --all >/dev/null 2>&1 || true

  # 内容日付が異なる2件はそれぞれの日付の log ファイルへ振り分けられる
  local log1 log2 today_log dir_count
  log1="${envdir}/logs/2026/2026-01-01-log.md"
  log2="${envdir}/logs/2026/2026-03-01-log.md"
  today_log="${envdir}/logs/$(date +%Y)/$(date +%Y-%m)-01-log.md"
  dir_count=$(find "${base}/myrepo" -maxdepth 1 -type d -name '*_test-task-*' | wc -l)
  check 'clean-all: 完了2件を split (dir 2)' '2' "${dir_count}"
  check 'clean-all: 2026-01 の完了は 2026-01 log へ' \
    '1' "$(grep -qE -- '20260101-000000_test-task' "${log1}" 2>/dev/null && echo 1 || echo 0)"
  check 'clean-all: 2026-03 の完了は 2026-03 log へ' \
    '1' "$(grep -qE -- '20260315-000000_test-task' "${log2}" 2>/dev/null && echo 1 || echo 0)"
  check 'clean-all: 2026-01 log に 2026-03 分は混ざらない' \
    '0' "$(grep -qE -- '20260315' "${log1}" 2>/dev/null && echo 1 || echo 0)"
  check 'clean-all: 実行日 (今日) の log には転記しない' \
    '0' "$([[ -f ${today_log} ]] && grep -qE -- '_test-task-[0-9]+\]' "${today_log}" && echo 1 || echo 0)"
  check 'clean-all: fzf を経由しない (非対話)' \
    '0' "$([[ -s ${fzf_log} ]] && echo 1 || echo 0)"
}

# 18. clean N: Nth 完了タスクのみ split+転記し、他は未 split のまま残す
test_clean_select_nth() {
  new_env t18 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  cat >>"${base}/myrepo/index.md" <<'EOF'
- [x] Done one
  - [20260101_000000] 🎉 完了
- [x] Done two
  - [20260102_000000] 🎉 完了
EOF

  run_tasks -c 1 >/dev/null 2>&1 || true

  # Nth=1 = "Done one" (内容日付 2026-01) のみ、その日付の log へ転記
  local log
  log="${envdir}/logs/2026/2026-01-01-log.md"
  check 'clean-nth: 1件のみ内容日付 (2026-01) の log へ転記 (Nth のみ)' \
    '1' "$(grep -cE -- '_test-task-[0-9]+\]' "${log}" 2>/dev/null || true)"
  check 'clean-nth: 1件目は split 済み (ブロック消滅)' \
    '0' "$(grep -qF -- '- [x] Done one' "${base}/myrepo/index.md" && echo 1 || echo 0)"
  check 'clean-nth: 2件目は未 split で残す' \
    '1' "$(grep -qF -- '- [x] Done two' "${base}/myrepo/index.md" && echo 1 || echo 0)"
}

# 19. split --all: 全 pending タスクを fzf 非経由で split する (--all の汎用性)
test_split_all_flag() {
  new_env t19 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  {
    printf '%s\n' '- [ ] Task one'
    printf '%s\n' '- [ ] Task two'
  } >>"${base}/myrepo/index.md"

  run_tasks -s --all >/dev/null 2>&1 || true

  local dir_count ref_count
  dir_count=$(find "${base}/myrepo" -mindepth 2 -name index.md 2>/dev/null | wc -l)
  ref_count=$(grep -cE '^- \[ \] \[[^]]*\]\(' "${base}/myrepo/index.md" 2>/dev/null || echo 0)
  check 'split-all-flag: 全 pending を dir へ split' '2' "${dir_count}"
  check 'split-all-flag: 全 pending を参照行へ置換' '2' "${ref_count}"
  check 'split-all-flag: fzf を経由しない' \
    '0' "$([[ -s ${fzf_log} ]] && echo 1 || echo 0)"
}

# 20. clean(worktree): 完了参照行は候補外。log 転記せず index.md にも残す
# 完了参照行は normal/worktree とも候補外 (split 済み完了は complete 側で log 転記済み)。
test_clean_worktree_excludes_done_reference() {
  new_env t20 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  git -C "${repo}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  local wt="${envdir}/myrepo-worktree/feature-y"
  mkdir -p "$(dirname "${wt}")"
  git -C "${repo}" worktree add -q -b feature-y "${wt}" >/dev/null 2>&1

  (cd "${wt}" &&
    XDG_CONFIG_HOME="${xdg}" TASKS_GEN_META_CMD="${fake_meta}" \
      FAKE_META_COUNTER="${meta_counter}" "${tasks_bin}" --summary) >/dev/null 2>&1 || true

  local wt_md
  wt_md=$(readlink "${wt}/.tasks.md")
  # 既に split 済みの完了参照行を直接投入 (worktree では候補外になるべき)
  printf '%s\n' \
    '- [x] [20260101-000000_prior](base/myrepo/20260101-000000_prior/index.md)' >>"${wt_md}"

  (cd "${wt}" &&
    PATH="${fakebin}:${PATH}" \
      XDG_CONFIG_HOME="${xdg}" TASKS_GEN_META_CMD="${fake_meta}" \
      FAKE_META_COUNTER="${meta_counter}" FAKE_FZF_LOG="${fzf_log}" \
      "${tasks_bin}" -c --all) >/dev/null 2>&1 || true

  local y ym log
  y=$(date +%Y) && ym=$(date +%Y-%m)
  log="${envdir}/logs/${y}/${ym}-01-log.md"
  check 'clean-wt-excl: 完了参照行は log へ転記しない' \
    '0' "$([[ -f ${log} ]] && grep -qF -- '_prior]' "${log}" && echo 1 || echo 0)"
  check 'clean-wt-excl: 完了参照行は index.md に残る' \
    '1' "$(grep -qF -- '20260101-000000_prior' "${wt_md}" && echo 1 || echo 0)"
}

# 22. log 転記: ref の timestamp から日付見出し (## YYYY-MM-DD (曜)) を生成し見出し配下へ
# 記録する。同日付の参照を複数転記しても見出しは重複しない (冪等)。
test_log_writes_dated_header() {
  new_env t22 myrepo
  write_config "${base}"
  local repo_base="${base}/myrepo"
  local dir1="${repo_base}/20260101-000000_one"
  local dir2="${repo_base}/20260101-235959_two"
  local ref1='base/myrepo/20260101-000000_one/index.md'
  local ref2='base/myrepo/20260101-235959_two/index.md'
  mkdir -p "${dir1}" "${dir2}"
  {
    printf '%s\n' "- [ ] [20260101-000000_one](${ref1})"
    printf '%s\n' "- [ ] [20260101-235959_two](${ref2})"
  } >"${repo_base}/index.md"
  cat >"${dir1}/index.md" <<EOF
---
title: One
branch: feature/one
name: one
status:
parent: ${repo_base}/index.md
---

EOF
  cat >"${dir2}/index.md" <<EOF
---
title: Two
branch: feature/two
name: two
status:
parent: ${repo_base}/index.md
---

EOF

  run_tasks ok -f "${dir1}/index.md" >/dev/null 2>&1 || true
  run_tasks ok -f "${dir2}/index.md" >/dev/null 2>&1 || true

  # 完了参照の内容日付 (2026-01) の log ファイルへ、その日付見出しで記録する
  local log header
  log="${envdir}/logs/2026/2026-01-01-log.md"
  header=$(date -d 20260101 +'## %Y-%m-%d (%a)')
  check 'log-header: ref timestamp から日付見出しを生成' \
    '1' "$(grep -qxF -- "${header}" "${log}" 2>/dev/null && echo 1 || echo 0)"
  check 'log-header: 同日付の見出しは重複しない (1 件)' \
    '1' "$(grep -cxF -- "${header}" "${log}" 2>/dev/null || true)"
  check 'log-header: 両参照を見出し配下へ記録' \
    '2' "$(grep -cE -- '_(one|two)\]\(' "${log}" 2>/dev/null || true)"
}

# 21. preview: 実ブロックはブロック境界まで、参照行は参照先 index.md を表示
test_preview_line_block_and_ref() {
  new_env t21 myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  mkdir -p "${base}/myrepo/refdir"
  printf '%s\n' 'REF INDEX CONTENT' 'second line' >"${base}/myrepo/refdir/index.md"
  cat >>"${base}/myrepo/index.md" <<'EOF'
- [ ] plain pending
- [x] done block line1
  - sub detail
- [ ] [reftitle](base/myrepo/refdir/index.md)
EOF

  local idx="${base}/myrepo/index.md"
  check 'preview: 単一行ブロックは1行のみ' \
    '- [ ] plain pending' \
    "$(run_tasks -f "${idx}" --preview-line 1)"
  check 'preview: 実ブロックはブロック境界まで表示' \
    '- [x] done block line1
  - sub detail' \
    "$(run_tasks -f "${idx}" --preview-line 2)"
  check 'preview: 参照行は参照先 index.md を表示' \
    'REF INDEX CONTENT
second line' \
    "$(run_tasks -f "${idx}" --preview-line 4)"
}

# 14. pr: pr を包み、成功時だけ status へ 🚀 を足す
# front matter 持ち index.md を worktree の .tasks.md に見立てて -f で直接指す。
test_pr_marks_status() {
  new_env t14 myrepo
  write_config "${base}"
  local dir="${base}/myrepo/20260101-000000_prtask"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<EOF
---
title: PR Me
branch: feature/foo
name: prtask
status:
parent: ${base}/myrepo/index.md
---

EOF

  run_tasks -f "${dir}/index.md" pr -d /tmp/pr origin/main >/dev/null 2>&1 || true

  check 'pr: status に 🚀 が入る' \
    '1' "$(grep -qx 'status: 🚀' "${dir}/index.md" && echo 1 || echo 0)"
  check 'pr: 引数をそのまま pr へ渡す' \
    '1' "$(grep -qF -- '-d /tmp/pr origin/main' "${pr_log}" 2>/dev/null && echo 1 || echo 0)"
  check 'pr: tasks 自身の -f は pr へ渡さない' \
    '0' "$(grep -qF -- '-f ' "${pr_log}" 2>/dev/null && echo 1 || echo 0)"
}

# 14b. pr: pr が失敗したら status は変えない
test_pr_failure_keeps_status() {
  new_env t14b myrepo
  write_config "${base}"
  pr_exit=1
  local dir="${base}/myrepo/20260101-000000_prfail"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<EOF
---
title: PR Fail
branch: feature/foo
name: prfail
status:
parent: ${base}/myrepo/index.md
---

EOF

  run_tasks -f "${dir}/index.md" pr origin/main >/dev/null 2>&1 || true

  check 'pr-fail: status は空のまま' \
    '1' "$(grep -qx 'status:' "${dir}/index.md" && echo 1 || echo 0)"
}

# 14c. pr: 完了済みへ PR 印を足すと 🚀✅️ の順に正規化する
test_pr_normalizes_mark_order() {
  new_env t14c myrepo
  write_config "${base}"
  local dir="${base}/myrepo/20260101-000000_prorder"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<EOF
---
title: PR Order
branch: feature/foo
name: prorder
status: ✅️
parent: ${base}/myrepo/index.md
---

EOF

  run_tasks -f "${dir}/index.md" pr origin/main >/dev/null 2>&1 || true

  check 'pr-order: 完了済みへ足すと 🚀✅️ の順になる' \
    '1' "$(grep -qx 'status: 🚀✅️' "${dir}/index.md" && echo 1 || echo 0)"
}

# 14d. pr: 同じ印を 2 回足しても重複しない
test_pr_mark_is_idempotent() {
  new_env t14d myrepo
  write_config "${base}"
  local dir="${base}/myrepo/20260101-000000_pridem"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<EOF
---
title: PR Idem
branch: feature/foo
name: pridem
status: 🚀
parent: ${base}/myrepo/index.md
---

EOF

  run_tasks -f "${dir}/index.md" pr origin/main >/dev/null 2>&1 || true

  check 'pr-idem: 🚀 は 1 つのまま' \
    '1' "$(grep -qx 'status: 🚀' "${dir}/index.md" && echo 1 || echo 0)"
}

# 14e. complete: PR 済みを完了すると 🚀✅️ の 2 つが残る
test_complete_keeps_pr_mark() {
  new_env t14e myrepo
  write_config "${base}"
  local repo_base="${base}/myrepo"
  local dir="${repo_base}/20260101-000000_prdone"
  local ref='base/myrepo/20260101-000000_prdone/index.md'
  mkdir -p "${dir}"
  printf '%s\n' "- [ ] [20260101-000000_prdone](${ref})" >"${repo_base}/index.md"
  cat >"${dir}/index.md" <<EOF
---
title: PR Done
branch: feature/foo
name: prdone
status: 🚀
parent: ${repo_base}/index.md
---

EOF

  run_tasks ok -f "${dir}/index.md" >/dev/null 2>&1 || true

  check 'complete-pr: 🚀 を残したまま ✅️ を足す' \
    '1' "$(grep -qx 'status: 🚀✅️' "${dir}/index.md" && echo 1 || echo 0)"
}

# 14f. pr: front matter が無いタスクファイルでは PR だけ実行し印は飛ばす
test_pr_without_front_matter_warns() {
  new_env t14f myrepo
  write_config "${base}"
  run_tasks --summary >/dev/null 2>&1 || true
  printf '%s\n' '- [ ] plain task' >>"${base}/myrepo/index.md"

  local out
  out=$(run_tasks pr origin/main 2>&1 || true)

  check 'pr-nofm: pr は実行する' \
    '1' "$(grep -qF -- 'origin/main' "${pr_log}" 2>/dev/null && echo 1 || echo 0)"
  # 'status' だけだと成功メッセージ (Task status marked as PR created) にも当たる
  check 'pr-nofm: front matter が無い旨を警告する' \
    '1' "$([[ ${out} == *"No task file with front matter"* ]] && echo 1 || echo 0)"
}

# 14g. pr: .tasks.md が無いリポジトリでも PR は通し、store にリンクを生やさない
test_pr_without_tasks_file() {
  new_env t14g myrepo
  write_config "${base}"

  local out
  out=$(run_tasks pr origin/main 2>&1 || true)

  check 'pr-notask: pr は実行する' \
    '1' "$(grep -qF -- 'origin/main' "${pr_log}" 2>/dev/null && echo 1 || echo 0)"
  check 'pr-notask: 印を飛ばした旨を警告する' \
    '1' "$([[ ${out} == *"status not marked"* ]] && echo 1 || echo 0)"
  # 要点: タスクを持たないリポジトリで pr を打っただけで store を汚さない
  check 'pr-notask: .tasks.md を生成しない' \
    '0' "$([[ -e ${repo}/.tasks.md ]] && echo 1 || echo 0)"
  check 'pr-notask: .tasks を生成しない' \
    '0' "$([[ -e ${repo}/.tasks ]] && echo 1 || echo 0)"
  check 'pr-notask: store に repo ディレクトリを作らない' \
    '0' "$([[ -e ${base}/myrepo ]] && echo 1 || echo 0)"
}

# 14h. pr: pr の終了コードをそのまま返す (die で 1 に潰さない)
test_pr_propagates_exit_code() {
  new_env t14h myrepo
  write_config "${base}"
  pr_exit=3

  check 'pr-exit: pr の終了コードをそのまま返す' \
    '3' "$(run_tasks_status pr origin/main)"
}

# 14i. complete: status 行が無い front matter は黙って落ちず die する
test_complete_without_status_line_dies() {
  new_env t14i myrepo
  write_config "${base}"
  local dir="${base}/myrepo/20260101-000000_nostatus"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<EOF
---
title: No Status
branch: feature/foo
name: nostatus
parent: ${base}/myrepo/index.md
---

EOF

  local out
  out=$(run_tasks ok -f "${dir}/index.md" 2>&1 || true)

  check 'complete-nostatus: 無言で終わらせず理由を出す' \
    '1' "$([[ ${out} == *"status:"* ]] && echo 1 || echo 0)"
}

# 14j. pr: status 行が無くても PR 発行後は成功で返す (再実行で PR が二重に立たない)
test_pr_without_status_line_succeeds() {
  new_env t14j myrepo
  write_config "${base}"
  local dir="${base}/myrepo/20260101-000000_prnostatus"
  mkdir -p "${dir}"
  cat >"${dir}/index.md" <<EOF
---
title: PR No Status
branch: feature/foo
name: prnostatus
parent: ${base}/myrepo/index.md
---

EOF

  local out
  out=$(run_tasks -f "${dir}/index.md" pr origin/main 2>&1 || true)

  check 'pr-nostatus: PR 発行後は成功で返す' \
    '0' "$(run_tasks_status -f "${dir}/index.md" pr origin/main)"
  check 'pr-nostatus: pr は実行済み' \
    '1' "$(grep -qF -- 'origin/main' "${pr_log}" 2>/dev/null && echo 1 || echo 0)"
  # 成功で返す代わりに、印を付けられなかった理由は必ず出す (無言で飛ばさない)
  check 'pr-nostatus: status 行が無い旨を警告する' \
    '1' "$([[ ${out} == *"No 'status:' line"* ]] && echo 1 || echo 0)"
}

# 14k. pr: VS16 無しの ✅ でも完了印を取り違えず、🚀 を足すだけにする
test_pr_keeps_vs16less_complete_mark() {
  new_env t14k myrepo
  write_config "${base}"
  local dir="${base}/myrepo/20260101-000000_vs16less"
  mkdir -p "${dir}"
  # status は人が手でも書く場所。VS16 (U+FE0F) 無しの ✅ が来ても完了印として扱う
  printf -- '---\ntitle: T\nbranch: b\nname: vs16less\nstatus: \u2705\nparent: %s\n---\n\n' \
    "${base}/myrepo/index.md" >"${dir}/index.md"

  run_tasks -f "${dir}/index.md" pr origin/main >/dev/null 2>&1 || true

  # 出力は正規形 (VS16 付き) に揃う。要点は完了印が消えないこと
  check 'pr-vs16less: 完了印を消さず 🚀 を前に足す' \
    '1' "$(grep -qx "status: $(printf '\U0001F680\u2705\ufe0f')" "${dir}/index.md" && echo 1 || echo 0)"
}

main() {
  set -uo pipefail
  tmproot=$(mktemp -d)
  trap 'rm -rf "${tmproot}"' EXIT
  local pass=0 fail=0
  write_fake_meta
  write_fake_bins

  test_creates_index_md_link
  test_dies_without_config
  test_dies_without_store_root
  test_dies_without_tasks_subdir
  test_dies_without_log_fmt
  test_dies_with_relative_store_root
  test_accepts_quoted_tilde_store_root
  test_requires_config_even_with_links
  test_worktree_self_heals_links
  test_split_creates_dir_and_reference
  test_split_all_removed
  test_split_creates_worktree
  test_spawn_splits_unsplit_then_tmux
  test_spawn_skips_existing_worktree
  test_spawn_default_sends_claude_command
  test_spawn_codex_sends_codex_command
  test_split_multi_select_all
  test_summary_reads_front_matter_title
  test_complete_front_matter_task
  test_complete_front_matter_task_worktree_ref
  test_complete_normal_task
  test_complete_skips_reference
  test_clean_excludes_done_reference
  test_clean_splits_unsplit_completed_task
  test_clean_single_line_no_split
  test_clean_timestamp_fallback_to_now
  test_clean_warns_when_entry_date_unknown
  test_clean_skips_pending_tasks
  test_clean_worktree_keeps_reference
  test_clean_all_flag
  test_clean_select_nth
  test_split_all_flag
  test_clean_worktree_excludes_done_reference
  test_log_writes_dated_header
  test_preview_line_block_and_ref
  test_pr_marks_status
  test_pr_failure_keeps_status
  test_pr_normalizes_mark_order
  test_pr_mark_is_idempotent
  test_complete_keeps_pr_mark
  test_pr_without_front_matter_warns
  test_pr_without_tasks_file
  test_pr_propagates_exit_code
  test_complete_without_status_line_dies
  test_pr_without_status_line_succeeds
  test_pr_keeps_vs16less_complete_mark

  printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
  [[ ${fail} -eq 0 ]]
}

main "$@"
