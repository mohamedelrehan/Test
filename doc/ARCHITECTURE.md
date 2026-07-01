# Architecture

## Logical Design

```text
Internet
  |
  v
Customer DNS: <publicDnsName>
  |
  v
Azure Application Gateway
  |-- HTTPS backend 1280 -> controller01
  |-- HTTPS backend 1280 -> controller02
  |-- HTTPS backend 1280 -> controller03

Private VNet controller HA:
controller01 <-> controller02 <-> controller03 on 6262

Routers:
router01, router02, router03 enrolled to OpenZiti fabric
```

## Public Endpoint

Customers use one URL:

```text
https://<publicDnsName>/zac/
```

This is intentionally stable even if controller01 fails.

## Private HA Endpoint

The controllers use internal names on port 6262:

```text
tls:<deploymentPrefix>-controller01:6262
tls:<deploymentPrefix>-controller02:6262
tls:<deploymentPrefix>-controller03:6262
```

This must remain private.

## Why Application Gateway cookie affinity is enabled

ZAC password authentication creates a browser session. If the login request goes to controller01 and the next API request goes to controller02, ZAC may return to the login page. Cookie affinity keeps a browser session on the same healthy backend controller.

If that controller fails, the current browser session may need a new login, but new sessions go to a healthy controller.

## Availability Zones

The template places controllers and routers across zones where the selected Azure region supports zones. This reduces single-zone failure risk.

## Certificate Model

Controller server certificates include:

```text
DNS:<controller-name>
DNS:<controller Azure FQDN>
DNS:<publicDnsName>
IP:127.0.0.1
```

The public Application Gateway certificate is either issued by Let's Encrypt or loaded from an existing Key Vault certificate.
