#!/usr/bin/env bash
set -uo pipefail

# OpenZiti Azure HA Validation Tool
# Single-file validation script. Run from Azure Cloud Shell or any machine with Azure CLI.

RG=""
DOMAIN=""
APPGW="ziti-ha-appgw"
PRIMARY_CONTROLLER="ziti-ha-controller01"
OUT_DIR="openziti-ha-validation-report"
FAILOVER_TEST="false"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RESULTS_JSON_ITEMS=""
LOG_FILE=""
JSON_FILE=""
HTML_FILE=""

usage() {
  cat <<USAGE
OpenZiti Azure HA Validation Tool

Usage:
  ./validation/validate.sh --resource-group <rg> --domain <fqdn> [options]

Required:
  --resource-group, -g   Azure resource group containing the OpenZiti HA deployment
  --domain, -d           Public ZAC/API domain, for example ziti.example.com

Options:
  --app-gateway          Application Gateway name. Default: ziti-ha-appgw
  --primary-controller   Controller VM used for cluster checks. Default: ziti-ha-controller01
  --out-dir              Report output directory. Default: openziti-ha-validation-report
  --failover-test        Perform disruptive controller leader failover test
  --help, -h             Show help

Examples:
  ./validation/validate.sh -g openziti4 -d umbramesh.elrehan.com
  ./validation/validate.sh -g openziti4 -d umbramesh.elrehan.com --failover-test
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group|-g) RG="${2:-}"; shift 2 ;;
    --domain|-d) DOMAIN="${2:-}"; shift 2 ;;
    --app-gateway) APPGW="${2:-}"; shift 2 ;;
    --primary-controller) PRIMARY_CONTROLLER="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --failover-test) FAILOVER_TEST="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$RG" || -z "$DOMAIN" ]]; then
  usage
  exit 1
fi

mkdir -p "$OUT_DIR"
LOG_FILE="$OUT_DIR/OpenZiti-HA-Validation-$TIMESTAMP.log"
JSON_FILE="$OUT_DIR/OpenZiti-HA-Validation-$TIMESTAMP.json"
HTML_FILE="$OUT_DIR/OpenZiti-HA-Validation-$TIMESTAMP.html"

exec > >(tee "$LOG_FILE") 2>&1

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null || sed 's/\\/\\\\/g; s/"/\\"/g'
}

add_result() {
  local section="$1"
  local name="$2"
  local status="$3"
  local details="$4"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT+1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT+1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1)) ;;
  esac
  local esc_section esc_name esc_status esc_details
  esc_section=$(printf '%s' "$section" | json_escape)
  esc_name=$(printf '%s' "$name" | json_escape)
  esc_status=$(printf '%s' "$status" | json_escape)
  esc_details=$(printf '%s' "$details" | json_escape)
  local item="{\"section\":\"$esc_section\",\"name\":\"$esc_name\",\"status\":\"$esc_status\",\"details\":\"$esc_details\"}"
  if [[ -z "$RESULTS_JSON_ITEMS" ]]; then
    RESULTS_JSON_ITEMS="$item"
  else
    RESULTS_JSON_ITEMS="$RESULTS_JSON_ITEMS,$item"
  fi
  printf '[%s] %s - %s\n%s\n\n' "$status" "$section" "$name" "$details"
}

run_cmd() {
  local title="$1"
  shift
  echo "---- $title ----"
  "$@"
  local rc=$?
  echo "---- end: $title rc=$rc ----"
  return $rc
}

run_az_vm_script() {
  local vm="$1"
  local script="$2"
  az vm run-command invoke \
    -g "$RG" \
    -n "$vm" \
    --command-id RunShellScript \
    --scripts "$script" \
    --query "value[0].message" \
    -o tsv 2>&1
}

require_tools() {
  local missing=0
  for tool in az curl python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      add_result "Prerequisites" "$tool installed" "FAIL" "$tool is required but was not found. Run from Azure Cloud Shell or install it locally."
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then
    finalize_reports
    exit 1
  fi
  add_result "Prerequisites" "Required tools" "PASS" "az, curl, and python3 are available."
}

check_azure_login() {
  local account
  account=$(az account show --query "{subscription:id,user:user.name}" -o json 2>&1)
  if [[ $? -eq 0 ]]; then
    add_result "Azure" "Azure CLI login" "PASS" "$account"
  else
    add_result "Azure" "Azure CLI login" "FAIL" "$account"
  fi
}

check_vms() {
  local out
  out=$(az vm list -g "$RG" -d --query "[].{Name:name,Power:powerState,PrivateIP:privateIps,PublicIP:publicIps}" -o table 2>&1)
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    add_result "Azure VMs" "VM inventory" "FAIL" "$out"
    return
  fi
  echo "$out"
  local expected=(ziti-ha-controller01 ziti-ha-controller02 ziti-ha-controller03 ziti-ha-router01 ziti-ha-router02 ziti-ha-router03)
  local missing=()
  for vm in "${expected[@]}"; do
    if ! grep -q "$vm" <<<"$out"; then
      missing+=("$vm")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]] && [[ $(grep -c "VM running" <<<"$out" || true) -ge 6 ]]; then
    add_result "Azure VMs" "6 VM health" "PASS" "$out"
  elif [[ ${#missing[@]} -eq 0 ]]; then
    add_result "Azure VMs" "6 VM health" "WARN" "$out"
  else
    add_result "Azure VMs" "6 VM health" "FAIL" "Missing VMs: ${missing[*]}\n$out"
  fi
}

check_appgw() {
  local settings health
  settings=$(az network application-gateway http-settings list -g "$RG" --gateway-name "$APPGW" --query "[].{Name:name,Port:port,Protocol:protocol,CookieAffinity:cookieBasedAffinity,HostName:hostName}" -o table 2>&1)
  if [[ $? -eq 0 ]]; then
    if grep -q "Enabled" <<<"$settings" && grep -q "1280" <<<"$settings"; then
      add_result "Application Gateway" "HTTP settings" "PASS" "$settings"
    else
      add_result "Application Gateway" "HTTP settings" "WARN" "$settings"
    fi
  else
    add_result "Application Gateway" "HTTP settings" "FAIL" "$settings"
  fi

  health=$(az network application-gateway show-backend-health -g "$RG" -n "$APPGW" --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{Address:address,Health:health,Probe:healthProbeLog}" -o table 2>&1)
  if [[ $? -eq 0 ]]; then
    local healthy_count
    healthy_count=$(grep -c "Healthy" <<<"$health" || true)
    if [[ "$healthy_count" -ge 3 ]]; then
      add_result "Application Gateway" "Backend health" "PASS" "$health"
    else
      add_result "Application Gateway" "Backend health" "WARN" "$health"
    fi
  else
    add_result "Application Gateway" "Backend health" "FAIL" "$health"
  fi
}

check_controller_cluster() {
  local out
  out=$(run_az_vm_script "$PRIMARY_CONTROLLER" "sudo ziti agent cluster list || true")
  if grep -q "ziti-ha-controller01" <<<"$out" && grep -q "ziti-ha-controller02" <<<"$out" && grep -q "ziti-ha-controller03" <<<"$out" && grep -q "true" <<<"$out"; then
    add_result "Controllers" "HA cluster" "PASS" "$out"
  else
    add_result "Controllers" "HA cluster" "FAIL" "$out"
  fi
}

check_controller_services() {
  local vm out combined=""
  local fail=0
  for vm in ziti-ha-controller01 ziti-ha-controller02 ziti-ha-controller03; do
    out=$(run_az_vm_script "$vm" "echo VM=$vm; sudo systemctl is-active ziti-controller; sudo grep -nE 'advertiseAddress|address:' /var/lib/ziti-controller/config.yml | head -30")
    combined+=$'\n'"$out"$'\n'
    if ! grep -q "active" <<<"$out"; then fail=1; fi
    if ! grep -q "address: ${DOMAIN}:443" <<<"$out"; then fail=1; fi
    if ! grep -q "advertiseAddress: tls:${vm}:6262" <<<"$out"; then fail=1; fi
  done
  if [[ $fail -eq 0 ]]; then
    add_result "Controllers" "Services and public API config" "PASS" "$combined"
  else
    add_result "Controllers" "Services and public API config" "FAIL" "$combined"
  fi
}

check_router_services() {
  local vm out combined=""
  local fail=0
  for vm in ziti-ha-router01 ziti-ha-router02 ziti-ha-router03; do
    out=$(run_az_vm_script "$vm" "echo VM=$vm; sudo systemctl is-active ziti-router; sudo journalctl -u ziti-router --no-pager -n 40 | grep -E 'subscribed|controller|reconnected|update ctrl|ctrlId' || true")
    combined+=$'\n'"$out"$'\n'
    if ! grep -q "active" <<<"$out"; then fail=1; fi
  done
  if [[ $fail -eq 0 ]]; then
    add_result "Routers" "Router services" "PASS" "$combined"
  else
    add_result "Routers" "Router services" "FAIL" "$combined"
  fi
}

check_public_api() {
  local out
  out=$(curl -k -s "https://${DOMAIN}/edge/management/v1/version" 2>&1)
  if grep -q "HA_CONTROLLER" <<<"$out" && grep -q "${DOMAIN}:443" <<<"$out"; then
    add_result "Public API" "Version endpoint" "PASS" "$out"
  elif grep -q "version" <<<"$out"; then
    add_result "Public API" "Version endpoint" "WARN" "$out"
  else
    add_result "Public API" "Version endpoint" "FAIL" "$out"
  fi
}

check_certs() {
  local vm out combined=""
  local fail=0
  for vm in ziti-ha-controller01 ziti-ha-controller02 ziti-ha-controller03; do
    out=$(run_az_vm_script "$vm" "echo VM=$vm; CERT=\$(ls /var/lib/ziti-controller/*.server.chain.cert | head -1); sudo openssl x509 -in \$CERT -noout -subject -ext subjectAltName 2>/dev/null | sed -n '1,20p'")
    combined+=$'\n'"$out"$'\n'
    if ! grep -q "DNS:${DOMAIN}" <<<"$out"; then fail=1; fi
  done
  if [[ $fail -eq 0 ]]; then
    add_result "Certificates" "Controller SAN includes public domain" "PASS" "$combined"
  else
    add_result "Certificates" "Controller SAN includes public domain" "FAIL" "$combined"
  fi
}

run_failover_test() {
  echo "Starting disruptive failover test..."
  local before stop_out after api_out restart_out final
  before=$(run_az_vm_script "$PRIMARY_CONTROLLER" "sudo ziti agent cluster list || true")
  add_result "Failover" "Cluster before failover" "PASS" "$before"

  stop_out=$(run_az_vm_script "ziti-ha-controller01" "sudo systemctl stop ziti-controller && echo controller01-stopped && sudo systemctl is-active ziti-controller || true")
  if grep -q "inactive" <<<"$stop_out"; then
    add_result "Failover" "Stop controller01" "PASS" "$stop_out"
  else
    add_result "Failover" "Stop controller01" "WARN" "$stop_out"
  fi

  sleep 20
  after=$(run_az_vm_script "ziti-ha-controller02" "sudo ziti agent cluster list || true")
  if grep -q "ziti-ha-controller02" <<<"$after" && grep -q "true" <<<"$after" && grep -q "<not connected>" <<<"$after"; then
    add_result "Failover" "New leader election" "PASS" "$after"
  else
    add_result "Failover" "New leader election" "WARN" "$after"
  fi

  api_out=$(curl -k -s "https://${DOMAIN}/edge/management/v1/version" 2>&1)
  if grep -q "HA_CONTROLLER" <<<"$api_out"; then
    add_result "Failover" "Public API during controller01 outage" "PASS" "$api_out"
  else
    add_result "Failover" "Public API during controller01 outage" "FAIL" "$api_out"
  fi

  restart_out=$(run_az_vm_script "ziti-ha-controller01" "sudo systemctl start ziti-controller && sleep 10 && sudo systemctl is-active ziti-controller")
  if grep -q "active" <<<"$restart_out"; then
    add_result "Failover" "Restart controller01" "PASS" "$restart_out"
  else
    add_result "Failover" "Restart controller01" "FAIL" "$restart_out"
  fi

  sleep 10
  final=$(run_az_vm_script "$PRIMARY_CONTROLLER" "sudo ziti agent cluster list || true")
  if grep -q "ziti-ha-controller01" <<<"$final" && grep -q "ziti-ha-controller02" <<<"$final" && grep -q "ziti-ha-controller03" <<<"$final"; then
    add_result "Failover" "Cluster after recovery" "PASS" "$final"
  else
    add_result "Failover" "Cluster after recovery" "WARN" "$final"
  fi
}

known_notes() {
  add_result "Known behavior" "ZAC HA authentication warning" "WARN" "ZAC may display: Found 3 controllers in HA cluster but was unable to authenticate with all of them. Reverting to standard zt-session authentication. In this reference design, public ZAC/API traffic uses App Gateway on 443, while controller HA cluster traffic remains private on 6262. This warning is expected and does not indicate failed controller HA, router HA, or public API failover."
}

finalize_reports() {
  local overall="PASS"
  if [[ $FAIL_COUNT -gt 0 ]]; then overall="FAIL"; elif [[ $WARN_COUNT -gt 0 ]]; then overall="WARN"; fi

  cat > "$JSON_FILE" <<JSON
{
  "tool": "OpenZiti Azure HA Validation Tool",
  "timestampUtc": "$TIMESTAMP",
  "resourceGroup": "$RG",
  "domain": "$DOMAIN",
  "appGateway": "$APPGW",
  "overallStatus": "$overall",
  "summary": {
    "pass": $PASS_COUNT,
    "warn": $WARN_COUNT,
    "fail": $FAIL_COUNT
  },
  "results": [
    $RESULTS_JSON_ITEMS
  ]
}
JSON

  python3 - "$JSON_FILE" "$HTML_FILE" <<'PY'
import json, html, sys
json_path, html_path = sys.argv[1], sys.argv[2]
with open(json_path, 'r', encoding='utf-8') as f:
    data = json.load(f)
status = data.get('overallStatus','UNKNOWN')
status_class = status.lower()
rows = []
for r in data.get('results', []):
    rows.append(f"""
    <tr>
      <td>{html.escape(r.get('section',''))}</td>
      <td>{html.escape(r.get('name',''))}</td>
      <td><span class="badge {html.escape(r.get('status','').lower())}">{html.escape(r.get('status',''))}</span></td>
      <td><pre>{html.escape(r.get('details',''))}</pre></td>
    </tr>""")
content = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>OpenZiti Azure HA Validation Report</title>
<style>
body {{ font-family: Arial, sans-serif; margin: 32px; background: #f6f8fb; color: #18212f; }}
.header {{ background: white; border-radius: 12px; padding: 24px; box-shadow: 0 2px 10px rgba(0,0,0,.08); }}
.status {{ font-size: 32px; font-weight: 700; }}
.status.pass {{ color: #127a32; }} .status.warn {{ color: #9a6500; }} .status.fail {{ color: #b42318; }}
.summary {{ display: flex; gap: 16px; margin: 20px 0; }}
.card {{ background: white; padding: 16px; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,.06); min-width: 120px; }}
table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 10px rgba(0,0,0,.06); }}
th, td {{ border-bottom: 1px solid #e7eaf0; padding: 12px; vertical-align: top; text-align: left; }}
th {{ background: #edf2f7; }}
.badge {{ padding: 5px 10px; border-radius: 999px; color: white; font-weight: 700; font-size: 12px; }}
.badge.pass {{ background: #127a32; }} .badge.warn {{ background: #b7791f; }} .badge.fail {{ background: #c53030; }}
pre {{ white-space: pre-wrap; word-break: break-word; max-height: 360px; overflow: auto; background: #0b1020; color: #e6edf3; padding: 12px; border-radius: 8px; }}
.meta {{ color: #526070; line-height: 1.6; }}
</style>
</head>
<body>
<div class="header">
  <h1>OpenZiti Azure HA Validation Report</h1>
  <div class="status {status_class}">{html.escape(status)}</div>
  <div class="meta">
    <div><b>Resource Group:</b> {html.escape(data.get('resourceGroup',''))}</div>
    <div><b>Domain:</b> {html.escape(data.get('domain',''))}</div>
    <div><b>Application Gateway:</b> {html.escape(data.get('appGateway',''))}</div>
    <div><b>Timestamp UTC:</b> {html.escape(data.get('timestampUtc',''))}</div>
  </div>
</div>
<div class="summary">
  <div class="card"><b>PASS</b><br>{data['summary']['pass']}</div>
  <div class="card"><b>WARN</b><br>{data['summary']['warn']}</div>
  <div class="card"><b>FAIL</b><br>{data['summary']['fail']}</div>
</div>
<table>
<thead><tr><th>Section</th><th>Check</th><th>Status</th><th>Details</th></tr></thead>
<tbody>
{''.join(rows)}
</tbody>
</table>
</body>
</html>"""
with open(html_path, 'w', encoding='utf-8') as f:
    f.write(content)
PY

  echo "Reports generated:"
  echo "  HTML: $HTML_FILE"
  echo "  JSON: $JSON_FILE"
  echo "  LOG : $LOG_FILE"
  echo "Overall status: $overall"
}

main() {
  echo "OpenZiti Azure HA Validation Tool"
  echo "Resource Group: $RG"
  echo "Domain: $DOMAIN"
  echo "App Gateway: $APPGW"
  echo "Timestamp UTC: $TIMESTAMP"
  echo

  require_tools
  check_azure_login
  check_vms
  check_appgw
  check_controller_cluster
  check_controller_services
  check_certs
  check_router_services
  check_public_api
  known_notes

  if [[ "$FAILOVER_TEST" == "true" ]]; then
    run_failover_test
  else
    add_result "Failover" "Disruptive failover test" "WARN" "Skipped. Re-run with --failover-test to stop controller01, verify leader election/public API continuity, and restart controller01."
  fi

  finalize_reports
}

main
