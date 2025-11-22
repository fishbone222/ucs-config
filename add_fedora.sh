read -p "ip of ucs-master: " ipadd
export MASTER_IP=$ipadd

dnf install -y sssd-ldap

# Set the IP address of the UCS DC Master, 192.168.0.3 in this example
echo $MASTER_IP
mkdir /etc/univention -p
ssh -n root@${MASTER_IP} 'ucr shell | grep -v ^hostname=' >/etc/univention/ucr_master
echo "master_ip=${MASTER_IP}" >>/etc/univention/ucr_master
chmod 660 /etc/univention/ucr_master
. /etc/univention/ucr_master

echo "${MASTER_IP} ${ldap_master}" >>/etc/hosts


# Download the SSL certificate
mkdir -p /etc/univention/ssl/ucsCA/
wget -O /etc/univention/ssl/ucsCA/CAcert.pem \
    http://${ldap_master}/ucs-root-ca.crt

# Create an account and save the password
password="$(tr -dc A-Za-z0-9_ </dev/urandom | head -c20)"
ssh -n root@${ldap_master} udm computers/linux create \
    --position "cn=computers,${ldap_base}" \
    --set name=$(hostname -s) --set password="${password}" \
    --set operatingSystem="$(lsb_release -is)" \
    --set operatingSystemVersion="$(lsb_release -rs)"
printf '%s' "$password" >/etc/ldap.secret
chmod 0400 /etc/ldap.secret

# Create ldap.conf
mkdir /etc/ldap -p
cat >/etc/ldap/ldap.conf <<__EOF__
TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base
__EOF__

# Create sssd.conf
cat >/etc/sssd/sssd.conf <<__EOF__
[sssd]
services = nss, pam, sudo
domains = $kerberos_realm

[nss]

[pam]

[domain/$kerberos_realm]
auth_provider = krb5
krb5_kdcip = ${master_ip}
krb5_realm = ${kerberos_realm}
krb5_server = ${ldap_master}
krb5_kpasswd = ${ldap_master}
id_provider = ldap
ldap_uri = ldaps://${ldap_master}:7636
ldap_search_base = ${ldap_base}
ldap_tls_reqcert = allow
ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem
cache_credentials = true
enumerate = true
ldap_default_bind_dn = cn=$(hostname),cn=computers,${ldap_base}
ldap_default_authtok_type = password
ldap_default_authtok = $(cat /etc/ldap.secret)
__EOF__
chmod 600 /etc/sssd/sssd.conf

authselect select sssd with-mkhomedir

# Restart sssd
service sssd restart


# Default krb5.conf
cat >/etc/krb5.conf <<__EOF__
[libdefaults]
    default_realm = $kerberos_realm
    kdc_timesync = 1
    ccache_type = 4
    forwardable = true
    proxiable = true
    default_tkt_enctypes = arcfour-hmac-md5 des-cbc-md5 des3-hmac-sha1 des-cbc-crc des-cbc-md4 des3-cbc-sha1 aes128-cts-hmac-sha1-96 aes256-cts-hmac-sha1-96
    permitted_enctypes = des3-hmac-sha1 des-cbc-crc des-cbc-md4 des-cbc-md5 des3-cbc-sha1 arcfour-hmac-md5 aes128-cts-hmac-sha1-96 aes256-cts-hmac-sha1-96
    allow_weak_crypto=true

[realms]
$kerberos_realm = {
   kdc = $master_ip $ldap_master
   admin_server = $master_ip $ldap_master
   kpasswd_server = $master_ip $ldap_master
}
__EOF__

# Synchronize the time with the UCS system
ntpdate -bu $ldap_master

# Test Kerberos: kinit will ask you for a ticket and the SSH login to the master should work with ticket authentication:
kinit Administrator
ssh -n Administrator@$ldap_master ls /etc/univention

# Destroy the kerberos ticket
kdestroy
