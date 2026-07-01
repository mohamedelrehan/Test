# OpenZiti Azure HA Reference - Enterprise Generic Template

This package deploys a generic 3-controller / 3-router OpenZiti HA reference architecture on Azure.

## What changed in this enterprise test build

- No hardcoded customer domain or deployment name.
- One public ZAC/API endpoint through Azure Application Gateway:
  `https://<publicDnsName>/zac/`
- Application Gateway backend pool includes all 3 controllers.
- Backend host header uses the shared public DNS name.
- Controller certificates include the shared public DNS name as SAN.
- Key Vault is now dependency-aware:
  - default: create a new Key Vault in the deployment resource group;
  - enterprise mode: reuse an existing Key Vault;
  - certificate mode can either issue with Let's Encrypt + GoDaddy DNS-01 or use an existing Key Vault certificate.

## Recommended test mode

Use the default enterprise self-contained mode:

```text
createKeyVault = true
certificateMode = LetsEncryptGoDaddy
enableEnterpriseHttps = true
publicDnsName = ziti.your-domain.com
acmeServer = letsencrypt_test
```

For the first test, keep `acmeServer = letsencrypt_test`. After validation, change it to `letsencrypt` for a trusted production certificate.

## Required customer inputs

Minimum values to change before deployment:

```text
deploymentPrefix
adminUsername
adminPassword
zitiAdminPassword
dnsLabelPrefix
publicDnsName
letsEncryptEmail
keyVaultName
godaddyApiKey
godaddyApiSecret
artifactBaseUrl
```

`keyVaultName` must be globally unique in Azure.

## Key Vault modes

### Mode A - Template creates Key Vault, recommended default

```text
createKeyVault = true
keyVaultResourceGroup = ""
certificateMode = LetsEncryptGoDaddy
```

The template creates the Key Vault, stores the GoDaddy API secrets, issues the ACME certificate, imports it into Key Vault, grants Application Gateway access, and configures HTTPS.

### Mode B - Existing enterprise Key Vault, issue certificate using existing GoDaddy secrets

```text
createKeyVault = false
keyVaultResourceGroup = existing-security-rg
keyVaultName = existing-kv-name
certificateMode = LetsEncryptGoDaddy
godaddyApiKeySecretName = existing-secret-name
godaddyApiSecretSecretName = existing-secret-name
```

The existing Key Vault must already contain the GoDaddy API key and API secret.

### Mode C - Existing enterprise Key Vault certificate

```text
createKeyVault = false
keyVaultResourceGroup = existing-security-rg
keyVaultName = existing-kv-name
certificateMode = ExistingKeyVaultCertificate
keyVaultCertificateName = existing-certificate-secret-name
```

The certificate must already exist in Key Vault and be usable by Application Gateway.

## Deployment command

```bash
az group create -n rg-ziti-ha-test -l westeurope

az deployment group create \
  -g rg-ziti-ha-test \
  -f azuredeploy.json \
  -p @azuredeploy.parameters.json
```

## DNS requirement

Before testing browser access, point your public DNS record to the Application Gateway public IP:

```text
ziti.your-domain.com -> Application Gateway public IP
```

For GoDaddy DNS-01, the domain must be managed in GoDaddy and the API credentials must be valid.

## Expected HA behavior

After successful deployment:

```text
https://<publicDnsName>/zac/
```

should load ZAC through Application Gateway. If controller01 fails, Application Gateway health probes should remove it and send traffic to controller02 or controller03.

The ZAC message below should disappear when all 3 controllers are healthy and the shared public hostname/certificate path is accepted by every controller:

```text
Found 3 controllers in HA cluster but was unable to authenticate with all of them. Reverting to standard zt-session authentication.
```

If it still appears, check these first:

```bash
curl -k https://<publicDnsName>/version
curl -k https://<publicDnsName>/zac/
```

Then verify each controller directly from inside the VNet:

```bash
curl -k --resolve <publicDnsName>:1280:<controller01-private-ip> https://<publicDnsName>:1280/version
curl -k --resolve <publicDnsName>:1280:<controller02-private-ip> https://<publicDnsName>:1280/version
curl -k --resolve <publicDnsName>:1280:<controller03-private-ip> https://<publicDnsName>:1280/version
```

## Important validation notes

This template is designed for testing the enterprise HA path. Validate in this order:

1. Azure deployment succeeds.
2. Key Vault exists and certificate secret exists.
3. Application Gateway backend health shows all 3 controllers healthy.
4. ZAC opens from the public URL.
5. ZAC no longer shows the HA authentication warning.
6. Stop controller01 and confirm ZAC still opens through the same public URL.
7. Restart controller01 and confirm backend health returns to 3 healthy controllers.

