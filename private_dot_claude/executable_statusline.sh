#!/usr/bin/env bash
# Claude Code status line. Reads session JSON on stdin, prints two lines.
input=$(cat)

j() { jq -r "$1 // empty" <<<"$input"; }

R=$'\e[0m' DIM=$'\e[2m' BOLD=$'\e[1m'
GRN=$'\e[32m' YEL=$'\e[33m' RED=$'\e[31m' CYN=$'\e[36m' MAG=$'\e[35m'
SEP="${DIM} │ ${R}"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$cache_dir"

# Color context use by "how bad".
color_used() { if (( $1 >= 85 )); then echo "$RED"; elif (( $1 >= 60 )); then echo "$YEL"; else echo "$GRN"; fi; }
color_load() { if (( $1 >= 100 )); then echo "$RED"; elif (( $1 >= 80 )); then echo "$YEL"; else echo "$GRN"; fi; }

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

# Rate limits across the Claude accounts in sub2api. Claude Code's own
# rate_limits field only reflects whichever account served the last request.
# The admin API's passive usage reads what sub2api already recorded, so no
# upstream call; refreshed in the background every 60s like the PR lookup.
# Cache lines: <account id> <account> <window> <used%> <reset epoch>
# <recorded epoch> <window cost $>, the cost known for the five-hour window only.
# pool.cost is the gateway's own hourly cost per account for the last 8 days,
# refreshed every 5 minutes: <account id> <hour start epoch> <cost $>
pool_key="$HOME/.config/claude/gateway-admin-key"
pool_cache="$cache_dir/pool"
pool_cost="$cache_dir/pool.cost"
pool_wall_cache="$cache_dir/pool.wall"
admin=https://gateway.ai.faviann.com/api/v1/admin
hdr() { printf 'x-api-key: %s\n' "$(tr -d '[:space:]' <"$pool_key")"; }
epoch() { if [[ $1 == - ]]; then echo 0; else date -d "$1" +%s; fi; }
pool_usage() {
  local json rows w u r t c
  json=$(curl -sf -m 10 -H @<(hdr) "$admin/accounts/$1/usage?source=passive") || return
  rows=$(jq -r '.data as $d | ("five_hour", "seven_day")
    | "\(.) \($d[.].utilization // 0) \($d[.].resets_at // "-") \($d.updated_at // "-") \($d[.].window_stats.cost // 0)"' <<<"$json") || return
  while read -r w u r t c; do echo "$1 $2 $w $u $(epoch "$r") $(epoch "$t") $c"; done <<<"$rows"
}
# The gateway buckets by Toronto wall-clock hour whatever timezone is asked
# for, so each bucket is converted in that zone to stay right across DST.
pool_costs() {
  local json rows hours
  json=$(curl -sf -m 10 -H @<(hdr) "$admin/dashboard/trend?start_date=$(TZ=America/Toronto date -d '8 days ago' +%F)&end_date=$(TZ=America/Toronto date +%F)&granularity=hour&timezone=America/Toronto&account_id=$1") || return
  rows=$(jq -r '.data.trend[] | "\(.date)\t\(.actual_cost)"' <<<"$json") || return
  [[ -n $rows ]] || return 0
  hours=$(cut -f1 <<<"$rows" | TZ=America/Toronto date -f - +%s) || return
  paste -d' ' <(printf '%s\n' "$hours") <(cut -f2 <<<"$rows") | sed "s/^/$1 /"
}
# Runs $1 for every active Claude account, 8 at a time, each into its own file;
# replaces $2 only when every account answered.
pool_fetch() {
  local dir="$2.$$.d" lines line id name files=() n=0
  mapfile -t lines < <(curl -sf -m 10 -H @<(hdr) "$admin/accounts?page_size=100" |
    jq -r '.data.items | sort_by(.id)[] | select(.platform == "anthropic" and .status == "active")
           | "\(.id) \(.name | sub("^Claude - "; "") | gsub(" "; "_"))"')
  (( ${#lines[@]} )) || return
  mkdir -p "$dir"
  for line in "${lines[@]}"; do
    read -r id name <<<"$line"
    files+=("$dir/$id")
    (( n++ < 8 )) || wait -n
    { "$1" "$id" "$name" >"$dir/$id.part" && mv "$dir/$id.part" "$dir/$id"; } &
  done
  wait
  if cat "${files[@]}" >"$2.$$" && [[ -s $2.$$ ]]; then mv -f "$2.$$" "$2"; fi
  rm -rf "$dir" "$2.$$"
}
stale() { [[ ! -f $1 ]] || (( now - $(stat -c %Y "$1") > $2 )); }
if [[ -r $pool_key ]]; then
  if stale "$pool_cache" 60; then
    touch "$pool_cache"
    ( pool_fetch pool_usage "$pool_cache" ) </dev/null >/dev/null 2>&1 &
    disown
  fi
  if stale "$pool_cost" 300; then
    touch "$pool_cost"
    ( pool_fetch pool_costs "$pool_cost" ) </dev/null >/dev/null 2>&1 &
    disown
  fi
fi
# When will the pool run dry? Prints one "<label> <wall epoch|clear|->" line
# per window, "-" until there is enough history and use to price it. Burn is
# the recent cost of all accounts together, turned into points of the limit
# by its price; supply is each account's headroom as chunks that expire at
# their reset.
# A limit's price is dollars per point of use across the pool, as the accounts
# share one plan: the weekly one from what each account spent since its
# window opened, the five-hour one from sub2api's own window cost.
# Then "used <weekly span> <weekly %> <last 5h %> <peak 5h %>": the pace of the
# last week (or as much as is recorded) as a share of the pool's weekly
# capacity, and the last and busiest five hours as a share of its five-hour
# capacity, "-" for any not yet measurable.
# Then "cap <label> <seconds> <pct>" per horizon: what the pool could deliver
# within it, spending flat out, against the same accounts with every counter
# at zero; or "cap -" until both limits are priced, which gives k, the
# five-hour budgets in a weekly one.
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
    function min(a, b) { return a < b ? a : b }
    function max(a, b) { return a > b ? a : b }
    # Weekly pp one account delivers by end: its five-hour windows back to
    # back, those opening before the weekly reset capped by weekly headroom.
    function deliver(u5, r5, uw, rw, end, k,    s, pre, post, tot) {
      if (rw <= now) { uw = 0; rw = now + period["seven_day"] }
      pre = post = 0; s = now
      if (r5 > now) { pre = 100 - u5; s = r5 }
      for (; s < end; s += period["five_hour"]) if (s < rw) pre += 100; else post += 100
      tot = min(pre / k, 100 - uw); if (tot < 0) tot = 0
      if (rw < end) tot += min(post / k, 100)
      return tot
    }
    # The cost of bucket i between a and e, prorated; the current hour runs to now.
    function part(i, a, e,    len) {
      len = min(bt[i] + 3600, now) - bt[i]
      return len > 0 ? bc[i] * max(min(bt[i] + 3600, min(now, e)) - max(bt[i], a), 0) / len : 0
    }
    function spent(a, e,    i, s) { for (i = 1; i <= nb; i++) s += part(i, a, e); return s }
    FILENAME == ARGV[1] {
      nb++; bid[nb] = $1; bt[nb] = $2; bc[nb] = $3
      if (!first || $2 < first) first = $2
      next
    }
    {
      m++; pid[m] = $1; pw[m] = $3; pused[m] = $4; preset[m] = $5
      if ($3 == "seven_day" && $5 > now && $4 >= 99) capped[$1] = 1
      if (!($1 in acct)) na++
      nrow[$3]++
      acct[$1] = 1; cu[$1, $3] = $4; cr[$1, $3] = $5
      # Only windows still open when sub2api recorded them, and weekly ones
      # with enough use to price.
      if ($6 > 0 && $5 > $6)
        if ($3 == "five_hour") { cost5 += $7; used5 += $4 }
        else if ($4 >= 5) { wopen[$1] = $5 - period["seven_day"]; seen[$1] = $6; usedw += $4 }
    }
    END {
      if (used5 >= 5 && cost5 > 0) price["five_hour"] = cost5 / used5
      for (i = 1; i <= nb; i++) if (bid[i] in wopen) costw += part(i, wopen[bid[i]], seen[bid[i]])
      if (usedw > 0 && costw > 0) price["seven_day"] = costw / usedw
      for (wi = 1; wi <= nw; wi++) {
        w = order[wi]
        n = 0
        for (i = 1; i <= m; i++) {
          if (pw[i] != w || (w == "five_hour" && capped[pid[i]])) continue
          s = now
          if (preset[i] > now) { left = 100 - pused[i]; add(left > 0 ? left : 0, now, preset[i]); s = preset[i] }
          for (; s < now + hor[w]; s += period[w]) add(100, s, s + period[w])
        }
        # An empty pool burns nothing, so its burn would read as clear.
        avail = back = 0
        for (i = 1; i <= n; i++)
          if (st[i] <= now) avail += amt[i]
          else if (amt[i] > 0 && (!back || st[i] < back)) back = st[i]
        if (nrow[w] && avail < 1) { print label[w], "dry", (back ? back : "-"); continue }
        # Test membership first: reading price[w] would create it.
        if (!(w in price)) { print label[w], "-"; continue }
        # Whole hours back to the lookback, so the current partial one is
        # weighed by the time it has run.
        lo = max(int((now - look[w]) / 3600) * 3600, first); span = now - lo
        if (span < look[w] / 4) { print label[w], "-"; continue }
        need0 = spent(lo, now) / price[w] / span * 300
        # Earliest expiry first: headroom about to lapse is spent before it.
        for (i = 1; i <= n; i++) idx[i] = i
        for (i = 2; i <= n; i++) {
          v = idx[i]
          for (j = i - 1; j >= 1 && ex[idx[j]] > ex[v]; j--) idx[j + 1] = idx[j]
          idx[j + 1] = v
        }
        for (i = 1; i <= n; i++) rem[i] = amt[i]
        wall = "clear"
        for (t = now; t < now + hor[w]; t += 300) {
          need = need0
          for (q = 1; q <= n && need > 1e-9; q++) {
            c = idx[q]
            if (st[c] <= t && t < ex[c] && rem[c] > 0) {
              take = rem[c] < need ? rem[c] : need
              rem[c] -= take; need -= take
            }
          }
          if (need > 1e-9) { wall = t; break }
        }
        print label[w], wall
      }
      wspan = wpct = f5 = peak = "-"
      cover = now - first
      if ("seven_day" in price && cover >= 21600) {
        wspan = min(cover, 604800)
        wpct = int(spent(now - wspan, now) / price["seven_day"] * 604800 / wspan / na + 0.5)
      }
      if ("five_hour" in price && cover >= 900) {
        last5 = spent(now - 18000, now)
        f5 = int(last5 / price["five_hour"] * (cover < 18000 ? 18000 / cover : 1) / na + 0.5)
      }
      if ("five_hour" in price && cover >= 18000) {
        for (i = 1; i <= nb; i++) hr[bt[i]] += bc[i]
        best = last5
        for (s = int(now / 3600) * 3600 - 14400; s >= max(first, now - 604800); s -= 3600) {
          run = hr[s] + hr[s + 3600] + hr[s + 7200] + hr[s + 10800] + hr[s + 14400]
          if (run > best) best = run
        }
        peak = int(best / price["five_hour"] / na + 0.5)
      }
      print "used", wspan, wpct, f5, peak
      if (!("seven_day" in price && "five_hour" in price)) { print "cap -"; exit }
      k = price["seven_day"] / price["five_hour"]
      nh = split("1h 3600 2h 7200 4h 14400 8h 28800 1d 86400 2d 172800 4d 345600 7d 604800", hz, " ")
      for (h = 1; h < nh; h += 2) {
        got = zero = 0
        for (a in acct) {
          got += deliver(cu[a, "five_hour"], cr[a, "five_hour"], cu[a, "seven_day"], cr[a, "seven_day"], now + hz[h + 1], k)
          zero += deliver(0, 0, 0, 0, now + hz[h + 1], k)
        }
        print "cap", hz[h], hz[h + 1], int(100 * got / zero + 0.5)
      }
    }' "$pool_cost" "$pool_cache"
}
if [[ -s $pool_cost && -s $pool_cache ]]; then
  # Recomputed only when its inputs change; that costs more than a render.
  if [[ ! $pool_wall_cache -nt $pool_cost || ! $pool_wall_cache -nt $pool_cache ]]; then
    pool_wall >"$pool_wall_cache.$$"
    mv -f "$pool_wall_cache.$$" "$pool_wall_cache"
  fi
  first_wall=""
  while read -r label at span pct peak; do
    if [[ $label == used ]]; then
      used=""
      if [[ $span != - ]]; then
        if (( at >= 604800 )); then wspan=7d
        elif (( at >= 86400 )); then wspan="$(( at / 86400 ))d"
        else wspan="$(( at / 3600 ))h"; fi
        used+=" · ${wspan} $(color_load "$span")${span}%${R}"
      fi
      [[ $pct != - ]] && used+=" · 5h $(color_load "$pct")${pct}%${R}"
      [[ $peak != - ]] && used+=" · peak $(color_load "$peak")${peak}%${R}"
      [[ -n $used ]] && line2+="${SEP}used${used# ·}"
      continue
    fi
    if [[ $label == cap ]]; then
      if [[ $at == - ]]; then line3="cap ${DIM}measuring${R}"; continue; fi
      cell=$GRN
      [[ -n $first_wall ]] && (( first_wall <= now + span )) && cell=$RED
      line3="${line3:-cap} ${DIM}${at}${R} ${cell}${pct}%${R}"
      continue
    fi
    case $at in
      dry)
        seg="${RED}dry${R}"
        [[ $span != - ]] && seg="${RED}dry until $(TZ=America/Toronto date -d "@$span" '+%a %H:%M')${R}"
        first_wall=$now ;;
      clear) seg="${GRN}clear${R}" ;;
      -) seg="${DIM}measuring${R}" ;;
      *)
        wall_color=$GRN
        (( at - now <= 259200 )) && wall_color=$YEL
        (( at - now <= 86400 )) && wall_color=$RED
        seg="${wall_color}wall $(TZ=America/Toronto date -d "@$at" '+%a %H:%M')${R}"
        if [[ -z $first_wall ]] || (( at < first_wall )); then first_wall=$at; fi ;;
    esac
    line2+="${SEP}${label} ${seg}"
  done <"$pool_wall_cache"
fi

printf '%s\n' "$line1"
if [[ -n $line2 ]]; then printf '%s\n' "${line2#"$SEP"}"; fi
if [[ -n $line3 ]]; then printf '%s\n' "$line3"; fi
