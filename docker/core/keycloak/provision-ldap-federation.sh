#!/usr/bin/env bash
# Create the WRITABLE Active Directory user federation in the `homelab` realm,
# pointing at the Samba AD DC **heimdall** over LDAPS. Writable edit mode means a
# Keycloak password reset (Update Password / Forgot Password) is written back to
# AD (`unicodePwd`), so one credential covers **SMB + web SSO**. AD becomes the
# source of truth for paul/jacob/becky/chloe; Keycloak is the self-service front end.
#
# Prereqs (see identity-infra/docs/ad-dc-build.md Phase 6):
#   - heimdall AD DC up; `svc-keycloak` bind account exists (CN=Users, Domain Admins).
#   - Firewall conditional-forward ad.lab.example -> 192.168.2.2 (SRV/A).
#   - keycloak container recreated with ./keycloak/truststore mounted at
#     /opt/keycloak/conf/truststores (Samba CA) + extra_hosts IPv4 pin for heimdall.
#   - Bind password in .env as AD_LDAP_BIND_CREDENTIAL — push it to Infisical first
#     (`./push-secret.sh AD_LDAP_BIND_CREDENTIAL '<pw>' && ./pull-secrets.sh`), since
#     pull-secrets.sh truncates .env and a value only in .env won't survive a re-pull.
#
# NOTE on existing local users: a local (non-federated) homelab user with the same
# username as an AD user blocks the import ("user already exists"). Delete the local
# paul/jacob/becky/chloe first (back them up) so they re-federate cleanly from AD.
#
# Idempotent. Run from /opt/homelab:  ./core/keycloak/provision-ldap-federation.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

REALM=homelab
PROVIDER_NAME=heimdall-ad
LDAP_URL="ldaps://heimdall.ad.lab.example:636"
BIND_DN="CN=svc-keycloak,CN=Users,DC=ad,DC=pdx,DC=sanctioned,DC=tech"
USERS_DN="DC=ad,DC=pdx,DC=sanctioned,DC=tech"

g(){ grep "^$1=" .env | cut -d= -f2- | sed -E "s/^['\"]//;s/['\"]\$//"; }
KC(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

BINDCRED="$(g AD_LDAP_BIND_CREDENTIAL)"
[ -n "$BINDCRED" ] || { echo "ERROR: AD_LDAP_BIND_CREDENTIAL missing from .env" >&2; exit 1; }

KC config credentials --server http://localhost:8080 --realm master \
  --user "$(g KEYCLOAK_ADMIN)" --password "$(g KEYCLOAK_ADMIN_PASSWORD)" >/dev/null

REALM_ID=$(KC get realms/$REALM --fields id --format csv --noquotes)

CID=$(KC get components -r $REALM -q name=$PROVIDER_NAME --fields id --format csv --noquotes 2>/dev/null | head -1 || true)

if [ -z "$CID" ]; then
  CID=$(KC create components -r $REALM -i \
    -s name=$PROVIDER_NAME \
    -s providerId=ldap \
    -s providerType=org.keycloak.storage.UserStorageProvider \
    -s parentId=$REALM_ID \
    -s 'config.enabled=["true"]' \
    -s 'config.priority=["0"]' \
    -s 'config.vendor=["ad"]' \
    -s 'config.editMode=["WRITABLE"]' \
    -s 'config.importEnabled=["true"]' \
    -s 'config.syncRegistrations=["true"]' \
    -s "config.connectionUrl=[\"$LDAP_URL\"]" \
    -s "config.bindDn=[\"$BIND_DN\"]" \
    -s "config.bindCredential=[\"$BINDCRED\"]" \
    -s "config.usersDn=[\"$USERS_DN\"]" \
    -s 'config.searchScope=["2"]' \
    -s 'config.usernameLDAPAttribute=["sAMAccountName"]' \
    -s 'config.rdnLDAPAttribute=["cn"]' \
    -s 'config.uuidLDAPAttribute=["objectGUID"]' \
    -s 'config.userObjectClasses=["person, organizationalPerson, user"]' \
    -s 'config.useTruststoreSpi=["always"]' \
    -s 'config.connectionPooling=["true"]' \
    -s 'config.pagination=["true"]' \
    -s 'config.trustEmail=["true"]' \
    -s 'config.allowKerberosAuthentication=["false"]' \
    -s 'config.useKerberosForPasswordAuthentication=["false"]' \
    -s 'config.validatePasswordPolicy=["false"]' \
    -s 'config.batchSizeForSync=["1000"]' \
    -s 'config.fullSyncPeriod=["-1"]' \
    -s 'config.changedSyncPeriod=["-1"]' \
    -s 'config.cachePolicy=["DEFAULT"]')
  echo "created LDAP federation '$PROVIDER_NAME' ($CID)" >&2
else
  # reconcile the mutable bits (url / bind / writable / trustEmail) on re-run
  KC update components/$CID -r $REALM \
    -s "config.connectionUrl=[\"$LDAP_URL\"]" \
    -s "config.bindDn=[\"$BIND_DN\"]" \
    -s "config.bindCredential=[\"$BINDCRED\"]" \
    -s 'config.editMode=["WRITABLE"]' \
    -s 'config.trustEmail=["true"]' >/dev/null
  echo "updated existing LDAP federation '$PROVIDER_NAME' ($CID)" >&2
fi

# Ensure the MSAD account-control mapper exists (userAccountControl, pwdLastSet /
# must-change, enabled/disabled). Creating an `ad` provider usually auto-generates
# the default mapper set; this is the idempotent backstop.
HASMSAD=$(KC get components -r $REALM -q parent=$CID --fields providerId --format csv --noquotes 2>/dev/null \
  | tr -d '"' | grep -c 'msad-user-account-control-mapper' || true)
if [ "$HASMSAD" = "0" ]; then
  KC create components -r $REALM \
    -s name="MSAD account controls" \
    -s providerId=msad-user-account-control-mapper \
    -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
    -s parentId=$CID >/dev/null && echo "added MSAD account-control mapper" >&2
fi

echo "triggering full sync (import AD users)..." >&2
KC create "user-storage/$CID/sync?action=triggerFullSync" -r $REALM 2>&1 | tail -1 >&2

echo "$CID"
