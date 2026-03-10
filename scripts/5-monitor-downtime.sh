#!/usr/bin/env bash
# =============================================================================
# Script 5 — Monitor Connectivity During ExpressRoute Gateway Upgrade
# =============================================================================
# Usage: bash scripts/5-monitor-downtime.sh
#
# Run this script in a separate terminal BEFORE starting the gateway upgrade
# (scripts/3-upgrade-ergw.azcli). It continuously monitors ICMP reachability
# from an Azure spoke VM to the on-premises GCP VM and logs any packet loss
# with timestamps.
#
# HOW IT WORKS:
#   Phase 1 (SETUP)    — Starts a background ping loop inside the Azure VM.
#                         Results are written to /tmp/er-monitor.log on the VM.
#   Phase 2 (TRACKING) — Polls the Azure VM log every ~30 seconds and shows
#                         live results in your terminal.
#   Phase 3 (REPORT)   — After you stop the script (Ctrl+C), retrieves the
#                         complete log from the VM and prints a downtime summary.
#
# NOTE: az vm run-command invoke has inherent latency (~10-20s per call).
#       This script detects GATEWAY-level downtime (seconds to minutes), not
#       sub-second micro-outages. For sub-second analysis use Azure Network
#       Watcher Connection Monitor (see the README for details).
# =============================================================================

set -euo pipefail

# ─── Parameters ──────────────────────────────────────────────────────────────
rg=lab-er-scale
spoke1Name=az-spk1
monitorVm="${spoke1Name}-vm"
logFile="/tmp/er-monitor.log"
summaryFile="/tmp/er-monitor-summary.txt"

# ─── CONFIGURE THIS ──────────────────────────────────────────────────────────
ONPREM_IP="192.168.0.x"   # Replace with actual GCP VM internal IP
PING_DURATION=1800         # How long to run background ping (seconds). Default: 30 minutes.
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$ONPREM_IP" == "192.168.0.x" ]]; then
    echo "ERROR: ONPREM_IP is not configured. Edit this script and set ONPREM_IP."
    exit 1
fi

# ─── Helper: run a command inside the Azure VM ────────────────────────────────
run_in_vm() {
    az vm run-command invoke \
        --resource-group "$rg" \
        --name "$monitorVm" \
        --command-id RunShellScript \
        --scripts "$1" \
        --query 'value[0].message' \
        --output tsv 2>/dev/null
}

echo ""
echo "============================================================"
echo "  EXPRESSROUTE UPGRADE DOWNTIME MONITOR"
echo "============================================================"
echo "  Source VM:   $monitorVm  (in $rg)"
echo "  Target IP:   $ONPREM_IP  (on-premises GCP VM)"
echo "  Duration:    ${PING_DURATION}s (~$((PING_DURATION/60))m)"
echo "  Start time:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# ─── Phase 1: Start Background Monitoring Inside the VM ──────────────────────
echo "=== Phase 1: Starting background monitor inside $monitorVm ==="

monitorScript="
# Kill any previous monitor
pkill -f 'ping.*$ONPREM_IP' 2>/dev/null || true
rm -f $logFile $summaryFile

# Write header
echo 'MONITOR_START' > $logFile
echo \"Started: \$(date '+%Y-%m-%d %H:%M:%S')\" >> $logFile
echo \"Target: $ONPREM_IP\" >> $logFile
echo '---' >> $logFile

# Background continuous ping loop
(
  sent=0; received=0; lost=0; outage_start=''
  for i in \$(seq 1 $PING_DURATION); do
    ts=\$(date '+%Y-%m-%d %H:%M:%S')
    sent=\$((sent + 1))
    if ping -c1 -W1 $ONPREM_IP > /dev/null 2>&1; then
      received=\$((received + 1))
      if [ -n \"\$outage_start\" ]; then
        duration=\$(( \$(date +%s) - \$(date -d \"\$outage_start\" +%s 2>/dev/null || echo 0) ))
        echo \"\$ts RESTORED (outage duration: ~\${duration}s)\" >> $logFile
        outage_start=''
      else
        echo \"\$ts REACH\" >> $logFile
      fi
    else
      lost=\$((lost + 1))
      if [ -z \"\$outage_start\" ]; then
        outage_start=\"\$ts\"
        echo \"\$ts LOSS *** OUTAGE START ***\" >> $logFile
      else
        echo \"\$ts LOSS\" >> $logFile
      fi
    fi
    sleep 1
  done

  # Write summary
  echo '---' >> $logFile
  echo 'MONITOR_COMPLETE' >> $logFile
  echo \"Finished: \$(date '+%Y-%m-%d %H:%M:%S')\" >> $logFile
  echo \"Packets: sent=\$sent received=\$received lost=\$lost\" >> $logFile
  if [ \$sent -gt 0 ]; then
    pct=\$(( lost * 100 / sent ))
    echo \"Loss rate: \${pct}%\" >> $logFile
  fi
) &
echo \"Monitor PID: \$!\"
"

run_in_vm "$monitorScript"
echo "  Background monitor started inside $monitorVm"
echo ""

# ─── Phase 2: Live Tracking (poll every 30 seconds) ──────────────────────────
echo "=== Phase 2: Live tracking (Ctrl+C to stop and generate report) ==="
echo ""

# Cleanup trap — always generate final report
trap 'echo ""; echo "Stopping live tracking..."; generate_report' EXIT INT TERM

generate_report() {
    echo ""
    echo "============================================================"
    echo "  PHASE 3: FINAL REPORT"
    echo "============================================================"
    echo ""
    echo "  Retrieving complete log from $monitorVm ..."
    echo ""

    finalLog=$(az vm run-command invoke \
        --resource-group "$rg" \
        --name "$monitorVm" \
        --command-id RunShellScript \
        --scripts "cat $logFile 2>/dev/null || echo 'Log file not found'" \
        --query 'value[0].message' \
        --output tsv 2>/dev/null)

    echo "$finalLog"
    echo ""

    # Count outages
    outageCount=$(echo "$finalLog" | grep -c "OUTAGE START" || true)
    lossLines=$(echo "$finalLog" | grep -c "LOSS" || true)

    echo "============================================================"
    echo "  SUMMARY"
    echo "============================================================"
    echo "  Number of outages detected:    $outageCount"
    echo "  Total LOSS events:             $lossLines"
    if [[ "$outageCount" -eq 0 ]]; then
        echo ""
        echo "  ✅ No connectivity interruption detected during the upgrade!"
    else
        echo ""
        echo "  ⚠️  Connectivity interruption(s) detected. Review log above."
    fi
    echo ""
    echo "  Full log is stored on $monitorVm at: $logFile"
    echo "  Retrieve it with:"
    echo "    az vm run-command invoke -g $rg -n $monitorVm --command-id RunShellScript \\"
    echo "      --scripts 'cat $logFile' --query 'value[0].message' -o tsv"
    echo "============================================================"

    # Kill background monitor on the VM when done
    az vm run-command invoke \
        --resource-group "$rg" \
        --name "$monitorVm" \
        --command-id RunShellScript \
        --scripts "pkill -f 'ping.*$ONPREM_IP' 2>/dev/null || true; echo 'Monitor stopped.'" \
        --query 'value[0].message' \
        --output tsv 2>/dev/null || true
}

# Live monitoring loop
iteration=0
while true; do
    iteration=$((iteration + 1))
    echo "[$(date '+%H:%M:%S')] Polling VM log (iteration $iteration) ..."

    # Show last 10 lines of the log
    recentLog=$(az vm run-command invoke \
        --resource-group "$rg" \
        --name "$monitorVm" \
        --command-id RunShellScript \
        --scripts "tail -15 $logFile 2>/dev/null || echo 'Log not ready yet...'" \
        --query 'value[0].message' \
        --output tsv 2>/dev/null)

    echo "$recentLog"
    echo "---"

    # Check if background monitor finished
    if echo "$recentLog" | grep -q "MONITOR_COMPLETE"; then
        echo "Background monitor completed inside VM."
        break
    fi

    sleep 30
done
