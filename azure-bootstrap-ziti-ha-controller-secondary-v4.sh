#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-controller-secondary-v4.log) 2>&1
NODE_NAME="${1:?node name missing}"
NODE_FQDN="${2:-}"
RUN_APT_UPGRADE="${3:-false}"
PUBLIC_DNS_NAME="${4:-}"
log(){ echo "[$(date -Is)] $*"; }
install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if [[ "$RUN_APT_UPGRADE" == "true" ]]; then apt-get upgrade -y; fi
  apt-get install -y curl gpg ca-certificates jq dnsutils iproute2 openssl sed netcat-openbsd
  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg
  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" > /etc/apt/sources.list.d/openziti-release.list
  apt-get update
  apt-get install -y openziti openziti-controller openziti-console
}
create_placeholder_config(){
  mkdir -p /var/lib/ziti-controller/cluster /opt/ziti-ha
  cd /var/lib/ziti-controller
  rm -f config.yml
  ziti create config controller --ctrlPort 6262 --routerEnrollmentDuration 3h --identityEnrollmentDuration 3h --output /var/lib/ziti-controller/config.yml
  sed -i "s/localhost/${NODE_NAME}/g" config.yml
  if ! grep -qE '^cluster:' config.yml; then
    cat >> config.yml <<EOF

cluster:
  dataDir: /var/lib/ziti-controller/cluster
EOF
  fi
  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
  chmod -R u=rwX,g=rwX,o= /var/lib/ziti-controller
  systemctl disable --now ziti-controller || true
}
enable_zac_spa(){
  cd /var/lib/ziti-controller
  # Keep controller web address as controller FQDN:1280; only add/repair ZAC SPA binding.
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

write_finalize(){
  cat > /opt/ziti-ha/finalize-secondary-controller-v4.sh <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
NODE_NAME="${1:?node name missing}"
NODE_FQDN="${2:-}"
PKI_TGZ="${3:?pki tarball missing}"
PRIMARY_NAME="${4:-ziti-ha-controller01}"
FALLBACK_NAME="${5:-ziti-ha-controller02}"
PUBLIC_DNS_NAME="${6:-}"
exec > >(tee -a /var/log/ziti-ha-finalize-secondary-controller-v4.log) 2>&1

install_preferred_leader_watchdog(){
  local preferred_id="$1"
  local primary_id="$2"
  local mode="$3"
  cat > /usr/local/bin/ziti-preferred-leader-watchdog.sh <<EOS2
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
EOS2
  chmod +x /usr/local/bin/ziti-preferred-leader-watchdog.sh

  # Ensure watchdog log is writable by the service user before the timer/service starts.
  touch /var/log/ziti-ha-preferred-leader-watchdog.log
  chown ziti-controller:ziti-controller /var/log/ziti-ha-preferred-leader-watchdog.log
  chmod 664 /var/log/ziti-ha-preferred-leader-watchdog.log
  cat > /etc/systemd/system/ziti-preferred-leader-watchdog.service <<'EOS2'
[Unit]
Description=OpenZiti preferred leader watchdog
After=ziti-controller.service
Wants=ziti-controller.service

[Service]
Type=oneshot
User=ziti-controller
ExecStart=/usr/local/bin/ziti-preferred-leader-watchdog.sh
EOS2
  cat > /etc/systemd/system/ziti-preferred-leader-watchdog.timer <<'EOS2'
[Unit]
Description=Run OpenZiti preferred leader watchdog periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
Unit=ziti-preferred-leader-watchdog.service

[Install]
WantedBy=timers.target
EOS2
  systemctl daemon-reload
  systemctl enable --now ziti-preferred-leader-watchdog.timer
  /usr/local/bin/ziti-preferred-leader-watchdog.sh || true
}
systemctl stop ziti-controller || true
mkdir -p /var/lib/ziti-controller
if [[ -d /var/lib/ziti-controller/pki ]]; then mv /var/lib/ziti-controller/pki /var/lib/ziti-controller/pki.local.$(date +%Y%m%d-%H%M%S); fi
tar -xzf "$PKI_TGZ" -C /var/lib/ziti-controller
chown -R ziti-controller:ziti-controller /var/lib/ziti-controller/pki
sudo -u ziti-controller bash -lc "
set -e
cd /var/lib/ziti-controller
ziti pki create key --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --key-file ${NODE_NAME}
ziti pki create server --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --server-file ${NODE_NAME}.server --server-name ${NODE_NAME} --key-file ${NODE_NAME} --dns ${NODE_NAME} ${NODE_FQDN:+--dns ${NODE_FQDN}} ${PUBLIC_DNS_NAME:+--dns ${PUBLIC_DNS_NAME}} --ip 127.0.0.1 --spiffe-id /controller/${NODE_NAME} --allow-overwrite
ziti pki create client --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --client-file ${NODE_NAME}.client --client-name ${NODE_NAME} --key-file ${NODE_NAME} --spiffe-id /controller/${NODE_NAME} --allow-overwrite
cp pki/intermediate/keys/${NODE_NAME}.key ./${NODE_NAME}.key
cp pki/intermediate/certs/${NODE_NAME}.client.chain.pem ./${NODE_NAME}client.chain.cert
cp pki/intermediate/certs/${NODE_NAME}.server.chain.pem ./${NODE_NAME}.server.chain.cert
cp pki/intermediate/certs/intermediate.chain.pem ./${NODE_NAME}.ca
cp pki/intermediate/certs/intermediate.cert ./${NODE_NAME}.signing.cert
cp pki/intermediate/keys/intermediate.key ./${NODE_NAME}.signing.key
chmod 640 /var/lib/ziti-controller/${NODE_NAME}*
"
chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
chmod 750 /var/lib/ziti-controller
systemctl enable ziti-controller
systemctl restart ziti-controller
for i in $(seq 1 60); do curl -kfsS https://127.0.0.1:1280/version >/dev/null && break; sleep 5; done
systemctl status ziti-controller --no-pager || true
if [[ "$NODE_NAME" == "$FALLBACK_NAME" ]]; then install_preferred_leader_watchdog "$FALLBACK_NAME" "$PRIMARY_NAME" "fallback"; fi
EOS
  chmod +x /opt/ziti-ha/finalize-secondary-controller-v4.sh
}
main(){
  log "Starting OpenZiti HA secondary bootstrap for $NODE_NAME"
  install_packages
  create_placeholder_config
  enable_zac_spa
  write_finalize
  cat > /opt/ziti-ha/controller-status.txt <<EOS
status=waiting_for_primary
role=controller-secondary
node_name=${NODE_NAME}
finalize=/opt/ziti-ha/finalize-secondary-controller-v4.sh
log=/var/log/ziti-ha-controller-secondary-v4.log
EOS
}
main "$@"
