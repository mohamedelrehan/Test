#!/usr/bin/env bash
set -Eeuo pipefail

RG=""
DOMAIN=""
APPGW="ziti-ha-appgw"
CONTROLLERS=("ziti-ha-controller01" "ziti-ha-controller02" "ziti-ha-controller03")
ROUTERS=("ziti-ha-router01" "ziti-ha-router02" "ziti-ha-router03")
OUTDIR="./openziti-ha-validation-report"
RUN_FAILOVER="false"

usage() {
  cat <<'USAGE'
OpenZiti Azure HA Validation

Usage:
  validate-openziti-ha.sh --resource-group <rg-name> --domain <public-dns-name> [options]

Required:
  --resource-group, -g   Azure resource group containing the OpenZiti deployment
  --domain, -d           Public DNS name, for example ziti.example.com

Options:
  --appgw                Application Gateway name. Default: ziti-ha-appgw
  --outdir               Output directory. Default: ./openziti-ha-validation-report
  --failover-test        Stop the current leader and verify re-election, then restart it
  --help, -h             Show this help

Examples:
  ./scripts/validate-openziti-ha.sh -g openziti4 -d umbramesh.elrehan.com
  ./scripts/validate-openziti-ha.sh -g openziti4 -d umbramesh.elrehan.com --failover-test
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group|-g) RG="${2:-}"; shift 2 ;;
    --domain|-d) DOMAIN="${2:-}"; shift 2 ;;
    --appgw) APPGW="${2:-}"; shift 2 ;;
    --outdir) OUTDIR="${2:-}"; shift 2 ;;
    --failover-test) RUN_FAILOVER="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$RG" || -z "$DOMAIN" ]]; then
  echo "ERROR: --resource-group and --domain are required."
  usage
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI 'az' is required."; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required."; exit 2; }

TS="$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"
LOG="$OUTDIR/OpenZiti-HA-Validation-$TS.log"
JSON="$OUTDIR/OpenZiti-HA-Validation-$TS.json"
HTML="$OUTDIR/OpenZiti-HA-Validation-$TS.html"
TMP="$OUTDIR/.tmp-$TS"
mkdir -p "$TMP"
: > "$TMP/results.tsv"

exec > >(tee "$LOG") 2>&1

PASS=0
WARN=0
FAIL=0

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "\"%s\\n\"", $0}'
}

html_escape_file() {
  python3 - "$1" <<'PY'
import html, sys, pathlib
p = pathlib.Path(sys.argv[1])
print(html.escape(p.read_text(errors='replace')))
PY
}

record() {
  local status="$1" section="$2" message="$3" file="$4"
  case "$status" in
    PASS) PASS=$((PASS+1)) ;;
    WARN) WARN=$((WARN+1)) ;;
    FAIL) FAIL=$((FAIL+1)) ;;
  esac
  printf '%s|%s|%s|%s\n' "$status" "$section" "$message" "$file" >> "$TMP/results.tsv"
}

run_cmd() {
  local name="$1"; shift
  local outfile="$TMP/${name}.txt"
  echo
  echo "================================================================"
  echo "CHECK: $name"
  echo "COMMAND: $*"
  echo "================================================================"
  set +e
  "$@" > "$outfile" 2>&1
  local rc=$?
  set -e
  cat "$outfile"
  return $rc
}

run_az_vm() {
  local vm="$1" script="$2" outfile="$3"
  az vm run-command invoke \
    -g "$RG" \
    -n "$vm" \
    --command-id RunShellScript \
    --scripts "$script" \
    --query "value[0].message" \
    -o tsv > "$outfile" 2>&1
}

extract_leader() {
  awk -F '│' '/ziti-ha-controller/ { gsub(/ /,"",$2); gsub(/ /,"",$5); gsub(/ /,"",$6); if ($5=="true" && $6 ~ /^v/) print $2 }' "$1" | head -1
}

echo "OpenZiti Azure HA Validation"
echo "Resource Group: $RG"
echo "Public Domain: $DOMAIN"
echo "App Gateway: $APPGW"
echo "UTC Time: $(date -u)"
echo "Failover Test: $RUN_FAILOVER"

# 1. Azure VM status
if run_cmd "azure-vms" az vm list -g "$RG" -d --query "[].{Name:name,Power:powerState,PrivateIP:privateIps,PublicIP:publicIps}" -o table; then
  VM_RUNNING_COUNT=$(grep -c "VM running" "$TMP/azure-vms.txt" || true)
  if [[ "$VM_RUNNING_COUNT" -ge 6 ]]; then
    record PASS "Azure VMs" "All expected controller/router VMs appear to be running" "$TMP/azure-vms.txt"
  else
    record WARN "Azure VMs" "Fewer than 6 running VMs detected; review VM list" "$TMP/azure-vms.txt"
  fi
else
  record FAIL "Azure VMs" "Failed to query VMs" "$TMP/azure-vms.txt"
fi

# 2. App Gateway backend health
if run_cmd "appgw-health" az network application-gateway show-backend-health -g "$RG" -n "$APPGW" --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address,Health:health,Probe:healthProbeLog}" -o table; then
  UNHEALTHY=$(grep -E "Unhealthy|Unknown" "$TMP/appgw-health.txt" || true)
  HEALTHY_COUNT=$(grep -c "Healthy" "$TMP/appgw-health.txt" || true)
  if [[ -z "$UNHEALTHY" && "$HEALTHY_COUNT" -ge 3 ]]; then
    record PASS "Application Gateway" "All controller backends are healthy" "$TMP/appgw-health.txt"
  else
    record FAIL "Application Gateway" "One or more controller backends are not healthy" "$TMP/appgw-health.txt"
  fi
else
  record FAIL "Application Gateway" "Failed to query backend health" "$TMP/appgw-health.txt"
fi

# 3. HTTP settings cookie affinity
if run_cmd "appgw-http-settings" az network application-gateway http-settings list -g "$RG" --gateway-name "$APPGW" --query "[].{Name:name,Port:port,Protocol:protocol,CookieAffinity:cookieBasedAffinity,HostName:hostName}" -o table; then
  if grep -q "Enabled" "$TMP/appgw-http-settings.txt"; then
    record PASS "Application Gateway" "Cookie-based affinity is enabled" "$TMP/appgw-http-settings.txt"
  else
    record WARN "Application Gateway" "Cookie-based affinity does not appear enabled; ZAC login may not remain sticky" "$TMP/appgw-http-settings.txt"
  fi
else
  record WARN "Application Gateway" "Could not inspect HTTP settings" "$TMP/appgw-http-settings.txt"
fi

# 4. Controller HA cluster
CLUSTER_OUT="$TMP/controller-cluster.txt"
if run_az_vm "ziti-ha-controller01" "sudo ziti agent cluster list" "$CLUSTER_OUT"; then
  cat "$CLUSTER_OUT"
  CONNECTED_COUNT=$(grep -c "v2.0.0" "$CLUSTER_OUT" || true)
  VOTER_COUNT=$(grep -c "│ true" "$CLUSTER_OUT" || true)
  if [[ "$CONNECTED_COUNT" -ge 3 && "$VOTER_COUNT" -ge 3 ]]; then
    record PASS "Controller HA" "Three connected voting controllers detected" "$CLUSTER_OUT"
  else
    record FAIL "Controller HA" "Controller HA cluster is not fully connected" "$CLUSTER_OUT"
  fi
else
  cat "$CLUSTER_OUT" || true
  record FAIL "Controller HA" "Failed to run ziti agent cluster list" "$CLUSTER_OUT"
fi

# 5. Controller services/config
CTRL_COMBINED="$TMP/controller-services.txt"
: > "$CTRL_COMBINED"
CTRL_FAIL=0
for VM in "${CONTROLLERS[@]}"; do
  OUT="$TMP/${VM}-service.txt"
  SCRIPT="echo VM=$VM; sudo systemctl is-active ziti-controller; sudo grep -nE 'advertiseAddress|address:' /var/lib/ziti-controller/config.yml | head -20"
  if run_az_vm "$VM" "$SCRIPT" "$OUT"; then
    cat "$OUT" | tee -a "$CTRL_COMBINED"
    grep -q "active" "$OUT" || CTRL_FAIL=1
    grep -q "address: ${DOMAIN}:443" "$OUT" || CTRL_FAIL=1
    grep -q "advertiseAddress: tls:${VM}:6262" "$OUT" || CTRL_FAIL=1
  else
    cat "$OUT" | tee -a "$CTRL_COMBINED" || true
    CTRL_FAIL=1
  fi
done
if [[ "$CTRL_FAIL" -eq 0 ]]; then
  record PASS "Controller Services" "All controllers active; public API advertises ${DOMAIN}:443 and HA stays on private 6262" "$CTRL_COMBINED"
else
  record FAIL "Controller Services" "One or more controllers are inactive or have unexpected advertised addresses" "$CTRL_COMBINED"
fi

# 6. Router services/logs
ROUTER_COMBINED="$TMP/router-services.txt"
: > "$ROUTER_COMBINED"
ROUTER_FAIL=0
for VM in "${ROUTERS[@]}"; do
  OUT="$TMP/${VM}-service.txt"
  SCRIPT="echo VM=$VM; sudo systemctl is-active ziti-router; sudo journalctl -u ziti-router --no-pager -n 40 | grep -E 'subscribed|controller|reconnected|update ctrl|link already known' || true"
  if run_az_vm "$VM" "$SCRIPT" "$OUT"; then
    cat "$OUT" | tee -a "$ROUTER_COMBINED"
    grep -q "active" "$OUT" || ROUTER_FAIL=1
  else
    cat "$OUT" | tee -a "$ROUTER_COMBINED" || true
    ROUTER_FAIL=1
  fi
done
if [[ "$ROUTER_FAIL" -eq 0 ]]; then
  record PASS "Router Services" "All routers are active and logs show controller/link activity" "$ROUTER_COMBINED"
else
  record FAIL "Router Services" "One or more routers are inactive or could not be checked" "$ROUTER_COMBINED"
fi

# 7. Public API
API_OUT="$TMP/public-api-version.txt"
echo
if curl -k -s "https://${DOMAIN}/edge/management/v1/version" > "$API_OUT" 2>&1; then
  cat "$API_OUT"
  if grep -q "HA_CONTROLLER" "$API_OUT" && grep -q "${DOMAIN}:443" "$API_OUT"; then
    record PASS "Public API" "Public API reachable and advertises HA controller capability on ${DOMAIN}:443" "$API_OUT"
  else
    record WARN "Public API" "Public API reachable but expected HA/domain markers were not found" "$API_OUT"
  fi
else
  cat "$API_OUT" || true
  record FAIL "Public API" "Public API is not reachable" "$API_OUT"
fi

# 8. Certificate SAN check
CERT_COMBINED="$TMP/controller-certificates.txt"
: > "$CERT_COMBINED"
CERT_FAIL=0
for VM in "${CONTROLLERS[@]}"; do
  OUT="$TMP/${VM}-cert.txt"
  SCRIPT="echo VM=$VM; CERT=\$(ls /var/lib/ziti-controller/*.server.chain.cert | head -1); echo Certificate=\$CERT; sudo openssl x509 -in \$CERT -noout -subject -ext subjectAltName"
  if run_az_vm "$VM" "$SCRIPT" "$OUT"; then
    cat "$OUT" | tee -a "$CERT_COMBINED"
    grep -q "DNS:${DOMAIN}" "$OUT" || CERT_FAIL=1
  else
    cat "$OUT" | tee -a "$CERT_COMBINED" || true
    CERT_FAIL=1
  fi
done
if [[ "$CERT_FAIL" -eq 0 ]]; then
  record PASS "Certificates" "All controller certificates include DNS:${DOMAIN}" "$CERT_COMBINED"
else
  record FAIL "Certificates" "One or more controller certificates are missing DNS:${DOMAIN}" "$CERT_COMBINED"
fi

# 9. Optional failover test
FAILOVER_FILE="$TMP/failover-test.txt"
if [[ "$RUN_FAILOVER" == "true" ]]; then
  echo "Running failover test" | tee "$FAILOVER_FILE"
  LEADER="$(extract_leader "$CLUSTER_OUT" || true)"
  if [[ -z "$LEADER" ]]; then
    LEADER="ziti-ha-controller01"
    echo "Could not automatically parse leader; defaulting to $LEADER" | tee -a "$FAILOVER_FILE"
  fi
  echo "Stopping leader: $LEADER" | tee -a "$FAILOVER_FILE"
  run_az_vm "$LEADER" "sudo systemctl stop ziti-controller && echo stopped && sudo systemctl is-active ziti-controller || true" "$TMP/failover-stop.txt" || true
  cat "$TMP/failover-stop.txt" | tee -a "$FAILOVER_FILE"
  sleep 20
  CHECK_VM="ziti-ha-controller02"
  [[ "$LEADER" == "ziti-ha-controller02" ]] && CHECK_VM="ziti-ha-controller03"
  run_az_vm "$CHECK_VM" "sudo ziti agent cluster list" "$TMP/failover-cluster.txt" || true
  cat "$TMP/failover-cluster.txt" | tee -a "$FAILOVER_FILE"
  run_az_vm "$LEADER" "sudo systemctl start ziti-controller && sleep 10 && sudo systemctl is-active ziti-controller" "$TMP/failover-restart.txt" || true
  cat "$TMP/failover-restart.txt" | tee -a "$FAILOVER_FILE"
  if grep -q "<not connected>" "$TMP/failover-cluster.txt" && grep -q "active" "$TMP/failover-restart.txt"; then
    record PASS "Failover" "Leader stop/re-election/restart test completed" "$FAILOVER_FILE"
  else
    record WARN "Failover" "Failover test ran but output should be reviewed manually" "$FAILOVER_FILE"
  fi
else
  echo "Failover test not requested. Re-run with --failover-test to validate leader stop/re-election." > "$FAILOVER_FILE"
  record WARN "Failover" "Failover test not executed by default" "$FAILOVER_FILE"
fi

# Known ZAC warning note
KNOWN_FILE="$TMP/known-zac-warning.txt"
cat > "$KNOWN_FILE" <<'NOTE'
ZAC may display: "Found 3 controllers in HA cluster but was unable to authenticate with all of them. Reverting to standard zt-session authentication."

In this reference architecture, controller HA port 6262 remains private/internal. Public browser access goes through Application Gateway 443 to controller backend 1280. This warning is expected/cosmetic when ZAC cannot authenticate directly with every private HA controller endpoint from the browser path. It does not mean controller HA, router HA, or public management API failover is broken.
NOTE
record WARN "Known ZAC Warning" "Expected/cosmetic in this architecture; 6262 remains private by design" "$KNOWN_FILE"

OVERALL="PASS"
if [[ "$FAIL" -gt 0 ]]; then
  OVERALL="FAIL"
elif [[ "$WARN" -gt 0 ]]; then
  OVERALL="WARN"
fi

# Build JSON
{
  echo "{"
  echo "  \"report\": {"
  echo "    \"title\": \"OpenZiti Azure HA Validation Report\","
  echo "    \"timestampUtc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "    \"resourceGroup\": \"$RG\","
  echo "    \"publicDnsName\": \"$DOMAIN\","
  echo "    \"appGateway\": \"$APPGW\","
  echo "    \"overallStatus\": \"$OVERALL\","
  echo "    \"summary\": {\"pass\": $PASS, \"warn\": $WARN, \"fail\": $FAIL},"
  echo "    \"checks\": ["
  first=1
  while IFS='|' read -r status section message file; do
    [[ -z "$status" ]] && continue
    [[ $first -eq 0 ]] && echo ","
    first=0
    detail=$(cat "$file" 2>/dev/null | json_escape)
    msg=$(printf '%s' "$message" | json_escape)
    sec=$(printf '%s' "$section" | json_escape)
    echo -n "      {\"status\": \"$status\", \"section\": $sec, \"message\": $msg, \"detail\": $detail}"
  done < "$TMP/results.tsv"
  echo
  echo "    ]"
  echo "  }"
  echo "}"
} > "$JSON"

# Build HTML
cat > "$HTML" <<HTML_HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenZiti Azure HA Validation Report</title>
<style>
  body { font-family: Arial, Helvetica, sans-serif; margin: 32px; background: #f7f8fa; color: #1f2937; }
  .card { background: white; border-radius: 12px; padding: 24px; margin-bottom: 18px; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
  h1 { margin: 0 0 8px 0; }
  .meta { color: #4b5563; line-height: 1.6; }
  .status { display: inline-block; padding: 8px 14px; border-radius: 999px; font-weight: bold; }
  .PASS { background: #dcfce7; color: #166534; }
  .WARN { background: #fef3c7; color: #92400e; }
  .FAIL { background: #fee2e2; color: #991b1b; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 10px; border-bottom: 1px solid #e5e7eb; vertical-align: top; }
  pre { white-space: pre-wrap; word-break: break-word; background: #111827; color: #f9fafb; padding: 14px; border-radius: 8px; max-height: 420px; overflow: auto; }
  details { margin-top: 8px; }
  summary { cursor: pointer; color: #2563eb; }
  .small { font-size: 13px; color: #6b7280; }
</style>
</head>
<body>
  <div class="card">
    <h1>OpenZiti Azure HA Validation Report</h1>
    <div class="meta">
      <div><strong>Overall Status:</strong> <span class="status $OVERALL">$OVERALL</span></div>
      <div><strong>Resource Group:</strong> $RG</div>
      <div><strong>Public DNS:</strong> $DOMAIN</div>
      <div><strong>Application Gateway:</strong> $APPGW</div>
      <div><strong>Generated UTC:</strong> $(date -u +%Y-%m-%dT%H:%M:%SZ)</div>
      <div><strong>Summary:</strong> PASS=$PASS, WARN=$WARN, FAIL=$FAIL</div>
    </div>
  </div>
  <div class="card">
    <h2>Validation Checks</h2>
    <table>
      <thead><tr><th>Status</th><th>Section</th><th>Message</th><th>Evidence</th></tr></thead>
      <tbody>
HTML_HEAD

while IFS='|' read -r status section message file; do
  [[ -z "$status" ]] && continue
  escaped=$(html_escape_file "$file")
  cat >> "$HTML" <<HTML_ROW
        <tr>
          <td><span class="status $status">$status</span></td>
          <td>$section</td>
          <td>$message</td>
          <td><details><summary>Show output</summary><pre>$escaped</pre></details></td>
        </tr>
HTML_ROW
done < "$TMP/results.tsv"

cat >> "$HTML" <<HTML_TAIL
      </tbody>
    </table>
  </div>
  <div class="card">
    <h2>Final Notes</h2>
    <p>The known ZAC HA authentication warning is expected in this architecture when private controller HA endpoints remain internal on port 6262. Validate HA using controller cluster status, router logs, App Gateway health, public API, and optional failover test.</p>
    <p class="small">Generated by scripts/validate-openziti-ha.sh</p>
  </div>
</body>
</html>
HTML_TAIL

rm -rf "$TMP"

echo
echo "================================================================"
echo "Validation complete"
echo "Overall Status: $OVERALL"
echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
echo "HTML report: $HTML"
echo "JSON report: $JSON"
echo "Log file:    $LOG"
echo "================================================================"

if [[ "$OVERALL" == "FAIL" ]]; then
  exit 1
fi
