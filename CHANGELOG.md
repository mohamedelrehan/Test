# Changelog

## Enterprise HA Reference Package

- Generic customer-ready ARM template.
- Added Azure Deploy button support in README.
- Added Key Vault create/reuse modes.
- Added Let's Encrypt GoDaddy DNS-01 and existing certificate modes.
- Application Gateway backend includes all 3 controllers.
- Application Gateway cookie-based affinity enabled to prevent ZAC login loop.
- Controller `ctrl.advertiseAddress` remains private/internal on port 6262.
- Controller ZAC/API/OIDC addresses use the customer `publicDnsName` on port 1280.
- Controller certificates include customer `publicDnsName` as SAN.
- Added enterprise runbooks for Azure CLI validation, controller failover, router validation, and troubleshooting.
- Documented ZAC HA authentication warning as expected/cosmetic for secure one-public-URL design with private controller HA.
