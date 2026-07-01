# Controller Failover Test Runbook

This document tests OpenZiti controller failover using Azure CLI.

Set variables:

```bash
RG="<resource-group>"
PUBLIC_DNS="<publicDnsName>"
APPGW="$(az network application-gateway list -g "$RG" --query "[0].name" -o tsv)"
```

---

## 1. Baseline health

```bash
az network application-gateway show-backend-health \
  -g "$RG" \
  -n "$APPGW" \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,healthProbeLog:healthProbeLog}" \
  -o table
```

Expected: 3 healthy controller backends.

---

## 2. Baseline OpenZiti cluster status

```bash
C01="$(az vm list -g "$RG" --query "[?contains(name, 'controller01')].name | [0]" -o tsv)"

az vm run-command invoke \
  -g "$RG" \
  -n "$C01" \
  --command-id RunShellScript \
  --scripts "ziti agent cluster list || true" \
  --query "value[0].message" \
  -o tsv
```

Expected: all 3 controllers connected; exactly one leader.

---

## 3. Stop current leader controller

First identify the leader from the previous output. If controller01 is leader:

```bash
az vm stop -g "$RG" -n "$C01"
```

If another controller is leader, replace `$C01` with that VM name.

---

## 4. Watch Application Gateway backend health

```bash
az network application-gateway show-backend-health \
  -g "$RG" \
  -n "$APPGW" \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,healthProbeLog:healthProbeLog}" \
  -o table
```

Expected:

- stopped controller becomes `Unhealthy`
- the other two remain `Healthy`

---

## 5. Confirm public ZAC/API still works

```bash
curl -k -I "https://${PUBLIC_DNS}/zac/"
curl -k -s "https://${PUBLIC_DNS}/version"
```

Expected: public endpoint still responds.

Browser test:

```text
https://<publicDnsName>/zac/
```

A browser session pinned to the failed controller may need a fresh login. New browser sessions should be routed to a healthy controller.

---

## 6. Confirm new OpenZiti leader

Run cluster status from a healthy controller, for example controller02:

```bash
C02="$(az vm list -g "$RG" --query "[?contains(name, 'controller02')].name | [0]" -o tsv)"

az vm run-command invoke \
  -g "$RG" \
  -n "$C02" \
  --command-id RunShellScript \
  --scripts "ziti agent cluster list || true" \
  --query "value[0].message" \
  -o tsv
```

Expected:

- a new leader is selected
- remaining live controllers are connected

---

## 7. Start failed controller again

```bash
az vm start -g "$RG" -n "$C01"
```

Wait a few minutes, then check backend health again:

```bash
az network application-gateway show-backend-health \
  -g "$RG" \
  -n "$APPGW" \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,healthProbeLog:healthProbeLog}" \
  -o table
```

Expected: all 3 return healthy.

---

## 8. Final OpenZiti HA status

```bash
az vm run-command invoke \
  -g "$RG" \
  -n "$C01" \
  --command-id RunShellScript \
  --scripts "ziti agent cluster list || true" \
  --query "value[0].message" \
  -o tsv
```

Expected:

```text
3 controllers
CONNECTED true for all
one LEADER true
```

---

## Pass Criteria

Controller failover passes when:

- Public ZAC/API remains reachable through the same URL.
- App Gateway removes the failed controller from backend rotation.
- OpenZiti elects/keeps a healthy leader.
- The failed controller rejoins after restart.
