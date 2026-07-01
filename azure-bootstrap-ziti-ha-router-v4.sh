#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-router-v4.log) 2>&1
ROUTER_NAME="${1:?router name missing}"
RUN_APT_UPGRADE="${2:-false}"
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
  apt-get install -y openziti openziti-router
  systemctl disable --now ziti-router || true
}
write_finalize(){
  mkdir -p /opt/ziti-ha
  cat > /opt/ziti-ha/finalize-router-v4.sh <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
ROUTER_NAME="${1:?router name missing}"
JWT_PATH="${2:?jwt path missing}"
exec > >(tee -a /var/log/ziti-ha-finalize-router-v4.log) 2>&1
systemctl stop ziti-router || true
mkdir -p /var/lib/ziti-router
ziti create config router edge --routerName "$ROUTER_NAME" --output /var/lib/ziti-router/config.yml
sed -i 's#/home/[^/]*/#/var/lib/ziti-router/#g' /var/lib/ziti-router/config.yml
cp "$JWT_PATH" /var/lib/ziti-router/${ROUTER_NAME}.jwt
chown -R ziti-router:ziti-router /var/lib/ziti-router
chmod 750 /var/lib/ziti-router
chmod 600 /var/lib/ziti-router/${ROUTER_NAME}.jwt
sudo -u ziti-router ziti router enroll /var/lib/ziti-router/config.yml --jwt /var/lib/ziti-router/${ROUTER_NAME}.jwt
systemctl enable ziti-router
systemctl restart ziti-router
sleep 5
systemctl status ziti-router --no-pager || true
EOS
  chmod +x /opt/ziti-ha/finalize-router-v4.sh
}
main(){
  log "Starting OpenZiti HA router prep for $ROUTER_NAME"
  install_packages
  write_finalize
  cat > /opt/ziti-ha/router-status.txt <<EOS
status=waiting_for_primary
role=router
router_name=${ROUTER_NAME}
finalize=/opt/ziti-ha/finalize-router-v4.sh
log=/var/log/ziti-ha-router-v4.log
EOS
}
main "$@"
