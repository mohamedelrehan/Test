# Troubleshooting

## ZAC asks for username/password again after successful login

Check Application Gateway HTTP settings:

```bash
az network application-gateway http-settings list \
  -g "$RG" \
  --gateway-name "$APPGW" \
  --query "[].{Name:name,CookieAffinity:cookieBasedAffinity,HostName:hostName,Port:port,Protocol:protocol}" \
  -o table
```

Expected:

```text
CookieAffinity = Enabled
```

Fix live deployment:

```bash
az network application-gateway http-settings update \
  -g "$RG" \
  --gateway-name "$APPGW" \
  -n "<http-setting-name>" \
  --cookie-based-affinity Enabled
```

---

## ZAC/API advertises internal controller names

Check controller config:

```bash
for VM in ziti-ha-controller01 ziti-ha-controller02 ziti-ha-controller03; do
  az vm run-command invoke \
    -g "$RG" \
    -n "$VM" \
    --command-id RunShellScript \
    --scripts "hostname; grep -nE 'advertiseAddress|address:' /var/lib/ziti-controller/config.yml | head -80" \
    --query "value[0].message" \
    -o tsv
done
```

Correct pattern:

```text
advertiseAddress: tls:<controller-name>:6262
address: <publicDnsName>:1280
address: <publicDnsName>:1280
```

Live test fix:

```bash
for VM in ziti-ha-controller01 ziti-ha-controller02 ziti-ha-controller03; do
  az vm run-command invoke \
    -g "$RG" \
    -n "$VM" \
    --command-id RunShellScript \
    --scripts "sudo sed -i -E 's/address: [A-Za-z0-9.-]+-controller[0-9][0-9]:1280/address: ${PUBLIC_DNS}:1280/g' /var/lib/ziti-controller/config.yml && sudo systemctl restart ziti-controller && sleep 8 && systemctl is-active ziti-controller && grep -nE 'advertiseAddress|address:' /var/lib/ziti-controller/config.yml | head -80" \
    --query "value[0].message" \
    -o tsv
done
```

Do not change `ctrl.advertiseAddress`; it must remain internal on port `6262`.

---

## Certificate SAN does not include public DNS name

Check:

```bash
for VM in ziti-ha-controller01 ziti-ha-controller02 ziti-ha-controller03; do
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

If missing, redeploy or regenerate controller certs with `publicDnsName` in SAN.

---

## Application Gateway backend is unhealthy

Check backend health:

```bash
az network application-gateway show-backend-health \
  -g "$RG" \
  -n "$APPGW" \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,healthProbeLog:healthProbeLog}" \
  -o table
```

Then check controller service:

```bash
az vm run-command invoke \
  -g "$RG" \
  -n "<controller-vm>" \
  --command-id RunShellScript \
  --scripts "systemctl status ziti-controller --no-pager | head -100; curl -k -I https://127.0.0.1:1280/version" \
  --query "value[0].message" \
  -o tsv
```

---

## OpenZiti cluster not connected

Run:

```bash
az vm run-command invoke \
  -g "$RG" \
  -n "<controller-vm>" \
  --command-id RunShellScript \
  --scripts "ziti agent cluster list || true" \
  --query "value[0].message" \
  -o tsv
```

Expected: all controllers `CONNECTED true`.
