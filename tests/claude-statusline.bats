#!/usr/bin/env bats
set -euo pipefail

# shellcheck source=tests/test_helper.bash
source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  CACHE="$XDG_CACHE_HOME/claude-statusline"
  mkdir -p "$HOME" "$CACHE"
  cd "$BATS_TEST_TMPDIR"
  NOW=$(date +%s)
  HOUR=$(( NOW / 3600 * 3600 ))
}

# Current state, recorded by sub2api just now. Args: id name window used% reset [window cost]
pool_line() { printf '%s %s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$NOW" "${6:-0}" >>"$CACHE/pool"; }

# A steady spend from start to end (default now), split into the gateway's
# hourly buckets. Args: id dollars_per_hour start [end]
spend() {
  awk -v id="$1" -v rate="$2" -v a="$3" -v e="${4:-$NOW}" 'BEGIN {
    for (b = int(a / 3600) * 3600; b < e; b += 3600) {
      lo = b > a ? b : a; hi = b + 3600 < e ? b + 3600 : e
      printf "%s %d %.6f\n", id, b, rate * (hi - lo) / 3600
    }
  }' >>"$CACHE/pool.cost"
}

# The cost of a weekly window at $8 a point: rate points an hour over the
# last hours, the rest of used% in the window's second hour.
# Args: id used% reset rate hours
week_cost() {
  local start=$(( $3 - 604800 )) steady rest
  read -r steady rest < <(awk -v u="$2" -v r="$4" -v h="$5" 'BEGIN { print r * 8, (u - r * h) * 8 }')
  (( $5 == 0 )) || spend "$1" "$steady" $(( NOW - $5 * 3600 ))
  spend "$1" "$rest" $(( start + 3600 )) $(( start + 7200 ))
}

# A weekly window and its cost. Args: id name used% reset rate hours
week() {
  pool_line "$1" "$2" seven_day "$3" "$4"
  week_cost "$1" "$3" "$4" "$5" "$6"
}

render() { bash "$REPO_ROOT/private_dot_claude/executable_statusline.sh" <<<'{}'; }
line2() { render | sed -n 2p | sed 's/\x1b\[[0-9;]*m//g'; }
line3() { render | sed -n 3p | sed 's/\x1b\[[0-9;]*m//g'; }

# The wall lands on a 5-minute step of the script's own clock; accept 15
# minutes either side, or the tolerance given in seconds.
assert_wall_near() {
  local label="$1" offset="$2" tol="${3:-900}" line d
  line=$(line2)
  for d in $(seq -"$tol" 60 "$tol"); do
    if [[ $line == *"$label wall $(TZ=America/Toronto date -d "@$((NOW + offset + d))" '+%a %H:%M')"* ]]; then
      return
    fi
  done
  fail "expected a ($label) wall near now+${offset}s, got: $line"
}

@test "a steady weekly burn that drains the pool shows the wk wall" {
  # Headroom 55 + 45.9 = 100.9 points, burn 36 points a day: dry after about 242160s.
  week 1 alpha 45 $((NOW + 259200)) 1 26
  week 2 beta 54.1 $((NOW + 259200)) 0.5 26
  assert_wall_near wk 242160
}

@test "a pool that is not burning shows clear" {
  pool_line 1 alpha five_hour 20 $((NOW + 10800)) 20
  week 1 alpha 45 $((NOW + 259200)) 0 0
  [[ $(line2) == "5h clear │ wk clear │ used "* ]]
}

@test "a limit without enough history shows measuring" {
  # The weekly window opened 30 minutes ago and is calibrated, but an hour or
  # two of cost history is too little to judge a day's burn.
  pool_line 1 alpha five_hour 20 $((NOW + 10800)) 2000
  pool_line 1 alpha seven_day 5 $((NOW + 603000))
  spend 1 80 $((NOW - 1800))
  [[ $(line2) == "5h clear │ wk measuring │ used 5h "* ]]
}

@test "spending across a weekly reset all burns but only the new window sets the rate" {
  # $24.4 an hour for 26 hours; the window opened 20 hours ago with 61 points
  # for $488, so $8 a point and 3.05 points an hour against 39 of headroom.
  pool_line 1 alpha seven_day 61 $((NOW + 532800))
  spend 1 24.4 $((NOW - 93600))
  assert_wall_near wk 46033
}

@test "a five-hour burn faster than the five-hour headroom shows the 5h wall" {
  # $41 an hour at $1 a point against 59 points of headroom: dry after about 5180s.
  pool_line 1 alpha five_hour 41 $((NOW + 10800)) 41
  spend 1 41 $((NOW - 10800))
  assert_wall_near 5h 5180
}

@test "a limit with too little use to price a point shows measuring" {
  pool_line 1 alpha five_hour 4 $((NOW + 10800)) 4
  week 1 alpha 4 $((NOW + 259200)) 0.1 26
  [[ $(line2) == "5h measuring │ wk measuring" ]]
}

@test "the weekly rate is total cost over total use in each current window" {
  # $2520 for alpha's 90 points and $480 for beta's 60 is $20 a point, so
  # alpha's $40 an hour is 2 points an hour against 146 points of headroom.
  local reset=$((NOW + 345600)) start=$((NOW - 259200))
  pool_line 1 alpha seven_day 90 $reset
  pool_line 2 beta seven_day 60 $reset
  pool_line 3 gamma seven_day 4 $reset
  spend 1 40 $((NOW - 93600))
  spend 1 1480 $((start + 3600)) $((start + 7200))
  spend 2 480 $((start + 3600)) $((start + 7200))
  # Not this window's use, and too little use to price.
  spend 1 3000 $((start - 28800)) $((start - 25200))
  spend 3 2000 $((start + 3600)) $((start + 7200))
  assert_wall_near wk 262800
}

@test "the five-hour rate is total window cost over total use in current windows" {
  # $3.50 for 14 points is $0.25 a point, so $40 an hour is 160 points an hour
  # against 286 points of headroom, the first of it lapsing in two hours.
  # gamma's window had already ended when sub2api last recorded it.
  pool_line 1 alpha five_hour 10 $((NOW + 10800)) 2.5
  pool_line 2 beta five_hour 4 $((NOW + 7200)) 1
  pool_line 3 gamma five_hour 20 $((NOW - 600)) 20
  spend 1 40 $((NOW - 10800))
  assert_wall_near 5h 6300
}

@test "headroom that expires before it can be used does not delay the wall" {
  # 5 points an hour. alpha has 5 for the first hour, beta 40 for two hours,
  # then each has a fresh 100. Only 10 can be drawn before beta's lapses, so
  # the wall is two hours plus 200 points of burn, not 245 points of burn.
  week 1 alpha 95 $((NOW + 3600)) 3 26
  week 2 beta 60 $((NOW + 7200)) 2 26
  assert_wall_near wk 151200
}

@test "the wall follows cost and pool data that change after it was shown" {
  pool_line 1 alpha five_hour 20 $((NOW + 10800)) 20
  week 1 alpha 45 $((NOW + 259200)) 0 0
  [[ $(line2) == "5h clear │ wk clear │ "* ]]
  : >"$CACHE/pool.cost"
  week_cost 1 45 $((NOW + 259200)) 1 26
  touch -d "@$((NOW + 60))" "$CACHE/pool.cost"
  assert_wall_near wk 198000
  # The same $360 now buys 75 points: 1.67 points an hour against 25 of headroom.
  touch -d "@$NOW" "$CACHE/pool.cost"
  sed -i 's/ seven_day 45 / seven_day 75 /' "$CACHE/pool"
  touch -d "@$((NOW + 120))" "$CACHE/pool"
  assert_wall_near wk 54000
}

@test "each limit gets its own answer" {
  pool_line 1 alpha five_hour 20 $((NOW + 10800)) 20
  week 1 alpha 45 $((NOW + 259200)) 1 26
  [[ $(line2) == "5h clear │ wk wall "* ]]
  assert_wall_near wk 198000
}

@test "capacity is compared with the same pool at zero, red from the wall on" {
  # k = $8 a weekly point / $1 a five-hour point = 8. Weekly headroom 10 at
  # 1 point an hour: wall in about 10h. The reset in 2 days restores a full week.
  pool_line 1 alpha five_hour 50 $((NOW + 4200)) 50
  week 1 alpha 90 $((NOW + 172800)) 1 26
  [[ $(line3) == "cap 1h 50% 2h 80% 4h 80% 8h 40% 1d 16% 2d 10% 4d 110% 7d 110%" ]]
  local raw
  raw=$(render | sed -n 3p)
  [[ $raw == *$'8h\e[0m \e[32m40%'* ]]
  [[ $raw == *$'1d\e[0m \e[31m16%'* ]]
}

@test "capacity waits until both limits are priced" {
  pool_line 1 alpha five_hour 20 $((NOW + 10800)) 20
  week 1 alpha 4 $((NOW + 259200)) 0 0
  [[ $(line3) == "cap measuring" ]]
}

@test "last week's use is shown against the pool's weekly capacity" {
  # $672 + $336 over 7 days at $8 a point is 126 points of 2 accounts' 200.
  spend 1 4 $((NOW - 691200))
  spend 2 2 $((NOW - 691200))
  pool_line 1 alpha seven_day 48 $((NOW + 259200))
  pool_line 2 beta seven_day 24 $((NOW + 259200))
  [[ $(line2) == "5h measuring │ wk "*"│ used 7d 63%" ]]
}

@test "until a week is recorded, use is projected from the days measured" {
  # $4 an hour at $8 a point is 84 points a week on 1 account.
  spend 1 4 $((HOUR - 172800))
  pool_line 1 alpha seven_day 18 $((NOW + 475200))
  [[ $(line2) == *"│ used 2d 84%" ]]
  [[ $(render | sed -n 2p) == *$'\e[33m84%'* ]]
}

@test "the busiest five hours is shown beside the last five" {
  # alpha spends $80 in 5 hours a day ago, then $30 in the last 5 hours; beta
  # is idle. At $1 a point the pool's five-hour capacity is 200 points.
  pool_line 1 alpha five_hour 30 $((NOW + 10800)) 30
  pool_line 2 beta five_hour 0 0
  spend 1 16 $((HOUR - 108000)) $((HOUR - 90000))
  spend 1 6 $((HOUR - 21600))
  [[ $(line2) == *"│ used 5h 15% · peak 40%" ]]
}

@test "a refresh records each account's usage and hourly cost from the gateway" {
  mkdir -p "$HOME/.config/claude" "$BATS_TEST_TMPDIR/bin"
  echo key >"$HOME/.config/claude/gateway-admin-key"
  { printf '#!%s\n' "$BASH"; cat <<'CURL'; } >"$BATS_TEST_TMPDIR/bin/curl"
for url; do :; done
echo "$url" >>"${0%/bin/curl}/urls"
case $url in
  */admin/usage*) exit 22 ;;
  */accounts\?*) echo '{"data":{"items":[
    {"id":2,"name":"Claude - beta two","platform":"anthropic","status":"active"},
    {"id":1,"name":"alpha","platform":"anthropic","status":"active"},
    {"id":3,"name":"gamma","platform":"anthropic","status":"disabled"},
    {"id":4,"name":"delta","platform":"openai","status":"active"}]}}' ;;
  */accounts/1/usage\?source=passive) echo '{"data":{"updated_at":"2026-11-01T06:30:00Z",
    "five_hour":{"utilization":7.000000000000001,"resets_at":"2026-11-01T03:00:00-05:00","window_stats":{"cost":1.39}},
    "seven_day":{"utilization":63,"resets_at":"2026-11-05T21:00:00-05:00"}}}' ;;
  */accounts/2/usage\?source=passive) echo '{"data":{"updated_at":null,
    "five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":0,"resets_at":null}}}' ;;
  */dashboard/trend\?*account_id=1) echo '{"data":{"trend":[
    {"date":"2026-11-01 00:00","requests":3,"actual_cost":1.5},
    {"date":"2026-11-01 03:00","requests":5,"actual_cost":2.25}]}}' ;;
  */dashboard/trend\?*account_id=2) echo '{"data":{"trend":[{"date":"2026-07-01 12:00","requests":1,"actual_cost":0.75}]}}' ;;
  *) exit 22 ;;
esac
CURL
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" render >/dev/null
  for _ in {1..100}; do
    [[ -s $CACHE/pool.cost && -s $CACHE/pool ]] && break
    sleep 0.1
  done
  # Toronto wall-clock hours: midnight is EDT, 03:00 after the fall-back is EST.
  [[ $(sort "$CACHE/pool.cost") == "1 $(date -u -d '2026-11-01 04:00' +%s) 1.5
1 $(date -u -d '2026-11-01 08:00' +%s) 2.25
2 $(date -u -d '2026-07-01 16:00' +%s) 0.75" ]]
  [[ $(<"$CACHE/pool") == "1 alpha five_hour 7.000000000000001 $(date -u -d '2026-11-01 08:00' +%s) $(date -u -d '2026-11-01 06:30' +%s) 1.39
1 alpha seven_day 63 $(date -u -d '2026-11-06 02:00' +%s) $(date -u -d '2026-11-01 06:30' +%s) 0
2 beta_two five_hour 0 0 0 0
2 beta_two seven_day 0 0 0 0" ]]
  grep -q "/dashboard/trend?start_date=$(TZ=America/Toronto date -d '8 days ago' +%F)&end_date=$(TZ=America/Toronto date +%F)&granularity=hour&timezone=America/Toronto&account_id=1$" "$BATS_TEST_TMPDIR/urls"
  if grep -q '/admin/usage' "$BATS_TEST_TMPDIR/urls"; then fail "read the usage list, which embeds API keys"; fi
}

@test "an empty pool shows dry until capacity returns, not clear" {
  # Nothing left to spend means nothing is measured as burned.
  pool_line 1 alpha five_hour 0 0
  week 1 alpha 100 $((NOW + 72000)) 0 0
  pool_line 2 beta five_hour 0 0
  week 2 beta 100 $((NOW + 108000)) 0 0
  [[ $(line2) == "5h dry │ wk dry until $(TZ=America/Toronto date -d "@$((NOW + 72000))" '+%a %H:%M') │ "* ]]
}

@test "five-hour use is shown against the level a week can sustain" {
  # k = $8 a weekly point / $1 a five-hour point = 8, so a week sustains
  # 8 / 33.6 = 24% of the pool's five-hour capacity. The last 5 hours spent
  # $40, which is 40 points of alpha's 100.
  pool_line 1 alpha five_hour 50 $((NOW + 4200)) 50
  week 1 alpha 90 $((NOW + 172800)) 1 26
  [[ $(line2) == *"· 5h 40%/24% ·"* ]]
  [[ $(render | sed -n 2p) == *$'5h \e[33m40%'* ]]
}

# A week with two quiet days in it. alpha's weekly window opened a day ago;
# the last day's $192 at 24 points prices a point at $8, so a busy hour burns
# one point against 76 points of headroom. Args: dollars_per_hour a week before
# the last day
replay_week() {
  pool_line 1 alpha seven_day 24 $((NOW + 518400))
  spend 1 "$1" $((NOW - 691200)) $((NOW - 604800))
  spend 1 8 $((NOW - 432000))
}

@test "the weekly wall replays last week hour by hour" {
  # The next two days repeat last week's quiet ones, so the 76 points last
  # 48 + 76 hours, not the 76 hours the last day's pace alone would give.
  # Hourly buckets blur the quiet days' edges by up to an hour.
  replay_week 8
  assert_wall_near wk 446400 7200
}

@test "the replay is scaled by how the last day compares with a week before" {
  # $192 against $144 a week earlier: busy hours now burn 4/3 of a point,
  # so the 76 points last 48 + 57 hours.
  replay_week 6
  assert_wall_near wk 378000 7200
}

@test "a replay without the week before's day keeps last week's scale" {
  pool_line 1 alpha seven_day 24 $((NOW + 518400))
  spend 1 8 $((NOW - 432000))
  spend 1 0.000001 $((NOW - 604800)) $((NOW - 601200))
  assert_wall_near wk 446400 7200
}

@test "a week unlike the last falls back to the last day's pace" {
  # $192 against $48 a week earlier: usage quadrupled, so last week's shape
  # is no guide and the 76 points last 76 hours at the last day's pace.
  replay_week 2
  assert_wall_near wk 273600
}
