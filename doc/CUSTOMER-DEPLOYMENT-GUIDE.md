# Customer Deployment Guide

## 1. Upload files to GitHub

Upload all files in this package to your GitHub repository root or a deployment folder.

For repository root:

```text
https://github.com/<org>/<repo>/
```

The `artifactBaseUrl` must be:

```text
https://raw.githubusercontent.com/<org>/<repo>/main
```

For a folder called `deploy`:

```text
https://raw.githubusercontent.com/<org>/<repo>/main/deploy
```

## 2. Prepare DNS

Choose the public ZAC/API DNS name:

```text
ziti.customer.com
```

The customer must later point this DNS record to the Application Gateway public IP or Azure DNS name.

## 3. Choose Key Vault mode

For easiest deployment:

```text
createKeyVault = true
certificateMode = LetsEncryptGoDaddy
```

For enterprise managed certificates:

```text
createKeyVault = false
certificateMode = ExistingKeyVaultCertificate
```

## 4. Deploy

Use the Deploy to Azure button from the README or run:

```bash
az deployment group create \
  -g "<resource-group>" \
  -f azuredeploy.json \
  -p @azuredeploy.parameters.json
```

## 5. Validate

Use these docs in order:

```text
docs/VALIDATION-AZURE-CLI.md
docs/CONTROLLER-FAILOVER-TEST.md
docs/ROUTER-VALIDATION.md
```
