#!/usr/bin/env bash

# bin/gen_sops_yaml のユニットテスト。
#
# age-keygen は本物を使い、HOME を一時ディレクトリに差し替えて鍵を作る。
# 生成した .sops.yaml で sops が実際に暗号化できるかまで見る
# (yaml の形が sops の期待とずれていても、文字列比較だけでは気付けない為)。
#
#   test/gen_sops_yaml.test.sh   # 全テスト実行

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gen_bin=$(cd "${script_dir}/../bin" && pwd)/gen_sops_yaml

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

# テスト毎に空の作業ディレクトリと、鍵入りの HOME を用意する。
setup_case() {
  work=$(mktemp -d -p "${tmproot}")
  # lint-ignore: uppercase 本物の鍵を触らないよう HOME ごと差し替える
  export HOME="${work}/home"
  unset SOPS_AGE_KEY_FILE
  mkdir -p "${HOME}/.config/sops/age"
  age-keygen -o "${HOME}/.config/sops/age/keys.txt" 2>/dev/null
  mykey=$(age-keygen -y "${HOME}/.config/sops/age/keys.txt")
  cd "${work}" || exit 1
}

# 1. 自分の公開鍵だけのルールを書き、そのまま sops で暗号化できる。
test_generates_with_own_key() {
  setup_case
  "${gen_bin}" >/dev/null

  check '自分の公開鍵でルールを書く' "creation_rules:
  - path_regex: \\.enc\\.(ya?ml|json|env)\$
    age: ${mykey}" "$(cat .sops.yaml)"

  echo 'PASS=secret' >a.enc.env
  sops encrypt -i a.enc.env
  check 'sops で暗号化 -> 復号できる' 'PASS=secret' "$(sops decrypt a.enc.env)"
}

# 2. 引数の公開鍵を自分の鍵の後ろにカンマ区切りで足す。
test_appends_recipients() {
  setup_case
  local other
  other=$(age-keygen 2>/dev/null | age-keygen -y)
  "${gen_bin}" "${other}" >/dev/null

  check '引数の鍵を足す' "    age: ${mykey},${other}" "$(grep 'age:' .sops.yaml)"
}

# 3. 既存の .sops.yaml は上書きしない。手で足したルールを消さない為。
test_refuses_to_overwrite() {
  setup_case
  echo keep >.sops.yaml

  "${gen_bin}" >/dev/null 2>&1
  check '既存があれば失敗する' '1' "$?"
  check '既存を書き換えない' 'keep' "$(cat .sops.yaml)"
}

# 4. 鍵が無い / 引数が age 公開鍵でない時は、ファイルを作らずに失敗する。
test_rejects_bad_input() {
  setup_case
  SOPS_AGE_KEY_FILE="${work}/none" "${gen_bin}" >/dev/null 2>&1
  check '鍵が無ければ失敗する' '1' "$?"

  "${gen_bin}" not-a-key >/dev/null 2>&1
  check '不正な公開鍵なら失敗する' '1' "$?"
  check '失敗時はファイルを作らない' 'no' "$([[ -e .sops.yaml ]] && echo yes || echo no)"
}

main() {
  tmproot=$(mktemp -d)
  trap 'rm -rf "${tmproot}"' EXIT
  pass=0
  fail=0

  test_generates_with_own_key
  test_appends_recipients
  test_refuses_to_overwrite
  test_rejects_bad_input

  printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
  [[ ${fail} -eq 0 ]]
}

main "$@"
