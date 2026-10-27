#!/usr/bin/env bash
# Claude Code status line. Reads session JSON on stdin, prints two lines.
input=$(cat)

j() { jq -r "$1 // empty" <<<"$input"; }

R=$'\e[0m' DIM=$'\e[2m' BOLD=$'\e[1m'
GRN=$'\e[32m' YEL=$'\e[33m' RED=$'\e[31m' CYN=$'\e[36m' MAG=$'\e[35m'
SEP="${DIM} │ ${R}"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$cache_dir"

# Color by "how bad": used% for context, left% for rate limits.
color_used() { if (( $1 >= 85 )); then echo "$RED"; elif (( $1 >= 60 )); then echo "$YEL"; else echo "$GRN"; fi; }
color_left() { if (( $1 <= 15 )); then echo "$RED"; elif (( $1 <= 40 )); then echo "$YEL"; else echo "$GRN"; fi; }

model=$(j .model.display_name)
dir=$(j .workspace.current_dir)
repo=$(j .workspace.repo.name)
wt=$(j .workspace.git_worktree)
cost=$(j .cost.total_cost_usd)
ctx=$(j .context_window.used_percentage)

# --- Line 1: model, repo/worktree, branch, PR -------------------------------
line1="${BOLD}${model}${R}"
effort=$(j .effort.level)
[[ -n $effort ]] && line1+=" ${DIM}(${effort})${R}"

if branch=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$dir" rev-parse --short HEAD 2>/dev/null); then
  name=${repo:-$(basename "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)")}
  [[ -n $wt ]] && name+="/${wt}"
  line1+="${SEP}${CYN}${name}${R}"

  dirty=""
  [[ -n $(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | head -1) ]] && dirty="${YEL}*${R}"
  ab=""
  if counts=$(git -C "$dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null); then
    read -r behind ahead <<<"$counts"
    (( ahead > 0 )) && ab+=" ↑${ahead}"
    (( behind > 0 )) && ab+=" ↓${behind}"
  fi
  line1+=" ${MAG}⎇ ${branch}${R}${dirty}${DIM}${ab}${R}"

  # PR number via gh, cached 5 min and refreshed in the background so the
  # status line never waits on the network.
  key=$(printf '%s' "$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)|$branch" | md5sum | cut -c1-16)
  cache="$cache_dir/pr-$key"
  if [[ ! -f $cache ]] || (( $(date +%s) - $(stat -c %Y "$cache") > 300 )); then
    touch "$cache"
    ( cd "$dir" && timeout 10 gh pr view --json number,state -q 'select(.state=="OPEN") | .number' >"$cache.tmp" 2>/dev/null
      mv -f "$cache.tmp" "$cache" ) </dev/null >/dev/null 2>&1 &
    disown
  fi
  pr=$(<"$cache")
fi

# PRs this session or its subagents opened from any worktree, recorded by
# hooks/track-session-prs.sh. Closed/merged ones are listed in a sidecar file
# by a background check, so the hook's appends never race a rewrite.
sid=$(j .session_id)
sprs="$cache_dir/session-$sid"
if [[ -n $sid && -s $sprs ]]; then
  if [[ ! -f $sprs.checked ]] || (( $(date +%s) - $(stat -c %Y "$sprs.checked") > 300 )); then
    touch "$sprs.checked"
    ( sort -u "$sprs" | grep -vxFf <(cat "$sprs.closed" 2>/dev/null) | while read -r url; do
        state=$(timeout 10 gh pr view "$url" --json state -q .state 2>/dev/null)
        [[ -n $state && $state != OPEN ]] && echo "$url" >>"$sprs.closed"
      done ) </dev/null >/dev/null 2>&1 &
    disown
  fi
  while read -r n; do
    [[ " $pr " == *" $n "* ]] || pr+="${pr:+ }$n"
  done < <(grep -vxFf <(cat "$sprs.closed" 2>/dev/null) "$sprs" | sed 's|.*/||' | awk '!seen[$0]++')
fi
[[ -n $pr ]] && line1+="${SEP}${GRN}PR #${pr// / #}${R}"

# --- Context and cost join line 1; line 2 is per-account rate limits ---
pct=${ctx%%.*}; pct=${pct:-0}
filled=$(( pct / 10 )); (( filled > 10 )) && filled=10
bar=""; for i in {1..10}; do (( i <= filled )) && bar+="▓" || bar+="░"; done
line1+="${SEP}ctx $(color_used "$pct")${bar} ${pct}%${R}"
# Tokens in context: input + cache read/write, the same basis as used_percentage.
ktok() { (( $1 >= 1000000 )) && echo "$(( $1 / 1000000 ))M" || echo "$(( $1 / 1000 ))k"; }
tokens=$(j .context_window.total_input_tokens); size=$(j .context_window.context_window_size)
[[ -n $tokens && -n $size ]] && line1+=" ${DIM}$(ktok "$tokens")/$(ktok "$size")${R}"
# Time since Claude last answered, from the transcript. A green ● means the
# prompt cache is still warm, a dim ○ that it went cold; Claude Code re-runs
# this script at prompt_cache.expires_at, so the dot flips on time.
now=$(date +%s)
transcript=$(j .transcript_path)
last=$([[ -f $transcript ]] && tac "$transcript" | jq -Rrn 'first(inputs | fromjson? | select(.type == "assistant") | .timestamp)')
if [[ -n $last ]]; then
  idle=$(( now - $(date -d "$last" +%s) ))
  if (( idle < 3600 )); then age="$(( idle / 60 ))m"; else age="$(( idle / 3600 ))h"; fi
  expires=$(j .prompt_cache.expires_at)
  if [[ -n $expires ]] && (( expires > now )); then line1+=" ${GRN}●${R}${DIM}${age}${R}"; else line1+=" ${DIM}○${age}${R}"; fi
fi
[[ -n $cost ]] && line1+="${SEP}$(printf '$%.2f' "$cost")"
line2=""

# Rate limits per Claude account in sub2api. Claude Code's own rate_limits
# field only reflects whichever account served the last request. The admin
# API's passive usage reads what sub2api already recorded, so no upstream
# call; refreshed in the background every 60s like the PR lookup.
# Cache lines: <account id> <account> <window> <used%> <reset epoch>
# pool.hist keeps the same lines, each prefixed by its observation epoch, for
# 25h; pool_wall turns it into the pool-level burn rate.
# The session cache maps a Claude Code session_id to the account that served
# its newest request, read from sub2api's usage log. That tracks failover on
# the next request, but it is not sub2api's sticky binding itself.
pool_key="$HOME/.config/claude/gateway-admin-key"
pool_cache="$cache_dir/pool"
pool_hist="$cache_dir/pool.hist"
pool_wall_cache="$cache_dir/pool.wall"
sess_cache="$cache_dir/sessions"
admin=https://gateway.ai.faviann.com/api/v1/admin
hdr() { printf 'x-api-key: %s\n' "$(tr -d '[:space:]' <"$pool_key")"; }
pool_refresh() {
  local id name w u r
  curl -sf -m 10 -H @<(hdr) "$admin/accounts?page_size=100" |
    jq -r '.data.items | sort_by(.id)[] | select(.platform == "anthropic" and .status == "active")
           | "\(.id) \(.name | sub("^Claude - "; "") | gsub(" "; "_"))"' |
  while read -r id name; do
    curl -sf -m 10 -H @<(hdr) "$admin/accounts/$id/usage?source=passive" |
      jq -r --arg id "$id" --arg n "$name" '.data as $d | ("five_hour", "seven_day") | "\($id) \($n) \(.) \($d[.].utilization // 0) \($d[.].resets_at // "")"'
  done | while read -r id name w u r; do echo "$id $name $w $u $([[ -n $r ]] && date -d "$r" +%s || echo 0)"; done
}
# History is sampled every 5 minutes: every status line render reads all of it.
pool_record() {
  local obs last
  obs=$(date +%s)
  printf '%s\n' "$1" >"$pool_cache"
  last=$(tail -n 1 "$pool_hist" 2>/dev/null | cut -d' ' -f1)
  (( obs - ${last:-0} >= 300 )) || return 0
  { cat "$pool_hist" 2>/dev/null; printf '%s\n' "$1" | sed "s/^/$obs /"; } |
    awk -v cut=$(( obs - 90000 )) '$1 >= cut' >"$pool_hist.$$"
  mv -f "$pool_hist.$$" "$pool_hist"
}
# Newest entries win; sessions absent from this page keep their last account.
sess_refresh() {
  local new
  new=$(curl -sf -m 10 -H @<(hdr) "$admin/usage?page_size=200" |
    jq -r '.data.items | map(select(.session_id // "" != "")) | group_by(.session_id)[] | max_by(.id) | "\(.session_id) \(.account_id)"')
  [[ -n $new ]] || return
  { printf '%s\n' "$new"; cat "$sess_cache" 2>/dev/null; } | awk '!seen[$1]++' | head -n 2000 >"$sess_cache.tmp"
  mv -f "$sess_cache.tmp" "$sess_cache"
}
if [[ -r $pool_key ]]; then
  if [[ ! -f $pool_cache ]] || (( $(date +%s) - $(stat -c %Y "$pool_cache") > 60 )); then
    touch "$pool_cache"
    ( out=$(pool_refresh); [[ -n $out ]] && pool_record "$out"; sess_refresh ) </dev/null >/dev/null 2>&1 &
    disown
  fi
fi
# When will the pool run dry? Prints "<label> <epoch>" for the earliest wall,
# "clear" once every window has enough history and none hits a wall, else
# nothing. Burn is the recent consumption of all accounts together, in pp/s;
# supply is each account's headroom as chunks that expire at their reset.
pool_wall() {
  awk -v now="$now" '
    BEGIN {
      nw = split("five_hour 18000 3600 28800 5h|seven_day 604800 86400 604800 wk", rows, "|")
      for (i = 1; i <= nw; i++) {
        split(rows[i], f, " ")
        order[i] = f[1]; period[f[1]] = f[2]; look[f[1]] = f[3]; hor[f[1]] = f[4]; label[f[1]] = f[5]
      }
    }
    function add(a, s, e) { n++; amt[n] = a; st[n] = s; ex[n] = e }
    FILENAME == ARGV[1] {
      t = $1; w = $4; u = $5; r = $6; k = $2 SUBSEP w
      if (!(w in first) || t < first[w]) first[w] = t
      if (k in pu) {
        # Reset epochs wobble by seconds inside one window; a drop is a new
        # window opening, never negative consumption.
        d = r - pr[k]; if (d < 0) d = -d
        inc = (d <= 3600) ? (u > pu[k] ? u - pu[k] : 0) : u
        if (t >= now - look[w]) sum[w] += inc
      }
      pu[k] = u; pr[k] = r
      next
    }
    {
      m++; pid[m] = $1; pw[m] = $3; pused[m] = $4; preset[m] = $5
      if ($3 == "seven_day" && $5 > now && $4 >= 99) capped[$1] = 1
    }
    END {
      best = 0; estimated = 0
      for (wi = 1; wi <= nw; wi++) {
        w = order[wi]
        if (!(w in first)) continue
        lo = now - look[w]; span = now - (first[w] > lo ? first[w] : lo)
        if (span < look[w] / 4) continue
        estimated++
        need0 = sum[w] / span * 300
        n = 0
        for (i = 1; i <= m; i++) {
          if (pw[i] != w || (w == "five_hour" && capped[pid[i]])) continue
          s = now
          if (preset[i] > now) { left = 100 - pused[i]; add(left > 0 ? left : 0, now, preset[i]); s = preset[i] }
          for (; s < now + hor[w]; s += period[w]) add(100, s, s + period[w])
        }
        # Earliest expiry first: headroom about to lapse is spent before it.
        for (i = 1; i <= n; i++) idx[i] = i
        for (i = 2; i <= n; i++) {
          v = idx[i]
          for (j = i - 1; j >= 1 && ex[idx[j]] > ex[v]; j--) idx[j + 1] = idx[j]
          idx[j + 1] = v
        }
        for (i = 1; i <= n; i++) rem[i] = amt[i]
        for (t = now; t < now + hor[w]; t += 300) {
          need = need0
          for (q = 1; q <= n && need > 1e-9; q++) {
            c = idx[q]
            if (st[c] <= t && t < ex[c] && rem[c] > 0) {
              take = rem[c] < need ? rem[c] : need
              rem[c] -= take; need -= take
            }
          }
          if (need > 1e-9) { if (!best || t < best) { best = t; bl = label[w] } break }
        }
      }
      if (best) print bl, best
      else if (estimated == nw) print "clear"
    }' "$pool_hist" "$pool_cache"
}
pool_seg=""
if [[ -s $pool_hist && -s $pool_cache ]]; then
  # Recomputed only when history changes; parsing it costs more than a render.
  if [[ ! $pool_wall_cache -nt $pool_hist ]]; then
    pool_wall >"$pool_wall_cache.$$"
    mv -f "$pool_wall_cache.$$" "$pool_wall_cache"
  fi
  read -r wall_label wall_at <"$pool_wall_cache"
  if [[ $wall_label == clear ]]; then
    pool_seg="${GRN}pool clear${R}"
  elif [[ -n $wall_at ]]; then
    wall_color=$GRN
    (( wall_at - now <= 259200 )) && wall_color=$YEL
    (( wall_at - now <= 86400 )) && wall_color=$RED
    pool_seg="${wall_color}pool wall $(TZ=America/Toronto date -d "@$wall_at" '+%a %H:%M') (${wall_label})${R}"
  fi
fi
mine=$([[ -n $sid && -f $sess_cache ]] && awk -v s="$sid" '$1 == s { print $2; exit }' "$sess_cache")

window() { # label, used%, reset epoch, date format
  local left=100
  # A window past its reset is fully available again until fresh data lands.
  (( $3 > now )) && left=$(( 100 - ${2%%.*} ))
  printf '%s %s%d%%%s' "$1" "$(color_left "$left")" "$left" "$R"
  (( $3 > now )) && printf ' %s↻ %s%s' "$DIM" "$(TZ=America/Toronto date -d "@$3" +"$4")" "$R"
}
prev=""
line2=$pool_seg
while read -r id a w u r; do
  if [[ $a != "$prev" ]]; then
    line2+="${SEP}${BOLD}${a}${R}"
    [[ $id == "$mine" ]] && line2+="${YEL}*${R}"
    line2+=" "; prev=$a
  else
    line2+=" ${DIM}·${R} "
  fi
  case $w in
    five_hour) line2+=$(window 5h "$u" "$r" '%H:%M') ;;
    seven_day) line2+=$(window wk "$u" "$r" '%a %H:%M') ;;
  esac
done < <([[ -f $pool_cache ]] && cat "$pool_cache")

printf '%s\n' "$line1"
[[ -n $line2 ]] && printf '%s\n' "${line2#"$SEP"}"
