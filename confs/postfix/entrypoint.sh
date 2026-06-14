#!/bin/sh
set -e

SMTP_SERVER="${SMTP_SERVER:-smtp.mail.ru}"
SMTP_PORT="${SMTP_PORT:-587}"
HELO_NAME="${HELO_NAME:-crm.cifroweek.com}"
SMTP_SECURITY="${SMTP_SECURITY:-encrypt}"
MYNETWORKS="${MYNETWORKS:-127.0.0.0/8 10.20.10.0/24}"

echo "Configuring Postfix..."

# Initialize main.cf from template if not exists
[ -f /etc/postfix/main.cf ] || cp /usr/share/postfix/main.cf.debian /etc/postfix/main.cf

postconf -e "myhostname = ${HELO_NAME}"
postconf -e "myorigin = ${HELO_NAME}"
postconf -e "mydestination ="
postconf -e "local_recipient_maps ="
postconf -e "local_transport = error:local mail is disabled"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mynetworks = ${MYNETWORKS}"
postconf -e "relayhost = [${SMTP_SERVER}]:${SMTP_PORT}"
postconf -e "maillog_file = /dev/stdout"

# Inbound SMTP (from PHP/msmtp in Docker network)
postconf -e "smtpd_relay_restrictions = permit_mynetworks reject"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks reject_unauth_destination"
postconf -e "smtpd_sasl_auth_enable = no"

# Outbound SASL auth
postconf -e "smtp_sender_dependent_authentication = yes"
postconf -e "sender_dependent_relayhost_maps = hash:/etc/postfix/sender_relay"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_sasl_tls_security_options = noanonymous"
postconf -e "smtp_sasl_mechanism_filter = login plain"
postconf -e "smtp_sasl_type = cyrus"
postconf -e "smtp_use_tls = yes"
postconf -e "smtp_tls_security_level = ${SMTP_SECURITY}"
postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "smtp_helo_name = ${HELO_NAME}"
postconf -e "smtp_tls_loglevel = 1"

# sender_relay
cat > /etc/postfix/sender_relay << ENDMAP
${SMTP_LOGIN_PORTAL}	[${SMTP_SERVER}]:${SMTP_PORT}
${SMTP_LOGIN_SHOP}	[${SMTP_SERVER}]:${SMTP_PORT}
ENDMAP
postmap /etc/postfix/sender_relay

# sasl_passwd (sender-keyed for per-account auth)
SASL_DEFAULT_LOGIN="${SMTP_DEFAULT_LOGIN:-${SMTP_LOGIN_PORTAL}}"
SASL_DEFAULT_PASS="${SMTP_DEFAULT_PASSWORD:-${SMTP_PASSWORD_PORTAL}}"
cat > /etc/postfix/sasl_passwd << ENDPW
${SMTP_LOGIN_PORTAL}	${SMTP_LOGIN_PORTAL}:${SMTP_PASSWORD_PORTAL}
${SMTP_LOGIN_SHOP}	${SMTP_LOGIN_SHOP}:${SMTP_PASSWORD_SHOP}
[${SMTP_SERVER}]:${SMTP_PORT}	${SASL_DEFAULT_LOGIN}:${SASL_DEFAULT_PASS}
ENDPW
chmod 600 /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd.db

# Aliases
[ -f /etc/postfix/aliases ] || echo "postmaster: root" > /etc/postfix/aliases
postalias /etc/postfix/aliases
postconf -e "alias_maps = hash:/etc/postfix/aliases"
postconf -e "alias_database = hash:/etc/postfix/aliases"

# Disable chroot for all services (required in Docker without SYS_CHROOT)
postconf -F '*/*/chroot=n' 2>/dev/null || true

echo "Postfix configuration done. Starting..."
postfix check

exec /usr/sbin/postfix start-fg
