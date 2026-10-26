#!/bin/bash
echo "Starting load..."
OK=0
FAIL=0
END=$((SECONDS+60))

while [ $SECONDS -lt $END ]; do
  if curl -sf -o /dev/null --max-time 2 http://localhost:30000/health; then
    OK=$((OK+1))
  else
    FAIL=$((FAIL+1))
    echo "Request failed at $SECONDS s"
  fi
  sleep 0.1
done

echo "================================"
echo "TOTAL: OK=$OK, FAIL=$FAIL"
echo "================================"