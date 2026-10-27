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
# pool.hist keeps the same lines, each prefixed by its observation epoch, for
# a week; pool_wall turns it into the pool-level burn rate.
pool_key="$HOME/.config/claude/gateway-admin-key"
pool_cache="$cache_dir/pool"
pool_hist="$cache_dir/pool.hist"
pool_wall_cache="$cache_dir/pool.wall"
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
    awk -v cut=$(( obs - 608400 )) '$1 >= cut' >"$pool_hist.$$"
  mv -f "$pool_hist.$$" "$pool_hist"
}
if [[ -r $pool_key ]]; then
  if [[ ! -f $pool_cache ]] || (( $(date +%s) - $(stat -c %Y "$pool_cache") > 60 )); then
    touch "$pool_cache"
    ( out=$(pool_refresh); [[ -n $out ]] && pool_record "$out" ) </dev/null >/dev/null 2>&1 &
    disown
  fi
fi
# When will the pool run dry? Prints one "<label> <wall epoch|clear|->" line
# per window, "-" without enough history. Burn is the recent consumption of all
# accounts together, in pp/s; supply is each account's headroom as chunks that
# expire at their reset.
# Then "used <weekly span> <weekly %> <last 5h %> <peak 5h %>": the pace of the
# last week (or as much as is recorded) as a share of the pool's weekly
# capacity, and the last and busiest five hours as a share of its five-hour
# capacity, "-" for any not yet measurable.
# Then "cap <label> <seconds> <pct>" per horizon: what the pool could deliver
# within it, spending flat out, against the same accounts with every counter
# at zero; or "cap -" until weekly usage gives k, the five-hour budgets in a
# weekly one, which both limits must be measured in to be combined.
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
    FILENAME == ARGV[1] {
      t = $1; w = $4; u = $5; r = $6; k = $2 SUBSEP w
      if (!(w in first) || t < first[w]) first[w] = t
      if (k in pu) {
        # Reset epochs wobble by seconds inside one window; a drop is a new
        # window opening, never negative consumption.
        d = r - pr[k]; if (d < 0) d = -d
        inc = (d <= 3600) ? (u > pu[k] ? u - pu[k] : 0) : u
        if (t >= now - look[w]) sum[w] += inc
        if (t >= now - 86400) ksum[w] += inc
        if (w == "seven_day" && t > now - 604800) week += inc
        if (w == "five_hour") fbin[int((now - t) / 300)] += inc
      }
      pu[k] = u; pr[k] = r
      next
    }
    {
      m++; pid[m] = $1; pw[m] = $3; pused[m] = $4; preset[m] = $5
      if ($3 == "seven_day" && $5 > now && $4 >= 99) capped[$1] = 1
      if (!($1 in acct)) na++
      nrow[$3]++
      acct[$1] = 1; cu[$1, $3] = $4; cr[$1, $3] = $5
    }
    END {
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
        # Test membership first: reading first[w] would create it.
        if (!(w in first)) { print label[w], "-"; continue }
        lo = now - look[w]; span = now - (first[w] > lo ? first[w] : lo)
        if (span < look[w] / 4) { print label[w], "-"; continue }
        need0 = sum[w] / span * 300
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
      if ("seven_day" in first && now - first["seven_day"] >= 21600) {
        wspan = min(now - first["seven_day"], 604800)
        wpct = int(week * 604800 / wspan / na + 0.5)
      }
      fspan = ("five_hour" in first) ? now - first["five_hour"] : 0
      if (fspan >= 900) {
        for (b = last5 = 0; b < 60; b++) last5 += fbin[b]
        f5 = int(last5 * (fspan < 18000 ? 18000 / fspan : 1) / na + 0.5)
      }
      if (fspan >= 18000) {
        best = run = last5
        for (b = 60; b <= int(fspan / 300); b++) {
          run += fbin[b] - fbin[b - 60]
          if (run > best) best = run
        }
        peak = int(best / na + 0.5)
      }
      print "used", wspan, wpct, f5, peak
      if (ksum["seven_day"] < 2 || ksum["five_hour"] <= 0) { print "cap -"; exit }
      k = ksum["five_hour"] / ksum["seven_day"]
      nh = split("1h 3600 2h 7200 4h 14400 8h 28800 1d 86400 2d 172800 4d 345600 7d 604800", hz, " ")
      for (h = 1; h < nh; h += 2) {
        got = zero = 0
        for (a in acct) {
          got += deliver(cu[a, "five_hour"], cr[a, "five_hour"], cu[a, "seven_day"], cr[a, "seven_day"], now + hz[h + 1], k)
          zero += deliver(0, 0, 0, 0, now + hz[h + 1], k)
        }
        print "cap", hz[h], hz[h + 1], int(100 * got / zero + 0.5)
      }
    }' "$pool_hist" "$pool_cache"
}
if [[ -s $pool_hist && -s $pool_cache ]]; then
  # Recomputed only when history changes; parsing it costs more than a render.
  if [[ ! $pool_wall_cache -nt $pool_hist ]]; then
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
