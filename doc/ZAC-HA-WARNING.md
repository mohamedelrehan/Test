# ZAC HA Authentication Warning

## Warning

ZAC may show:

```text
Found 3 controllers in HA cluster but was unable to authenticate with all of them. Reverting to standard zt-session authentication.
```

## Is this a deployment failure?

Not necessarily.

In this Azure reference architecture, public browser management uses one shared public URL:

```text
https://<publicDnsName>/zac/
```

The 3-controller HA cluster uses private controller addresses:

```text
tls:<controller01>:6262
tls:<controller02>:6262
tls:<controller03>:6262
```

ZAC can discover that there are 3 controllers. However, it may not be able to authenticate directly with every private controller cluster address from the browser path. In that case, it falls back to standard `zt-session` authentication.

## Why not expose port 6262 publicly?

Port `6262` is the controller-to-controller HA/raft/fabric control plane. Exposing it publicly only to suppress the ZAC warning is not recommended because it adds:

- More attack surface
- More customer firewall/ACL complexity
- Public dependency on controller cluster internals
- No benefit for normal ZAC/API administration

Enterprise default should be:

```text
Public:  443 through Application Gateway to ZAC/API; backend 1280 to controllers
Private: 6262 inside VNet only for controller HA
```

## When is the warning acceptable?

The warning is acceptable when all of these are true:

```text
Application Gateway backend health = 3 healthy controllers
ziti agent cluster list = 3 controllers connected
ZAC login works through https://<publicDnsName>/zac/
Controller failover test passes
Router validation passes
```

## What is not acceptable?

The warning is not the same as a login loop.

A login loop looks like:

```text
POST /edge/management/v1/authenticate?method=password succeeds
GET /edge/management/v1/... returns 401
ZAC asks for username/password again
```

That is usually caused by Application Gateway sending browser session requests to different controllers. This template enables cookie-based affinity to prevent that.

## How to confirm the secure design

Check controller config:

```bash
for VM in ziti-ha-controller01 ziti-ha-controller02 ziti-ha-controller03; do
  az vm run-command invoke \
    -g "$RG" \
    -n "$VM" \
    --command-id RunShellScript \
    --scripts "grep -nE 'advertiseAddress|address:' /var/lib/ziti-controller/config.yml | head -80" \
    --query "value[0].message" \
    -o tsv
done
```

Expected:

```text
advertiseAddress: tls:<controller-name>:6262
address: <publicDnsName>:443
address: <publicDnsName>:443
```

This is the intended balance of secure private HA plus public one-URL administration.
