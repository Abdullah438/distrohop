# sourced by distrohop — interactive checklist (restore picker)

# UI_IDS[], UI_LABELS[], UI_ON[] (0|1)
# On success: UI_PICKED is a space-separated list of ids. Return 1 if cancelled.

ui_checklist() {
  UI_PICKED=""
  local n=${#UI_IDS[@]}
  (( n > 0 )) || return 0

  if [[ -c /dev/tty ]]; then
    local st=0
    ui_checklist_tty
    st=$?
    (( st == 0 )) && return 0
    (( st == 1 )) && return 1
  fi

  if command -v whiptail >/dev/null 2>&1 && [[ -c /dev/tty ]]; then
    ui_checklist_whiptail && return 0
    return 1
  fi

  [[ -c /dev/tty ]] || return 1
  ui_checklist_numbered
}

ui_checklist_tty() {
  local n=${#UI_IDS[@]} cur=0 i key k2 k3
  local rs=$C_RESET hi=$C_CYN dim=$C_DIM

  printf '\033[?25l' > /dev/tty
  stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null || return 2
  trap 'stty sane < /dev/tty 2>/dev/null; printf "\033[?25h" > /dev/tty' RETURN

  local drawn=0
  _ui_draw() {
    local i mark ptr buf=""
    buf+="${C_BOLD}What should distrohop restore?${rs}"$'\n'
    buf+="${dim}space toggle  enter confirm  a all  n none  q abort${rs}"$'\n'$'\n'
    for (( i=0; i<n; i++ )); do
      if (( UI_ON[i] )); then
        mark="${C_GRN}[x]${rs}"
      else
        mark="[ ]"
      fi
      if (( i == cur )); then ptr="${hi}❯${rs} "; else ptr="  "; fi
      buf+="${ptr}${mark} ${C_BOLD}${UI_IDS[i]}${rs}  ${dim}${UI_LABELS[i]}${rs}"$'\n'
    done
    if (( drawn )); then
      printf '\033[%sA\033[J' "$drawn" > /dev/tty
    fi
    printf '%s' "$buf" > /dev/tty
    drawn=$(printf '%s' "$buf" | wc -l)
  }

  _ui_draw
  while true; do
    key=""; k2=""; k3=""
    IFS= read -rsn1 key < /dev/tty || true
    if [[ $key == $'\x1b' ]]; then
      IFS= read -rsn1 -t 0.05 k2 < /dev/tty || true
      IFS= read -rsn1 -t 0.05 k3 < /dev/tty || true
      key+="${k2}${k3}"
    fi
    case $key in
      $'\x1b[A'|$'\x1bOA'|k)
        (( cur > 0 )) && cur=$((cur - 1))
        ;;
      $'\x1b[B'|$'\x1bOB'|j)
        (( cur < n - 1 )) && cur=$((cur + 1))
        ;;
      ' ')
        if (( UI_ON[cur] )); then UI_ON[cur]=0; else UI_ON[cur]=1; fi
        ;;
      a|A)
        for (( i=0; i<n; i++ )); do UI_ON[i]=1; done
        ;;
      n|N)
        for (( i=0; i<n; i++ )); do UI_ON[i]=0; done
        ;;
      q|Q|$'\x03')
        printf '\n' > /dev/tty
        return 1
        ;;
      ''|$'\n'|$'\r')
        break
        ;;
      *)
        continue
        ;;
    esac
    _ui_draw
  done
  printf '\n' > /dev/tty

  local picked=()
  for (( i=0; i<n; i++ )); do
    (( UI_ON[i] )) && picked+=("${UI_IDS[i]}")
  done
  UI_PICKED="${picked[*]}"
  return 0
}

ui_checklist_whiptail() {
  local n=${#UI_IDS[@]} i args=() state
  for (( i=0; i<n; i++ )); do
    if (( UI_ON[i] )); then state=ON; else state=OFF; fi
    args+=("${UI_IDS[i]}" "${UI_LABELS[i]}" "$state")
  done
  local height=$((n + 8))
  (( height > 22 )) && height=22
  local result
  result=$(whiptail --title "distrohop restore" --checklist \
    "Space toggles an item. Tab to OK." "$height" 78 "$n" \
    "${args[@]}" 3>&1 1>&2 2>&3) || return 1
  UI_PICKED=${result//\"/}
  return 0
}

ui_checklist_numbered() {
  local n=${#UI_IDS[@]} i mark
  printf '\n%sWhat should distrohop restore?%s\n' "$C_BOLD" "$C_RESET" > /dev/tty
  printf '%sEnter numbers (e.g. 1 2 5), all, or none. Empty keeps the [x] defaults.%s\n\n' "$C_DIM" "$C_RESET" > /dev/tty
  for (( i=0; i<n; i++ )); do
    if (( UI_ON[i] )); then mark="[x]"; else mark="[ ]"; fi
    printf '  %2d  %s %-12s  %s\n' "$((i + 1))" "$mark" "${UI_IDS[i]}" "${UI_LABELS[i]}" > /dev/tty
  done
  local ans
  printf '\n> ' > /dev/tty
  IFS= read -r ans < /dev/tty || return 1
  ans=${ans#"${ans%%[![:space:]]*}"}
  ans=${ans%"${ans##*[![:space:]]}"}
  case $ans in
    q|Q|abort|cancel) return 1 ;;
    all)
      UI_PICKED="${UI_IDS[*]}"
      return 0
      ;;
    none)
      UI_PICKED=""
      return 0
      ;;
    "")
      local picked=()
      for (( i=0; i<n; i++ )); do
        (( UI_ON[i] )) && picked+=("${UI_IDS[i]}")
      done
      UI_PICKED="${picked[*]}"
      return 0
      ;;
  esac
  local picked=() tok idx
  for tok in $ans; do
    [[ $tok =~ ^[0-9]+$ ]] || continue
    idx=$((tok - 1))
    (( idx >= 0 && idx < n )) && picked+=("${UI_IDS[idx]}")
  done
  UI_PICKED="${picked[*]}"
  return 0
}
