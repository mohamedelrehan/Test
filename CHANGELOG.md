
## 2026-07-01 - DNS-independent bootstrap and public port fix

- Fixed router enrollment failure caused by JWTs pointing to `publicDnsName:1280` while Application Gateway exposes only public 443.
- Router enrollment now uses controller01 internal endpoint during deployment, so customer DNS does not need to be updated before provisioning completes.
- Final controller ZAC/API/OIDC advertised address now uses `<publicDnsName>:443`.
- Backend controller service remains on 1280 behind Application Gateway.
- Controller HA/raft `6262` remains private/internal and is not exposed publicly.
- Documentation updated for DNS cutover, ZAC HA warning, validation, and troubleshooting.

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
