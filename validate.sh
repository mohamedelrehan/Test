#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"

RG=""
DOMAIN=""
APPGW="ziti-ha-appgw"
PRIMARY_CONTROLLER="ziti-ha-controller01"
OUT_DIR="openziti-ha-validation-report"
FAILOVER_TEST="false"

usage() {
  cat <<USAGE
OpenZiti Azure HA Validation Framework

Usage:
  ./validation/validate.sh --resource-group <rg> --domain <fqdn> [options]

Required:
  --resource-group, -g   Azure resource group containing OpenZiti HA deployment
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
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$RG" ]] || die "--resource-group is required"
[[ -n "$DOMAIN" ]] || die "--domain is required"
require_cmd az
require_cmd curl

mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%d-%H%M%S)"
LOG="$OUT_DIR/OpenZiti-HA-Validation-$TS.log"
JSON="$OUT_DIR/OpenZiti-HA-Validation-$TS.json"
HTML="$OUT_DIR/OpenZiti-HA-Validation-$TS.html"
RAW_DIR="$OUT_DIR/raw-$TS"
mkdir -p "$RAW_DIR"

exec > >(tee "$LOG") 2>&1

init_results
section "OpenZiti Azure HA Validation"
echo "Resource Group : $RG"
echo "Domain         : $DOMAIN"
echo "App Gateway    : $APPGW"
echo "Generated UTC  : $(date -u '+%Y-%m-%d %H:%M:%S')"
echo "Output folder  : $OUT_DIR"

source "$LIB_DIR/azure_checks.sh"
source "$LIB_DIR/ziti_checks.sh"
source "$LIB_DIR/html_report.sh"

run_azure_checks "$RG" "$APPGW" "$DOMAIN" "$RAW_DIR"
run_ziti_checks "$RG" "$PRIMARY_CONTROLLER" "$DOMAIN" "$RAW_DIR"

if [[ "$FAILOVER_TEST" == "true" ]]; then
  run_controller_failover_test "$RG" "$PRIMARY_CONTROLLER" "$DOMAIN" "$RAW_DIR"
else
  add_result "WARN" "Controller failover test" "Skipped. Re-run with --failover-test to perform disruptive leader failover validation."
fi

write_json_report "$JSON" "$RG" "$DOMAIN" "$APPGW" "$TS"
write_html_report "$HTML" "$RG" "$DOMAIN" "$APPGW" "$TS" "$JSON" "$LOG"

section "Validation Summary"
print_summary

echo
echo "Reports generated:"
echo "  HTML: $HTML"
echo "  JSON: $JSON"
echo "  LOG : $LOG"
