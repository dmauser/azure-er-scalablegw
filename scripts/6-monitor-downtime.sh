#!/usr/bin/env bash
# =============================================================================
# Script 6 — Monitor Connectivity During ExpressRoute Gateway Upgrade/Migration
# =============================================================================
# Usage: bash scripts/6-monitor-downtime.sh
#
# This script is COMMON to both upgrade scenarios.
# Run it in a separate terminal BEFORE starting the upgrade or migration:
#   Scenario 1: Before running bash scripts/3-scenario1-upgrade-ergw.sh
#   Scenario 2: Before Phase 2 (Execute) of bash scripts/4-scenario2-migrate-ergw.sh
#
# It continuously monitors ICMP reachability from an Azure spoke VM to the
# on-premises GCP VM, logging packet loss and RTT statistics from each batch.
#
# HOW IT WORKS:
#   SCENARIO SELECT    — Choose Scenario 1 (in-place upgrade) or Scenario 2
#                         (3-phase gateway migration). Gateway phase labels and
#                         expected-downtime annotations adjust accordingly.
#
#   Phase 1 (ICMP)     — Starts a background batch-ping loop inside the Azure
#                         VM (10 ICMP packets per interval, 200 ms apart).
#                         Captures loss % and RTT min/avg/max per batch.
#                         Results are written to /tmp/er-monitor.log on the VM.
#
#   Phase 2 (TRACKING) — Each polling iteration (~30 s cycle) runs two checks:
#                         a) LOCAL: Queries the ExpressRoute Gateway via
#                            'az network vnet-gateway show'. Detects
#                            provisioningState transitions (Succeeded↔Updating),
#                            SKU changes, and migrationPhase (Scenario 2).
#                            Transitions are printed as banners and appended to
#                            a local gateway event log.
#                         b) REMOTE: Tails the VM ICMP log (last 5 lines).
#
#   Phase 3 (REPORT)   — After Ctrl+C or timer expiry, prints:
#                         • Gateway Event Timeline with annotated phase labels
#                         • Full ICMP log retrieved from the VM
#                         • Aggregate packet statistics (sent/received/lost/%)
#
# NOTE: az vm run-command invoke has inherent latency (~10-20s per call).
#       This script detects GATEWAY-level downtime (seconds to minutes), not
#       sub-second micro-outages. For sub-second analysis use Azure Network
#       Watcher Connection Monitor (see the README for details).
# =============================================================================

set -euo pipefail

# ─── Parameters ──────────────────────────────────────────────────────────────
rg=lab-er-scale                       # default — overridden by prompt below
spoke1Name=az-spk1
monitorVm="${spoke1Name}-vm"
logFile="/tmp/er-monitor.log"
summaryFile="/tmp/er-monitor-summary.txt"
gwEventsFile="/tmp/er-gw-events.log"  # local file: gateway state transitions

# ─── CONFIGURE THIS ──────────────────────────────────────────────────────────
ONPREM_IP="192.168.0.x"   # Replace with actual GCP VM internal IP
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$ONPREM_IP" == "192.168.0.x" ]]; then
    echo "ERROR: ONPREM_IP is not configured. Edit this script and set ONPREM_IP."
    exit 1
fi

# ─── Scenario & gateway selection ────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  EXPRESSROUTE UPGRADE / MIGRATION — DOWNTIME MONITOR"
echo "============================================================"
echo ""
echo "  Which scenario are you monitoring?"
echo "  1) Scenario 1 — In-place SKU upgrade   (3-scenario1-upgrade-ergw.sh)"
echo "  2) Scenario 2 — Customer-controlled migration (4-scenario2-migrate-ergw.sh)"
echo ""
read -r -p "  Enter 1 or 2 [1]: " scenario_input
SCENARIO="${scenario_input:-1}"
if [[ "$SCENARIO" != "1" && "$SCENARIO" != "2" ]]; then
    echo "ERROR: Invalid choice '$SCENARIO'. Please enter 1 or 2."
    exit 1
fi

read -r -p "  Resource Group name [$rg]: " rg_input
rg="${rg_input:-$rg}"

read -r -p "  Hub VNet name prefix [az-hub]: " hub_input
hubName="${hub_input:-az-hub}"
gwName="${hubName}-ergw"

echo ""
if [[ "$SCENARIO" == "1" ]]; then
    echo "  Scenario : 1 — In-place SKU upgrade"
else
    echo "  Scenario : 2 — Gateway migration (Prepare / Execute / Commit or Abort)"
fi
echo "  Resource Group : $rg"
echo "  Gateway        : $gwName"
echo ""

# ─── Prompt for monitoring duration ──────────────────────────────────────────
echo ""
if [[ "$SCENARIO" == "1" ]]; then
    echo "  Scenario 1 upgrade typically takes 20-45 minutes."
    _defaultDuration=2700
else
    echo "  Scenario 2 full migration (Prepare + Execute + Commit/Abort) can take up to 90 min."
    _defaultDuration=5400
fi
read -r -p "  Monitor duration in seconds [$_defaultDuration]: " duration_input
PING_DURATION="${duration_input:-$_defaultDuration}"
if ! [[ "$PING_DURATION" =~ ^[0-9]+$ ]] || (( PING_DURATION < 60 )); then
    echo "ERROR: Duration must be a number >= 60 seconds."
    exit 1
fi
echo "  Monitoring for ${PING_DURATION}s (~$((PING_DURATION / 60))m)"

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

# ─── Helper: query ExpressRoute gateway provisioningState + SKU + migrationPhase ─
query_gateway_state() {
    az network vnet-gateway show \
        --name "$gwName" \
        --resource-group "$rg" \
        --query "{s:provisioningState, k:sku.name, m:migrationPhase}" \
        --output json 2>/dev/null \
    || echo '{"s":"Unknown","k":"Unknown","m":null}'
}

echo ""
echo "============================================================"
if [[ "$SCENARIO" == "1" ]]; then
    echo "  SCENARIO 1: IN-PLACE UPGRADE MONITOR"
else
    echo "  SCENARIO 2: GATEWAY MIGRATION MONITOR"
fi
echo "============================================================"
echo "  Source VM   : $monitorVm  (in $rg)"
echo "  Target IP   : $ONPREM_IP  (on-premises GCP VM)"
echo "  Gateway     : $gwName     (in $rg)"
echo "  Duration    : ${PING_DURATION}s (~$((PING_DURATION/60))m)"
echo "  Start time  : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# ─── Capture initial gateway state before the upgrade/migration starts ────────
echo "  Querying initial gateway state..."
> "$gwEventsFile"
_initJson=$(query_gateway_state)
prevGwState=$(echo "$_initJson" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('s','Unknown'))")
prevGwSku=$(echo "$_initJson" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('k','Unknown'))")
prevGwPhase=$(echo "$_initJson" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('m') or 'None')")
updateRound=0
echo "$(date '+%Y-%m-%d %H:%M:%S')  INITIAL  state=$prevGwState  sku=$prevGwSku  phase=$prevGwPhase" \
    >> "$gwEventsFile"
echo "  Initial gateway: state=$prevGwState  sku=$prevGwSku  phase=$prevGwPhase"
echo ""

# ─── Phase 1: Start Background ICMP Monitor Inside the VM ────────────────────
echo "=== Phase 1: Starting background ICMP monitor inside $monitorVm ==="

monitorScript="
# Kill any previous monitor
pkill -f 'ping.*$ONPREM_IP' 2>/dev/null || true
rm -f $logFile $summaryFile

# Write header
echo 'MONITOR_START' > $logFile
echo \"Started: \$(date '+%Y-%m-%d %H:%M:%S')\" >> $logFile
echo \"Target:  $ONPREM_IP\" >> $logFile
echo \"Batches: 10 ICMP packets per interval, every 10 seconds\" >> $logFile
echo '---' >> $logFile

# Background ICMP batch monitoring loop
#   Each iteration sends 10 pings (200 ms apart) and parses ping's own
#   summary line for loss % and RTT min/avg/max.
(
  total_sent=0; total_received=0; total_lost=0
  outage_start=''; batch_count=10; sleep_interval=10

  start_epoch=\$(date +%s)
  while true; do
    elapsed=\$(( \$(date +%s) - start_epoch ))
    [[ \$elapsed -ge $PING_DURATION ]] && break

    ts=\$(date '+%Y-%m-%d %H:%M:%S')

    # Run batch: 10 packets, 200 ms apart, 1 s per-packet deadline
    result=\$(ping -c \$batch_count -i 0.2 -W 1 $ONPREM_IP 2>&1 || true)

    # Parse native ping summary line, e.g.:
    #   10 packets transmitted, 8 received, 20% packet loss, time 1803ms
    #   rtt min/avg/max/mdev = 12.3/14.1/18.7/1.9 ms
    sent=\$(echo \"\$result\" | grep -oP '\d+(?= packets transmitted)' || echo 0)
    recv=\$(echo \"\$result\" | grep -oP '\d+(?= received)'           || echo 0)
    loss_pct=\$(echo \"\$result\" | grep -oP '\d+(?=% packet loss)'   || echo 100)
    rtt=\$(echo \"\$result\" | grep -oP '(?<== )[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+' || echo '-')

    [[ -z \"\$sent\" ]]     && sent=0
    [[ -z \"\$recv\" ]]     && recv=0
    [[ -z \"\$loss_pct\" ]] && loss_pct=100

    lost_this=\$(( sent - recv ))
    total_sent=\$(( total_sent + sent ))
    total_received=\$(( total_received + recv ))
    total_lost=\$(( total_lost + lost_this ))

    if [[ \"\$loss_pct\" -ge 100 ]]; then
      # Complete outage
      if [[ -z \"\$outage_start\" ]]; then
        outage_start=\"\$ts\"
        echo \"\$ts  loss=100%  rtt=-          *** OUTAGE START ***\" >> $logFile
      else
        echo \"\$ts  loss=100%  rtt=-\" >> $logFile
      fi
    elif [[ \"\$loss_pct\" -gt 0 ]]; then
      # Partial packet loss
      if [[ -n \"\$outage_start\" ]]; then
        echo \"\$ts  loss=\${loss_pct}%   rtt=\${rtt}ms  RESTORED (partial, started: \$outage_start)\" >> $logFile
        outage_start=''
      else
        echo \"\$ts  loss=\${loss_pct}%   rtt=\${rtt}ms  PARTIAL LOSS\" >> $logFile
      fi
    else
      # Full reachability
      if [[ -n \"\$outage_start\" ]]; then
        echo \"\$ts  loss=0%    rtt=\${rtt}ms  RESTORED (outage started: \$outage_start)\" >> $logFile
        outage_start=''
      else
        echo \"\$ts  loss=0%    rtt=\${rtt}ms  REACH\" >> $logFile
      fi
    fi

    sleep \$sleep_interval
  done

  # Final summary
  echo '---' >> $logFile
  echo 'MONITOR_COMPLETE' >> $logFile
  echo \"Finished: \$(date '+%Y-%m-%d %H:%M:%S')\" >> $logFile
  echo '' >> $logFile
  echo '=== AGGREGATE PACKET STATISTICS ===' >> $logFile
  echo \"Packets sent:     \$total_sent\" >> $logFile
  echo \"Packets received: \$total_received\" >> $logFile
  echo \"Packets lost:     \$total_lost\" >> $logFile
  if [[ \$total_sent -gt 0 ]]; then
    overall_pct=\$(( total_lost * 100 / total_sent ))
    echo \"Overall loss:     \${overall_pct}%\" >> $logFile
  fi
) &
echo \"Monitor PID: \$!\"
"

run_in_vm "$monitorScript"
echo "  Background monitor started inside $monitorVm"
echo ""

# ─── Phase 2: Combined Live Tracking ─────────────────────────────────────────
echo "=== Phase 2: Live tracking (Ctrl+C to stop and generate report) ==="
if [[ "$SCENARIO" == "1" ]]; then
    echo "  [GW]   Detecting SKU transition (ErGw?AZ → ErGwScale) + provisioningState changes"
else
    echo "  [GW]   Detecting migration phase transitions:"
    echo "         Round 1=PREPARE (no traffic impact)  Round 2=EXECUTE (BGP flap expected)  Round 3=COMMIT/ABORT"
fi
echo "  [ICMP] Polling VM ICMP log (10-packet batches) via az vm run-command (~30 s cycle)"
echo ""

# Cleanup trap — always generate final report on Ctrl+C or normal exit
trap 'echo ""; echo "Stopping live tracking..."; generate_report' EXIT INT TERM

generate_report() {
    echo ""
    echo "============================================================"
    echo "  PHASE 3: FINAL REPORT"
    echo "============================================================"

    # ── Gateway Event Timeline ──────────────────────────────────────────────
    echo ""
    echo "--- GATEWAY EVENT TIMELINE ---"
    if [[ -s "$gwEventsFile" ]]; then
        cat "$gwEventsFile"
    else
        echo "  (no gateway state transitions recorded)"
    fi
    echo ""

    # ── Full ICMP log ───────────────────────────────────────────────────────
    echo "--- ICMP LOG (retrieved from $monitorVm) ---"
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

    # ── Aggregate packet statistics ─────────────────────────────────────────
    outageCount=$(echo "$finalLog" | grep -c "OUTAGE START" || true)
    lossLines=$(echo "$finalLog" | grep -cE "OUTAGE START|PARTIAL LOSS" || true)

    totalSent=$(echo "$finalLog" | grep "Packets sent:"     | grep -oP '\d+$' || echo "N/A")
    totalRecv=$(echo "$finalLog" | grep "Packets received:" | grep -oP '\d+$' || echo "N/A")
    totalLost=$(echo "$finalLog" | grep "Packets lost:"     | grep -oP '\d+$' || echo "N/A")
    overallLoss=$(echo "$finalLog" | grep "Overall loss:"   | grep -oP '\d+(?=%)' || echo "N/A")

    echo "============================================================"
    echo "  ICMP SUMMARY"
    echo "============================================================"
    echo "  Number of outages detected:    $outageCount"
    echo "  LOSS / PARTIAL LOSS events:    $lossLines"
    echo ""
    echo "  PACKET STATISTICS (aggregated across all batches):"
    echo "  Packets sent:                  $totalSent"
    echo "  Packets received:              $totalRecv"
    echo "  Packets lost:                  $totalLost"
    echo "  Overall packet loss:           ${overallLoss}%"
    if [[ "$outageCount" -eq 0 ]]; then
        echo ""
        echo "  ✅ No connectivity interruption detected!"
    else
        echo ""
        echo "  ⚠️  Connectivity interruption(s) detected. Correlate with Gateway Timeline above."
    fi
    echo ""
    echo "  Full ICMP log on $monitorVm: $logFile"
    echo "  Retrieve it with:"
    echo "    az vm run-command invoke -g $rg -n $monitorVm --command-id RunShellScript \\"
    echo "      --scripts 'cat $logFile' --query 'value[0].message' -o tsv"
    echo "============================================================"

    # Stop the background ICMP loop inside the VM
    az vm run-command invoke \
        --resource-group "$rg" \
        --name "$monitorVm" \
        --command-id RunShellScript \
        --scripts "pkill -f 'ping.*$ONPREM_IP' 2>/dev/null || true; echo 'Monitor stopped.'" \
        --query 'value[0].message' \
        --output tsv 2>/dev/null || true
}

# ─── Combined live polling loop ───────────────────────────────────────────────
# Each iteration:
#   1. Query gateway state locally  (fast: ~2-3 s via az network vnet-gateway show)
#   2. Poll VM ICMP log via run-cmd (slow: ~15-20 s — az vm run-command latency)
#   sleep 10 s between iterations; total cycle ~30 s.
# ─────────────────────────────────────────────────────────────────────────────
iteration=0
while true; do
    iteration=$((iteration + 1))
    loopTs=$(date '+%H:%M:%S')

    # ── 1. Gateway state poll (local, fast ~2-3 s) ─────────────────────────
    _gwJson=$(query_gateway_state)
    gwState=$(echo "$_gwJson" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('s','Unknown'))")
    gwSku=$(echo "$_gwJson" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('k','Unknown'))")
    gwPhase=$(echo "$_gwJson" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('m') or 'None')")

    eventTs=$(date '+%Y-%m-%d %H:%M:%S')

    # Detect gateway state / SKU / migrationPhase transitions
    if [[ "$gwState" != "$prevGwState" || "$gwSku" != "$prevGwSku" || "$gwPhase" != "$prevGwPhase" ]]; then
        changeDesc="state: ${prevGwState}→${gwState}  sku: ${prevGwSku}→${gwSku}  phase: ${prevGwPhase}→${gwPhase}"
        eventLabel=""

        if [[ "$gwState" == "Updating" && "$prevGwState" == "Succeeded" ]]; then
            updateRound=$(( updateRound + 1 ))
            if [[ "$SCENARIO" == "1" ]]; then
                eventLabel="UPGRADE STARTED — in-place SKU change submitted"
            else
                case $updateRound in
                    1) eventLabel="PREPARE STARTED  — provisioning new ErGwScale alongside original (no traffic impact)" ;;
                    2) eventLabel="EXECUTE STARTED  — transferring ER connections  *** BGP FLAP EXPECTED ***" ;;
                    3) eventLabel="COMMIT/ABORT STARTED — finalizing or rolling back migration" ;;
                    *) eventLabel="GATEWAY UPDATING (phase round $updateRound)" ;;
                esac
            fi

        elif [[ "$gwState" == "Succeeded" && "$prevGwState" == "Updating" ]]; then
            if [[ "$SCENARIO" == "1" ]]; then
                if [[ "$gwSku" == "ErGwScale" ]]; then
                    eventLabel="UPGRADE COMPLETE ✅ — Gateway is now ErGwScale"
                else
                    eventLabel="GATEWAY UPDATE COMPLETE (sku=$gwSku — verify expected)"
                fi
            else
                case $updateRound in
                    1) eventLabel="PREPARE COMPLETE — new gateway provisioned; original still active" ;;
                    2) eventLabel="EXECUTE COMPLETE — connections transferred; validation window open" ;;
                    3)
                        if [[ "$gwSku" == "ErGwScale" ]]; then
                            eventLabel="COMMIT COMPLETE ✅ — Migration finalized; gateway is ErGwScale"
                        else
                            eventLabel="ABORT COMPLETE ↩ — Rolled back; original gateway restored (sku=$gwSku)"
                        fi
                        ;;
                    *) eventLabel="GATEWAY UPDATE COMPLETE (round=$updateRound  sku=$gwSku)" ;;
                esac
            fi
        elif [[ "$gwState" == "Failed" ]]; then
            eventLabel="*** GATEWAY OPERATION FAILED — check Azure Activity Log ***"
        fi

        # Append to local gateway events timeline log
        echo "$eventTs  [CHANGE]  $changeDesc" >> "$gwEventsFile"
        [[ -n "$eventLabel" ]] && echo "              → $eventLabel" >> "$gwEventsFile"

        # Print state-change banner to the terminal
        echo ""
        echo "  ════════════════════════════════════════════════════════════"
        echo "  GW STATE CHANGE @ $eventTs"
        echo "  $changeDesc"
        [[ -n "$eventLabel" ]] && echo "  → $eventLabel"
        echo "  ════════════════════════════════════════════════════════════"
        echo ""

        prevGwState="$gwState"
        prevGwSku="$gwSku"
        prevGwPhase="$gwPhase"
    fi

    # ── 2. VM ICMP log tail (remote, slow ~15-20 s) ────────────────────────
    echo "[$loopTs] iter=$iteration  GW: state=$gwState  sku=$gwSku${gwPhase:+  phase=$gwPhase}"

    recentLog=$(az vm run-command invoke \
        --resource-group "$rg" \
        --name "$monitorVm" \
        --command-id RunShellScript \
        --scripts "tail -5 $logFile 2>/dev/null || echo 'Log not ready yet...'" \
        --query 'value[0].message' \
        --output tsv 2>/dev/null)

    echo "$recentLog"
    echo "---"

    # Exit when the background ICMP loop inside the VM has finished its full run
    if echo "$recentLog" | grep -q "MONITOR_COMPLETE"; then
        echo "Background ICMP monitor completed. Generating final report..."
        break
    fi

    sleep 10
done
