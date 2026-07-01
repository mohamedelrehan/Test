# OpenZiti Azure HA Validation Runbook

This runbook validates the Azure deployment, Application Gateway, controllers, and public ZAC/API path.

Set your variables first:

```bash
RG="<resource-group>"
PUBLIC_DNS="<publicDnsName>"
```

Example:

```bash
RG="openziti2"
PUBLIC_DNS="umbramesh.elrehan.com"
```

---

## 1. List deployed VMs

```bash
az vm list \
  -g "$RG" \
  --query "[].{Name:name,Power:powerState,Zone:zones[0]}" \
  -o table
```

Expected:

```text
controller01
controller02
controller03
router01
router02
router03
```

---

## 2. Find Application Gateway

```bash
APPGW="$(az network application-gateway list -g "$RG" --query "[0].name" -o tsv)"
echo "$APPGW"
```

---

## 3. Validate backend HTTP settings

```bash
az network application-gateway http-settings list \
  -g "$RG" \
  --gateway-name "$APPGW" \
  --query "[].{Name:name,Port:port,Protocol:protocol,HostName:hostName,CookieAffinity:cookieBasedAffinity,ValidateSNI:validateSNI,ValidateCert:validateCertChainAndExpiry}" \
  -o table
```

Expected:

```text
Port       1280 (backend HTTP setting only; public frontend is 443)
Protocol   Https
HostName   <publicDnsName>
CookieAffinity Enabled
```

Cookie affinity is required because ZAC password login creates a controller-local browser session. Without affinity, login can hit one controller and later API calls can hit another controller, causing a login loop.

---

## 4. Validate backend health

```bash
az network application-gateway show-backend-health \
  -g "$RG" \
  -n "$APPGW" \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,healthProbeLog:healthProbeLog}" \
  -o table
```

Expected:

```text
Health    HealthProbeLog
--------  ---------------------------------
Healthy   Success. Received 200 status code
Healthy   Success. Received 200 status code
Healthy   Success. Received 200 status code
```

---

## 5. Validate public ZAC/API endpoint

From your local machine or Azure Cloud Shell:

```bash
curl -k -I "https://${PUBLIC_DNS}/zac/"
curl -k -s "https://${PUBLIC_DNS}/version"
```

Expected:

- `/zac/` returns HTTP `200` or valid redirect/static response.
- `/version` returns OpenZiti version JSON.

---

## 6. Validate controller services

```bash
for VM in $(az vm list -g "$RG" --query "[?contains(name, 'controller')].name" -o tsv); do
  echo "===== $VM ====="
  az vm run-command invoke \
    -g "$RG" \
    -n "$VM" \
    --command-id RunShellScript \
    --scripts "hostname; systemctl is-active ziti-controller; grep -nE 'advertiseAddress|address:' /var/lib/ziti-controller/config.yml | head -80" \
    --query "value[0].message" \
    -o tsv
 done
```

Expected pattern:

```text
advertiseAddress: tls:<controller-name>:6262
address: <publicDnsName>:443
address: <publicDnsName>:443
```

---

## 7. Validate OpenZiti HA cluster

Run on controller01:

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

Expected:

```text
3 controllers
VOTER true for all
CONNECTED true for all
one LEADER true
```

---

## 8. Validate certificates include public DNS SAN

```bash
for VM in $(az vm list -g "$RG" --query "[?contains(name, 'controller')].name" -o tsv); do
  echo "===== $VM ====="
  az vm run-command invoke \
    -g "$RG" \
    -n "$VM" \
    --command-id RunShellScript \
    --scripts "CERT=\$(ls /var/lib/ziti-controller/*.server.chain.cert | head -1); openssl x509 -in \$CERT -noout -subject -ext subjectAltName" \
    --query "value[0].message" \
    -o tsv
 done
```

Expected:

```text
DNS:<publicDnsName>
```

---

## 9. ZAC browser validation

Open a private/incognito browser window:

```text
https://<publicDnsName>/zac/
```

Validate:

- Login succeeds.
- It does not loop back to login.
- Controllers/routers/entities are visible.

The documented HA-auth warning may appear. See `ZAC-HA-WARNING.md`.


## Validate public frontend and backend split

```bash
az network application-gateway frontend-port list -g "$RG" --gateway-name "$APPGW" -o table
az network application-gateway http-settings list -g "$RG" --gateway-name "$APPGW" --query "[].{Name:name,Port:port,Protocol:protocol,HostName:hostName,CookieAffinity:cookieBasedAffinity}" -o table
```

Expected:

```text
Frontend public port: 443
Backend setting port: 1280
Cookie affinity: Enabled
```
