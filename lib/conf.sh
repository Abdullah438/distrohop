# shellcheck shell=bash
# sourced by keepsake — generic key=value config-file loader
# shellcheck disable=SC2034

# conf_load_kv FILE KEY... — reads FILE (comments/blanks ignored, split on
# the first '=', surrounding quotes stripped) and sets each listed KEY as a
# global via printf -v, but only for lines whose key is in the allow-list.
# Returns 1 if FILE doesn't exist.
conf_load_kv() {
  local file=$1; shift
  local keys=" $* "
  [[ -f $file ]] || return 1
  local line k v
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *'='* ]] || continue
    k=${line%%=*}; v=${line#*=}
    k=${k//[[:space:]]/}
    v=${v#\"}; v=${v%\"}
    v=${v#\'}; v=${v%\'}
    [[ $keys == *" $k "* ]] && printf -v "$k" '%s' "$v"
  done < "$file"
}
