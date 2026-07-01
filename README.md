# OpenZiti Azure HA Reference Architecture

Enterprise-ready Azure reference template for deploying OpenZiti with:

- 3 OpenZiti controllers across availability zones
- 3 OpenZiti routers across availability zones
- Azure Application Gateway for public ZAC/API access
- Azure Key Vault support
- Optional Let's Encrypt DNS-01 certificate issuance using GoDaddy
- Optional existing enterprise Key Vault/certificate mode
- Azure CLI validation and failover runbooks

This template is designed for customer use. It does **not** hardcode a deployment name, domain, resource group, or customer-specific value.

---

## Deploy to Azure

Use this button after the files are uploaded to the GitHub repository root:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmohamedelrehan%2FTest%2Fmain%2Fazuredeploy.json)

If you move the template to another repository or folder, update the encoded `uri` above and set `artifactBaseUrl` to the matching raw GitHub folder.

Example for repository root:

```text
artifactBaseUrl = https://raw.githubusercontent.com/mohamedelrehan/Test/main
```

Example for a `deploy/` folder:

```text
artifactBaseUrl = https://raw.githubusercontent.com/mohamedelrehan/Test/main/deploy
```

---

## Customer Parameters

Minimum values normally changed by the customer:

```text
deploymentPrefix        Short Azure resource prefix, for example ziti-prod
adminUsername           Linux VM admin user
adminPassword           Linux VM admin password used by the bootstrap automation
zitiAdminUser           OpenZiti admin username, default admin
zitiAdminPassword       OpenZiti admin password
publicDnsName           Fully qualified ZAC/API domain, for example ziti.contoso.com
dnsLabelPrefix          Azure public DNS label prefix, for example ziti-contoso
adminSourceAddressPrefix Admin source IP/CIDR allowed to SSH and admin ports
artifactBaseUrl         Raw GitHub URL folder containing the template scripts
```

Important distinction:

```text
publicDnsName  = ziti.contoso.com       # customer domain used by browser/ZAC/API/certificates
dnsLabelPrefix = ziti-contoso           # Azure DNS label only, not a full domain
```

---

## Key Vault Modes

### Mode A — Template creates Key Vault, recommended for first deployment

```text
createKeyVault = true
certificateMode = LetsEncryptGoDaddy
```

The template creates the Key Vault and stores the GoDaddy DNS API credentials as secrets.

### Mode B — Existing enterprise Key Vault, issue certificate using existing GoDaddy secrets

```text
createKeyVault = false
keyVaultResourceGroup = rg-security
keyVaultName = kv-shared-security
certificateMode = LetsEncryptGoDaddy
godaddyApiKeySecretName = existing-secret-name
godaddyApiSecretSecretName = existing-secret-name
```

### Mode C — Existing enterprise Key Vault certificate

```text
createKeyVault = false
keyVaultResourceGroup = rg-security
keyVaultName = kv-shared-security
certificateMode = ExistingKeyVaultCertificate
keyVaultCertificateName = existing-certificate-name
```

---

## DNS Requirement

Create DNS so the public customer name resolves to the Application Gateway public IP or Azure DNS name.

Example:

```text
ziti.contoso.com  ->  Application Gateway public IP
```

For your test:

```text
umbramesh.elrehan.com -> ziti-ha Application Gateway public IP
```

---

## Architecture Note: Public ZAC/API and Private Controller HA

This template intentionally separates public management access from private controller HA traffic:

```text
Public browser/ZAC/API/OIDC:
https://<publicDnsName>/zac/
https://<publicDnsName>/edge/management/v1/...

Private controller HA / raft:
tls:<deploymentPrefix>-controller01:6262
tls:<deploymentPrefix>-controller02:6262
tls:<deploymentPrefix>-controller03:6262
```

Port `6262` should remain private inside the VNet. Do not expose it publicly just to remove a ZAC warning.

The controller config is generated with:

```text
ctrl.advertiseAddress  = internal controller name on 6262
edge.api.address       = publicDnsName on 1280
web.bindPoints.address = publicDnsName on 1280
```

This keeps HA secure while allowing one public customer URL for ZAC/API.

---

## Known ZAC HA Authentication Warning

You may see this message in ZAC:

```text
Found 3 controllers in HA cluster but was unable to authenticate with all of them. Reverting to standard zt-session authentication.
```

In this reference architecture this is documented and acceptable when:

- All controllers are healthy in Azure Application Gateway backend health.
- `ziti agent cluster list` shows all 3 controllers connected.
- ZAC login works through the public URL.
- Controller and router failover tests pass.

Reason: ZAC discovers the 3-controller HA cluster, but the controller cluster addresses are private internal `6262` addresses. The public browser path is intentionally through Application Gateway only. Exposing `6262` publicly would add attack surface and customer allowlist complexity. Therefore this template keeps `6262` private and documents the warning as expected/cosmetic for this secure public-one-URL design.

See [`docs/ZAC-HA-WARNING.md`](docs/ZAC-HA-WARNING.md).

---

## Validation and Failover Documents

Start here after deployment:

1. [`docs/VALIDATION-AZURE-CLI.md`](docs/VALIDATION-AZURE-CLI.md)
2. [`docs/CONTROLLER-FAILOVER-TEST.md`](docs/CONTROLLER-FAILOVER-TEST.md)
3. [`docs/ROUTER-VALIDATION.md`](docs/ROUTER-VALIDATION.md)
4. [`docs/ZAC-HA-WARNING.md`](docs/ZAC-HA-WARNING.md)
5. [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

---

## Fast Deployment Command

```bash
RG="rg-ziti-ha-test"
LOCATION="denmarkeast"

az group create -n "$RG" -l "$LOCATION"

az deployment group create \
  -g "$RG" \
  -f azuredeploy.json \
  -p @azuredeploy.parameters.json
```

---

## Fast Health Check

```bash
RG="<resource-group>"
APPGW="$(az network application-gateway list -g "$RG" --query "[0].name" -o tsv)"

az network application-gateway show-backend-health \
  -g "$RG" \
  -n "$APPGW" \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,healthProbeLog:healthProbeLog}" \
  -o table
```

Expected:

```text
Health
-------
Healthy
Healthy
Healthy
```
