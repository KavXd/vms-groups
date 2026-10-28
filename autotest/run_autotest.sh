#!/bin/bash
# Runs host + guest test copies of the game and prints the results.
cd "$(dirname "$0")/.."
ruby autotest/compile_plugins.rb . || exit 1
taskkill //F //IM Game.exe >/dev/null 2>&1; sleep 1
rm -rf autotest_logs
VMS_AUTOTEST=host timeout 900 ./Game.exe > autotest_host_console.txt 2>&1 &
for i in $(seq 1 60); do grep -q "connected\|ERROR" autotest_logs/host.log 2>/dev/null && break; sleep 1; done
VMS_AUTOTEST=guest timeout 900 ./Game.exe > autotest_guest_console.txt 2>&1 &
wait
echo "===== HOST ====="; grep -E "PASS|FAIL|ERROR|TIMEOUT|    |result|battle" autotest_logs/host.log
echo "===== GUEST ====="; grep -E "PASS|FAIL|ERROR|TIMEOUT|    |battle|throwing" autotest_logs/guest.log
echo "===== SYNC CHECK (battle turns on both games) ====="
diff <(grep -o "SYNC .*" autotest_logs/host.log) <(grep -o "SYNC .*" autotest_logs/guest.log) && echo "IDENTICAL: $(grep -c SYNC autotest_logs/host.log) turn lines match"
