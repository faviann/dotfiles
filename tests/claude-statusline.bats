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
}

# A steady climb ending at the current value: one observation every 10
# minutes, appended to pool.hist. Args: id name window u_now reset rate_per_hour hours
climb() {
  awk -v now="$NOW" -v id="$1" -v n="$2" -v w="$3" -v u="$4" -v r="$5" -v rate="$6" -v h="$7" '
    BEGIN { for (t = now - h * 3600; t <= now; t += 600) printf "%d %s %s %s %.4f %d\n", t, id, n, w, u - rate * (now - t) / 3600, r }' \
    >>"$CACHE/pool.hist"
}

# Current state. Args: id name window u reset
pool_line() { printf '%s %s %s %s %s\n' "$@" >>"$CACHE/pool"; }

render() { bash "$REPO_ROOT/private_dot_claude/executable_statusline.sh" <<<'{}'; }
line2() { render | sed -n 2p | sed 's/\x1b\[[0-9;]*m//g'; }
line3() { render | sed -n 3p | sed 's/\x1b\[[0-9;]*m//g'; }

# The wall lands on a 5-minute step of the script's own clock; accept 15 minutes either side.
assert_wall_near() {
  local label="$1" offset="$2" line d
  line=$(line2)
  for d in $(seq -900 60 900); do
    if [[ $line == *"$label wall $(TZ=America/Toronto date -d "@$((NOW + offset + d))" '+%a %H:%M')"* ]]; then
      return
    fi
  done
  fail "expected a ($label) wall near now+${offset}s, got: $line"
}

@test "a steady weekly burn that drains the pool shows the wk wall" {
  # Headroom 55 + 45.9 = 100.9 pp, burn 36 pp/day: dry after about 242160s.
  climb 1 alpha seven_day 45 $((NOW + 259200)) 1 24
  climb 2 beta seven_day 54.1 $((NOW + 259200)) 0.5 24
  pool_line 1 alpha seven_day 45 $((NOW + 259200))
  pool_line 2 beta seven_day 54.1 $((NOW + 259200))
  assert_wall_near wk 242160
}

@test "a pool that is not burning shows clear" {
  climb 1 alpha five_hour 20 $((NOW + 10800)) 0 1
  climb 1 alpha seven_day 45 $((NOW + 259200)) 0 24
  pool_line 1 alpha five_hour 20 $((NOW + 10800))
  pool_line 1 alpha seven_day 45 $((NOW + 259200))
  [[ $(line2) == "5h clear │ wk clear" ]]
}

@test "a limit without enough history shows measuring" {
  climb 1 alpha five_hour 20 $((NOW + 10800)) 0 1
  climb 1 alpha seven_day 45 $((NOW + 259200)) 0 1
  pool_line 1 alpha five_hour 20 $((NOW + 10800))
  pool_line 1 alpha seven_day 45 $((NOW + 259200))
  [[ $(line2) == "5h clear │ wk measuring" ]]
}

@test "usage after a reset inside the lookback counts and a drop is not negative" {
  # 90% before the reset, 61% in the new window: 61 pp burned in 24h against
  # 39 pp of headroom that lapses in a day.
  {
    printf '%d 1 alpha seven_day 90 %d\n' $((NOW - 86400)) $((NOW - 72000))
    printf '%d 1 alpha seven_day 61 %d\n' $((NOW - 3600)) $((NOW + 86400))
    printf '%d 1 alpha seven_day 61 %d\n' "$NOW" $((NOW + 86400))
  } >"$CACHE/pool.hist"
  pool_line 1 alpha seven_day 61 $((NOW + 86400))
  assert_wall_near wk 55240
}

@test "a five-hour burn faster than the five-hour headroom shows the 5h wall" {
  # 41 pp in the last hour against 59 pp of headroom: dry after about 5180s.
  climb 1 alpha five_hour 41 $((NOW + 10800)) 41 1
  pool_line 1 alpha five_hour 41 $((NOW + 10800))
  assert_wall_near 5h 5180
}

@test "history shorter than a quarter of the lookback shows measuring" {
  climb 1 alpha seven_day 45 $((NOW + 259200)) 10 0.1
  climb 1 alpha five_hour 45 $((NOW + 10800)) 10 0.1
  pool_line 1 alpha seven_day 45 $((NOW + 259200))
  pool_line 1 alpha five_hour 45 $((NOW + 10800))
  [[ $(line2) == "5h measuring │ wk measuring" ]]
}

@test "headroom that expires before it can be used does not delay the wall" {
  # 6.1 pp/h. alpha has 5 pp for the first hour, beta 40 pp for two hours,
  # then each has a fresh 100. Only 12.2 pp can be drawn before beta's lapses,
  # so the wall is two hours plus 200 pp of burn, not 245 pp of burn.
  climb 1 alpha seven_day 95 $((NOW + 3600)) 3.05 8
  climb 2 beta seven_day 60 $((NOW + 7200)) 3.05 8
  pool_line 1 alpha seven_day 95 $((NOW + 3600))
  pool_line 2 beta seven_day 60 $((NOW + 7200))
  assert_wall_near wk 125100
}

@test "the wall follows history that changes after it was shown" {
  climb 1 alpha five_hour 20 $((NOW + 10800)) 0 1
  climb 1 alpha seven_day 45 $((NOW + 259200)) 0 24
  pool_line 1 alpha five_hour 20 $((NOW + 10800))
  pool_line 1 alpha seven_day 45 $((NOW + 259200))
  [[ $(line2) == "5h clear │ wk clear" ]]
  : >"$CACHE/pool.hist"
  climb 1 alpha seven_day 45 $((NOW + 259200)) 1 24
  touch -d "@$((NOW + 60))" "$CACHE/pool.hist"
  assert_wall_near wk 198000
}

@test "each limit gets its own answer" {
  climb 1 alpha five_hour 20 $((NOW + 10800)) 0 1
  climb 1 alpha seven_day 45 $((NOW + 259200)) 1 24
  pool_line 1 alpha five_hour 20 $((NOW + 10800))
  pool_line 1 alpha seven_day 45 $((NOW + 259200))
  [[ $(line2) == "5h clear │ wk wall "* ]]
  assert_wall_near wk 198000
}

@test "capacity is compared with the same pool at zero, red from the wall on" {
  # k = 48 five-hour pp / 6 weekly pp = 8. Weekly headroom 10 at 1 pp/h: wall
  # in about 10h. The reset in 2 days restores a full week.
  climb 1 alpha five_hour 48 $((NOW + 10800)) 8 6
  climb 1 alpha seven_day 90 $((NOW + 172800)) 1 6
  pool_line 1 alpha five_hour 50 $((NOW + 3600))
  pool_line 1 alpha seven_day 90 $((NOW + 172800))
  [[ $(line3) == "cap 1h 50% 2h 80% 4h 80% 8h 40% 1d 16% 2d 10% 4d 110% 7d 110%" ]]
  local raw
  raw=$(render | sed -n 3p)
  [[ $raw == *$'8h\e[0m \e[32m40%'* ]]
  [[ $raw == *$'1d\e[0m \e[31m16%'* ]]
}

@test "capacity waits until weekly usage relates the two limits" {
  climb 1 alpha five_hour 20 $((NOW + 10800)) 0 1
  climb 1 alpha seven_day 45 $((NOW + 259200)) 0 24
  pool_line 1 alpha five_hour 20 $((NOW + 10800))
  pool_line 1 alpha seven_day 45 $((NOW + 259200))
  [[ $(line3) == "cap measuring" ]]
}
