#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LAST_NO_CONNECTION_FILE="$BASE_DIR/last_no_connection.log"

has_active_connections() {
  if command -v ss >/dev/null 2>&1; then
    if ss -Htan sport = :22 state established | grep -q .; then
      return 0
    else
      return 1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -an | grep ESTABLISHED | grep -q ":22"; then
      return 0
    else
      return 1
    fi
  else
    echo "Neither ss nor netstat found; cannot check connections" >&2
    return 1
  fi
}

now_ts() { date +%s; }

main() {
  mkdir -p "$(dirname "$LAST_NO_CONNECTION_FILE")"

  if has_active_connections; then
    echo "Active connections on port 22. Resetting idle timer."
    [ -f "$LAST_NO_CONNECTION_FILE" ] && rm -f "$LAST_NO_CONNECTION_FILE"
    exit 0
  fi

  current_time=$(now_ts)
  if [ -f "$LAST_NO_CONNECTION_FILE" ] && [ -s "$LAST_NO_CONNECTION_FILE" ]; then
    last_no_conn=$(cat "$LAST_NO_CONNECTION_FILE")
  else
    last_no_conn=0
  fi

  if [ "$last_no_conn" -eq 0 ]; then
    echo "$current_time" > "$LAST_NO_CONNECTION_FILE"
    echo "No active connections. Starting idle timer at $current_time."
    exit 0
  fi

  diff=$(( current_time - last_no_conn ))
  if [ "$diff" -ge 1800 ]; then
    echo "No active connections for $diff seconds (>= 1800). Initiating shutdown."
    if command -v shutdown >/dev/null 2>&1; then
      shutdown -h now
    else
      /sbin/shutdown -h now 2>/dev/null || /usr/sbin/shutdown -h now
    fi
  else
    remain=$(( 1800 - diff ))
    echo "No active connections. ${diff}s elapsed; ${remain}s until shutdown."
  fi
}

main "$@"