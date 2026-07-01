#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-controller-primary-v4.log) 2>&1
ADMIN_USER="${1:?admin user missing}"
ADMIN_PASS="$(printf '%s' "${2:?admin password b64 missing}" | base64 -d)"
ZITI_USER="${3:-admin}"
ZITI_PWD="$(printf '%s' "${4:?ziti password b64 missing}" | base64 -d)"
PREFIX="${5:?prefix missing}"
C01_HOST="${6:?controller01 name missing}"
C02_HOST="${7:?controller02 name missing}"
C03_HOST="${8:?controller03 name missing}"
R01_HOST="${9:?router01 name missing}"
R02_HOST="${10:?router02 name missing}"
R03_HOST="${11:?router03 name missing}"
C01_PUB_FQDN="${12:-}"
C02_PUB_FQDN="${13:-}"
C03_PUB_FQDN="${14:-}"
R01_PUB_FQDN="${15:-}"
R02_PUB_FQDN="${16:-}"
R03_PUB_FQDN="${17:-}"
RUN_APT_UPGRADE="${18:-false}"
PUBLIC_DNS_NAME="${19:-}"
log(){ echo "[$(date -Is)] $*"; }
fail(){ echo "[ERROR] $*"; exit 1; }
wait_for(){ local name="$1"; local cmd="$2"; local retries="${3:-60}"; local sleep_s="${4:-5}"; for i in $(seq 1 "$retries"); do if bash -lc "$cmd"; then log "$name ready"; return 0; fi; sleep "$sleep_s"; done; fail "$name not ready"; }
ssh_base(){ sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$ADMIN_USER@$1" "$2"; }
scp_to(){ sshpass -p "$ADMIN_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$1" "$ADMIN_USER@$2:$3"; }
install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if [[ "$RUN_APT_UPGRADE" == "true" ]]; then apt-get upgrade -y; fi
  apt-get install -y curl gpg ca-certificates jq dnsutils iproute2 openssl sed sshpass netcat-openbsd
  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg
  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" > /etc/apt/sources.list.d/openziti-release.list
  apt-get update
  apt-get install -y openziti openziti-controller openziti-console
}
create_controller_config(){
  mkdir -p /var/lib/ziti-controller/cluster /opt/ziti-ha
  cd /var/lib/ziti-controller
  rm -f config.yml
  ziti create config controller --ctrlPort 6262 --routerEnrollmentDuration 3h --identityEnrollmentDuration 3h --output /var/lib/ziti-controller/config.yml
  sed -i "s/localhost/${C01_HOST}/g" config.yml
  # Public ZAC/API/OIDC must advertise the customer public DNS name so browser clients
  # use the Application Gateway URL. Keep ctrl.advertiseAddress internal on port 6262
  # for controller-to-controller HA/raft traffic.
  if [[ -n "${PUBLIC_DNS_NAME}" ]]; then
    sed -i -E "s/address: ${C01_HOST}:1280/address: ${PUBLIC_DNS_NAME}:443/g" config.yml
  fi
  if ! grep -qE '^cluster:' config.yml; then
    cat >> config.yml <<EOF

cluster:
  dataDir: /var/lib/ziti-controller/cluster
EOF
  fi
  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
  chmod -R u=rwX,g=rwX,o= /var/lib/ziti-controller
}
enable_zac_spa(){
  cd /var/lib/ziti-controller

  # ZAC SPA is served by the controller on backend port 1280.
  # Public clients access it through Application Gateway on 443.

  # Enable ZAC static SPA serving from the real package install path.
  # This fixes /zac/ 404 and prevents JS chunks/assets (for example lottie-web)
  # from falling through to edge-client and being returned as JSON/HTML.
  if [[ -d /opt/openziti/share/console ]]; then
    if ! grep -qE "^[[:space:]]*-[[:space:]]*binding:[[:space:]]*spa" config.yml; then
      sed -i '/^[[:space:]]*#- binding: spa/,+4c\      - binding: spa\n        options:\n          path: zac\n          location: /opt/openziti/share/console\n          indexFile: index.html' config.yml
    else
      sed -i -E '/binding:[[:space:]]*spa/,/indexFile:/ s|^[[:space:]]*location:.*|          location: /opt/openziti/share/console|' config.yml
      sed -i -E '/binding:[[:space:]]*spa/,/indexFile:/ s|^[[:space:]]*path:.*|          path: zac|' config.yml
    fi
  fi

  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
}

create_pki_for_controller01(){
  sudo -u ziti-controller bash -lc "
set -e
cd /var/lib/ziti-controller
mkdir -p pki
ziti pki create ca --pki-root /var/lib/ziti-controller/pki --ca-file ca --ca-name '${PREFIX} Root CA' --trust-domain '${PREFIX}'
ziti pki create intermediate --pki-root /var/lib/ziti-controller/pki --ca-name ca --intermediate-file intermediate --intermediate-name '${PREFIX} Intermediate CA'
ziti pki create key --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --key-file ${C01_HOST}
ziti pki create server --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --server-file ${C01_HOST}.server --server-name ${C01_HOST} --key-file ${C01_HOST} --dns ${C01_HOST} ${C01_PUB_FQDN:+--dns ${C01_PUB_FQDN}} ${PUBLIC_DNS_NAME:+--dns ${PUBLIC_DNS_NAME}} --ip 127.0.0.1 --spiffe-id /controller/${C01_HOST} --allow-overwrite
ziti pki create client --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --client-file ${C01_HOST}.client --client-name ${C01_HOST} --key-file ${C01_HOST} --spiffe-id /controller/${C01_HOST} --allow-overwrite
cp pki/intermediate/keys/${C01_HOST}.key ./${C01_HOST}.key
cp pki/intermediate/certs/${C01_HOST}.client.chain.pem ./${C01_HOST}client.chain.cert
cp pki/intermediate/certs/${C01_HOST}.server.chain.pem ./${C01_HOST}.server.chain.cert
cp pki/intermediate/certs/intermediate.chain.pem ./${C01_HOST}.ca
cp pki/intermediate/certs/intermediate.cert ./${C01_HOST}.signing.cert
cp pki/intermediate/keys/intermediate.key ./${C01_HOST}.signing.key
chmod 640 /var/lib/ziti-controller/${C01_HOST}*
"
  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
  chmod 750 /var/lib/ziti-controller
}
start_and_init(){
  systemctl daemon-reload || true
  systemctl enable ziti-controller
  systemctl restart ziti-controller
  wait_for controller01-api "curl -kfsS https://127.0.0.1:1280/version >/dev/null" 90 5
  sudo -u ziti-controller ziti agent cluster init "$ZITI_USER" "$ZITI_PWD" "$C01_HOST" --timeout 60s || true
}
ship_and_finalize_secondaries(){
  tar -czf /tmp/${PREFIX}-shared-pki.tgz -C /var/lib/ziti-controller pki
  chown "$ADMIN_USER:$ADMIN_USER" /tmp/${PREFIX}-shared-pki.tgz || true
  for host in "$C02_HOST" "$C03_HOST"; do wait_for ${host}-ssh "nc -z $host 22" 120 5; scp_to /tmp/${PREFIX}-shared-pki.tgz "$host" /tmp/${PREFIX}-shared-pki.tgz; done
  wait_for ${C02_HOST}-finalize "sshpass -p '$ADMIN_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $ADMIN_USER@$C02_HOST test -x /opt/ziti-ha/finalize-secondary-controller-v4.sh" 120 5
  ssh_base "$C02_HOST" "sudo /opt/ziti-ha/finalize-secondary-controller-v4.sh '$C02_HOST' '$C02_PUB_FQDN' '/tmp/${PREFIX}-shared-pki.tgz' '$C01_HOST' '$C02_HOST' '$PUBLIC_DNS_NAME'"
  wait_for ${C03_HOST}-finalize "sshpass -p '$ADMIN_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $ADMIN_USER@$C03_HOST test -x /opt/ziti-ha/finalize-secondary-controller-v4.sh" 120 5
  ssh_base "$C03_HOST" "sudo /opt/ziti-ha/finalize-secondary-controller-v4.sh '$C03_HOST' '$C03_PUB_FQDN' '/tmp/${PREFIX}-shared-pki.tgz' '$C01_HOST' '$C02_HOST' '$PUBLIC_DNS_NAME'"
}
add_controllers(){
  wait_for controller02-api "curl -kfsS https://${C02_HOST}:1280/version >/dev/null" 90 5
  wait_for controller03-api "curl -kfsS https://${C03_HOST}:1280/version >/dev/null" 90 5
  sudo -u ziti-controller ziti agent cluster add "tls:${C02_HOST}:6262" --timeout 60s --voter || true
  sudo -u ziti-controller ziti agent cluster add "tls:${C03_HOST}:6262" --timeout 60s --voter || true
  sudo -u ziti-controller ziti agent cluster list --timeout 60s || true
}
install_preferred_leader_watchdog(){
  local preferred_id="$1"
  local primary_id="$2"
  local mode="$3"
  cat > /usr/local/bin/ziti-preferred-leader-watchdog.sh <<EOS
#!/usr/bin/env bash
set -Eeuo pipefail
PREFERRED_ID="$preferred_id"
PRIMARY_ID="$primary_id"
MODE="$mode"
LOG_FILE="/var/log/ziti-ha-preferred-leader-watchdog.log"
now(){ date -Is; }
trim_field(){ awk -F'│' -v idx="\$1" '{gsub(/^[ \\t]+|[ \\t]+$/, "", \$idx); print \$idx;}'; }
get_row(){ printf '%s\n' "\$CLUSTER_LIST" | grep "│[[:space:]]*\$1[[:space:]]*│" | head -1 || true; }
CLUSTER_LIST="\$(ziti agent cluster list --timeout 30s 2>/dev/null || true)"
[[ -n "\$CLUSTER_LIST" ]] || { echo "\$(now) cluster list empty" >> "\$LOG_FILE"; exit 0; }
PREF_ROW="\$(get_row "\$PREFERRED_ID")"
[[ -n "\$PREF_ROW" ]] || { echo "\$(now) preferred row not found: \$PREFERRED_ID" >> "\$LOG_FILE"; exit 0; }
PREF_LEADER="\$(printf '%s\n' "\$PREF_ROW" | trim_field 5)"
PREF_CONNECTED="\$(printf '%s\n' "\$PREF_ROW" | trim_field 7)"
[[ "\$PREF_CONNECTED" == "true" ]] || { echo "\$(now) preferred not connected: \$PREFERRED_ID" >> "\$LOG_FILE"; exit 0; }
if [[ "\$MODE" == "fallback" ]]; then
  PRIMARY_ROW="\$(get_row "\$PRIMARY_ID")"
  PRIMARY_CONNECTED="\$(printf '%s\n' "\$PRIMARY_ROW" | trim_field 7)"
  if [[ "\$PRIMARY_CONNECTED" == "true" ]]; then
    echo "\$(now) primary is connected; fallback will not take leadership: primary=\$PRIMARY_ID" >> "\$LOG_FILE"
    exit 0
  fi
fi
if [[ "\$PREF_LEADER" == "true" ]]; then
  echo "\$(now) preferred already leader: \$PREFERRED_ID" >> "\$LOG_FILE"
  exit 0
fi
echo "\$(now) transferring leadership to \$PREFERRED_ID mode=\$MODE" >> "\$LOG_FILE"
ziti agent cluster transfer-leadership "\$PREFERRED_ID" --timeout 30s >> "\$LOG_FILE" 2>&1 || true
EOS
  chmod +x /usr/local/bin/ziti-preferred-leader-watchdog.sh

  # Ensure watchdog log is writable by the service user before the timer/service starts.
  touch /var/log/ziti-ha-preferred-leader-watchdog.log
  chown ziti-controller:ziti-controller /var/log/ziti-ha-preferred-leader-watchdog.log
  chmod 664 /var/log/ziti-ha-preferred-leader-watchdog.log
  cat > /etc/systemd/system/ziti-preferred-leader-watchdog.service <<'EOS'
[Unit]
Description=OpenZiti preferred leader watchdog
After=ziti-controller.service
Wants=ziti-controller.service

[Service]
Type=oneshot
User=ziti-controller
ExecStart=/usr/local/bin/ziti-preferred-leader-watchdog.sh
EOS
  cat > /etc/systemd/system/ziti-preferred-leader-watchdog.timer <<'EOS'
[Unit]
Description=Run OpenZiti preferred leader watchdog periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
Unit=ziti-preferred-leader-watchdog.service

[Install]
WantedBy=timers.target
EOS
  systemctl daemon-reload
  systemctl enable --now ziti-preferred-leader-watchdog.timer
  /usr/local/bin/ziti-preferred-leader-watchdog.sh || true
}


set_local_edge_address(){
  local host="$1"
  cd /var/lib/ziti-controller
  # Bootstrap-only setting: router enrollment must not depend on customer DNS.
  # The router JWT generated in this phase points to the internal controller name
  # reachable from router subnet, while cert SAN already contains the controller name.
  sed -i -E "s/address: [A-Za-z0-9_.-]+:(443|1280)/address: ${host}:1280/g" config.yml
  chown ziti-controller:ziti-controller config.yml
  systemctl restart ziti-controller
  wait_for ${host}-local-edge "curl -kfsS https://127.0.0.1:1280/version >/dev/null" 60 5
}

set_public_edge_address_local(){
  [[ -n "${PUBLIC_DNS_NAME}" ]] || return 0
  cd /var/lib/ziti-controller
  # Final production setting: browser/ZAC/API/OIDC advertise the customer FQDN on 443.
  # Backend remains 1280 behind Application Gateway. Do not alter ctrl.advertiseAddress:6262.
  sed -i -E "s/address: [A-Za-z0-9_.-]+:(443|1280)/address: ${PUBLIC_DNS_NAME}:443/g" config.yml
  chown ziti-controller:ziti-controller config.yml
  systemctl restart ziti-controller
  wait_for public-edge-local "curl -kfsS https://127.0.0.1:1280/version >/dev/null" 60 5
}

set_public_edge_address_remote(){
  local host="$1"
  [[ -n "${PUBLIC_DNS_NAME}" ]] || return 0
  ssh_base "$host" "sudo sed -i -E 's/address: [A-Za-z0-9_.-]+:(443|1280)/address: ${PUBLIC_DNS_NAME}:443/g' /var/lib/ziti-controller/config.yml && sudo chown ziti-controller:ziti-controller /var/lib/ziti-controller/config.yml && sudo systemctl restart ziti-controller"
}

finalize_public_edge_addresses(){
  set_public_edge_address_local
  set_public_edge_address_remote "$C02_HOST"
  set_public_edge_address_remote "$C03_HOST"
}

create_router_jwt_and_finalize(){
  local router="$1"
  ziti edge login https://127.0.0.1:1280 -u "$ZITI_USER" -p "$ZITI_PWD" -y || true
  rm -f /tmp/${router}.jwt
  ziti edge create edge-router "$router" -o /tmp/${router}.jwt || true
  [[ -s /tmp/${router}.jwt ]] || fail "JWT not created for $router"
  scp_to /tmp/${router}.jwt "$router" /tmp/${router}.jwt
  wait_for ${router}-finalize "sshpass -p '$ADMIN_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $ADMIN_USER@$router test -x /opt/ziti-ha/finalize-router-v4.sh" 120 5
  ssh_base "$router" "sudo /opt/ziti-ha/finalize-router-v4.sh '$router' '/tmp/${router}.jwt'"
}
main(){
  log "Starting OpenZiti HA primary/orchestrator"
  install_packages
  create_controller_config
  enable_zac_spa
  create_pki_for_controller01
  start_and_init
  ship_and_finalize_secondaries
  add_controllers
  install_preferred_leader_watchdog "$C01_HOST" "$C01_HOST" "primary"
  # Router enrollment is intentionally done using controller01 internal address.
  # This makes deployment succeed even if the customer has not yet updated public DNS.
  set_local_edge_address "$C01_HOST"
  for r in "$R01_HOST" "$R02_HOST" "$R03_HOST"; do wait_for ${r}-ssh "nc -z $r 22" 120 5; create_router_jwt_and_finalize "$r"; done
  # After routers are enrolled, switch all controllers to final public 443 advertised address for ZAC/API/OIDC.
  finalize_public_edge_addresses
  ziti edge list edge-routers || true
  sudo -u ziti-controller ziti agent cluster list --timeout 60s || true
  cat > /opt/ziti-ha/controller-status.txt <<EOS
status=completed
role=controller-primary-orchestrator
cluster_check=sudo -u ziti-controller ziti agent cluster list --timeout 30s
router_check=ziti edge list edge-routers
log=/var/log/ziti-ha-controller-primary-v4.log
EOS
}
main "$@"
