#!/usr/bin/env bash
# Per-family process count, RSS and physical footprint.
printf "%-10s %6s %10s %14s\n" family procs rss_mb footprint_mb
ps_out=$(ps -axo pid=,rss=,comm=)
for fam in Superset Pane Ghostty cmux; do
  n=0; rss=0; fp=0
  while read -r pid r comm; do
    [ -z "$pid" ] && continue
    n=$((n+1)); rss=$((rss+r))
    line=$(footprint -p "$pid" 2>/dev/null | grep -iE 'phys_footprint:|Footprint:' | head -1) || continue
    [ -z "$line" ] && continue
    val=$(echo "$line" | grep -oE '[0-9.]+ ?[KMG]?B' | head -1)
    num=${val%%[^0-9.]*}
    case "$val" in
      *GB) num=$(echo "$num*1024" | bc -l) ;;
      *MB) ;;
      *KB) num=$(echo "$num/1024" | bc -l) ;;
      *B)  num=$(echo "$num/1048576" | bc -l) ;;
    esac
    fp=$(echo "$fp+$num" | bc -l)
  done < <(echo "$ps_out" | grep -iE "^ *[0-9]+ +[0-9]+ +.*${fam}" | grep -v "measure.sh")
  printf "%-10s %6d %10.1f %14.1f\n" "$fam" "$n" "$(echo "$rss/1024" | bc -l)" "$fp"
done

pid=$(pgrep -x Pane | head -1 || true)
if [ -n "$pid" ]; then
  echo
  top -l 2 -s 1 -stats pid,command,cpu,idlew,power -pid "$pid" | tail -1
fi
