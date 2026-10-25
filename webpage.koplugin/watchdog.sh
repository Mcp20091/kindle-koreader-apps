#!/bin/sh
# While the web server runs: if KOReader stops answering for 30 s (its
# heartbeat file not written), notes where it is stuck in crash.log, once per
# freeze. Ends when the heartbeat file goes (the server stopped) or KOReader
# exits.
# Usage: watchdog.sh <KOReader's pid> <heartbeat file> <request file> <log file>
PID=$1
HB=$2
REQ=$3
OUT=$4
reported=0
while kill -0 "$PID" 2>/dev/null && [ -f "$HB" ]; do
    sleep 10
    [ -f "$HB" ] || break
    now=$(date +%s)
    beat=$(cat "$HB" 2>/dev/null)
    [ -n "$beat" ] || beat=$now
    late=$((now - beat))
    if [ "$late" -gt 30 ]; then
        if [ "$reported" = 0 ]; then
            reported=1
            cpu1=$(cut -d' ' -f14,15 "/proc/$PID/stat" 2>/dev/null)
            sleep 5
            cpu2=$(cut -d' ' -f14,15 "/proc/$PID/stat" 2>/dev/null)
            {
                echo "$(date '+%m/%d/%y-%H:%M:%S') WARN  Web server watchdog: KOReader hasn't answered for ${late} s"
                echo "  last request: $(cat "$REQ" 2>/dev/null)"
                echo "  state: $(cut -d' ' -f3 "/proc/$PID/stat" 2>/dev/null) (R = busy, S/D = waiting)"
                echo "  cpu ticks: $cpu1 then, 5 s later, $cpu2"
                echo "  waiting in: $(cat "/proc/$PID/wchan" 2>/dev/null)"
                echo "  syscall: $(cat "/proc/$PID/syscall" 2>/dev/null)"
                for t in /proc/$PID/task/*; do
                    echo "  thread $(basename "$t"): $(cut -d' ' -f2,3 "$t/stat" 2>/dev/null) $(cat "$t/wchan" 2>/dev/null)"
                done
                echo "  open sockets: $(ls -l "/proc/$PID/fd" 2>/dev/null | grep -c socket)"
                echo "  children: $(cat /proc/$PID/task/$PID/children 2>/dev/null)"
            } >> "$OUT" 2>&1
        fi
    elif [ "$reported" = 1 ]; then
        reported=0
        echo "$(date '+%m/%d/%y-%H:%M:%S') INFO  Web server watchdog: KOReader is answering again" >> "$OUT"
    fi
done
