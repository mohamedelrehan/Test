# Router Validation and Failover Runbook

This document validates the 3-router layer after deployment.

Set variables:

```bash
RG="<resource-group>"
PUBLIC_DNS="<publicDnsName>"
```

---

## 1. List router VMs

```bash
az vm list \
  -g "$RG" \
  --query "[?contains(name, 'router')].{Name:name,Power:powerState,Zone:zones[0]}" \
  -o table
```

Expected: 3 router VMs.

---

## 2. Check router service status

```bash
for VM in $(az vm list -g "$RG" --query "[?contains(name, 'router')].name" -o tsv); do
  echo "===== $VM ====="
  az vm run-command invoke \
    -g "$RG" \
    -n "$VM" \
    --command-id RunShellScript \
    --scripts "hostname; systemctl is-active ziti-router || systemctl is-active ziti-edge-router || true; systemctl status ziti-router ziti-edge-router --no-pager | head -80 || true" \
    --query "value[0].message" \
    -o tsv
 done
```

Expected: router service active. The service name can vary by OpenZiti package/version.

---

## 3. Check routers from Ziti CLI

Run from controller01:

```bash
C01="$(az vm list -g "$RG" --query "[?contains(name, 'controller01')].name | [0]" -o tsv)"

az vm run-command invoke \
  -g "$RG" \
  -n "$C01" \
  --command-id RunShellScript \
  --scripts "ziti edge login https://127.0.0.1:1280 -u admin -p '<zitiAdminPassword>' -y >/dev/null 2>&1 || true; ziti edge list edge-routers || true" \
  --query "value[0].message" \
  -o tsv
```

Replace `<zitiAdminPassword>` with the password used during deployment.

Expected: 3 edge routers appear and are online/connected.

---

## 4. Router failover test

Stop one router:

```bash
R01="$(az vm list -g "$RG" --query "[?contains(name, 'router01')].name | [0]" -o tsv)"
az vm stop -g "$RG" -n "$R01"
```

Check remaining routers:

```bash
az vm list \
  -g "$RG" \
  --query "[?contains(name, 'router')].{Name:name,Power:powerState}" \
  -o table
```

Then from Ziti CLI:

```bash
az vm run-command invoke \
  -g "$RG" \
  -n "$C01" \
  --command-id RunShellScript \
  --scripts "ziti edge list edge-routers || true" \
  --query "value[0].message" \
  -o tsv
```

Expected: stopped router becomes unavailable; remaining routers stay available.

---

## 5. Start router again

```bash
az vm start -g "$RG" -n "$R01"
```

Wait a few minutes and validate again:

```bash
az vm run-command invoke \
  -g "$RG" \
  -n "$C01" \
  --command-id RunShellScript \
  --scripts "ziti edge list edge-routers || true" \
  --query "value[0].message" \
  -o tsv
```

Expected: router rejoins.

---

## Notes

Router failover depends on service/policy design. If a service is only reachable through one router path, stopping that router can affect that specific service. For high availability, design hosted services and router policies so multiple routers can carry the traffic.
