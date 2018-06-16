#!/usr/bin/env bash

readonly usage="Usage: $0 <client-name> <sim-type> <storage-account-name> <storage-account-key> <email-key> <server-tables-name> <server-tables-key> <cloudflare-user> <cloudflare-key> <cloudflare-zone> <sync-schedule>

Parameters:
--------------------------

client-name:              The name that should be assigned to the Opwen device
                          that is being configured by this script. Usually this
                          will be a name that is descriptive for the location
                          where the device will be deployed. The client-name
                          should be globally unique as it is used as the key for
                          a bunch of things.

sim-type:                 The mobile network to which to connect to upload data
                          to the cloud, e.g. Hologram_World or Vodacom_DRC.

storage-account-name:     The name of the account on the external storage
                          service (e.g. Azure Blob Storage, Amazon S3, etc.)
                          that the Opwen will use as its target data store.

storage-account-key:      The security key to access the account specified via
                          the <storage-account-name> parameter above.

email-key:                The security key to access the email sending service
                          (e.g. Sendgrid, Mailgun, etc.)

server-tables-name:       The name of the account on the external storage
                          service (e.g. Azure Blob Storage, Amazon S3, etc.)
                          that the Lokole server uses for tables.

server-tables-key:        The security key to access the account specified via
                          the <server-tables-name> parameter above.

cloudflare-user:          The user name for the Cloudflare account associated
                          with the Lokole DNS.

cloudflare-key:           The access key for the Cloudflare account associated
                          with the Lokole DNS.

cloudflare-zone:          The zone for the Cloudflare account associated with
                          the Lokole DNS.

sync-schedule:            How often the Lokole should sync with the server. In
                          cron syntax. Example: '34 * * * *' for once per hour.

Environment variables:
--------------------------

LOKOLE_PASSWORD:          If set to a non-empty string, updates the password of
                          the current user to this value as part of the setup.
                          Useful for fully automated setups of new devices that
                          come with a default insecure password.

LOKOLE_WIFI:              If set to 'no', skip setup of WiFi access point and
                          local DNS server configuration.

LOKOLE_PORT:              If set to a non-empty string, use this value instead
                          of the default port 80 to run the Lokole email app.
"

################################################################################
#                                                                 helper methods
################################################################################

info() { echo -e "\e[42m$*\e[0m"; }
fail() { echo -e "\e[41m$*\e[0m"; exit 1; }
python_version() { python3 -c 'from sys import version_info; print("%s.%s" % (version_info.major, version_info.minor));'; }
set_timezone() { sudo timedatectl set-timezone "$1"; }
update_system_packages() { sudo apt-get update; sudo apt-get upgrade -y; }
install_system_package() { sudo apt-get install -y "$@"; }
write_file() { mkdir -p "$(dirname "$1")"; sudo tee "$1" > /dev/null; }
replace_file() { sudo sed -i "$1" "$2"; }
create_directory() { mkdir -p "$1"; }
create_temp_directory() { mktemp -d "$1"; }
create_link() { sudo ln -s "$1" "$2" || true; }
copy_file() { sudo cp -f "$1" "$2" || echo "$1 does not exist, skipping copy to $2"; }
delete() { if [ ! -L "$1" ]; then sudo rm -rf "$1"; else sudo unlink "$1"; fi }
make_executable() { sudo chmod a+x "$1"; }
create_virtualenv() { python3 -m venv "$1"; }
change_password() { echo "$1:$2" | sudo chpasswd; }
required_param() { [ -z "$1" ] && echo "Missing required parameter: $2" && (echo "$3" | head -1) && exit 1; }
random_string() { head /dev/urandom | tr -dc '_A-Z-a-z-0-9' | head -c"${1:-16}"; echo; }
disable_system_power_management() { sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target; }
get_system_ram_kb() { grep 'MemTotal' '/proc/meminfo' | cut -d':' -f2 | sed 's/^ *//g' | cut -d' ' -f1; }
min() { if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi; }
create_root_cron() { (sudo crontab -l || true; echo "$1 $2") 2>&1 | grep -v 'no crontab for' | sort -u | sudo crontab -; }
http_get() { /usr/bin/curl --request 'GET' --fail "$@"; }
http_post_json() { /usr/bin/curl --header 'Content-Type: application/json' --request 'POST' --fail "$@"; }
reload_daemons() { sudo service supervisor start; sudo supervisorctl reread; sudo supervisorctl update; }
sleep_a_bit() { sleep "$((RANDOM % 10 + 17))s"; }

set_locale() {
local locale="$1"

local locale_script='/etc/profile.d/set-locale.sh'
local locale_command="export LANGUAGE='${locale}'; export LC_ALL='${locale}'; export LANG='${locale}'; export LC_TYPE='${locale}';"

sudo locale-gen "${locale}"
sudo update-locale
eval "${locale_command}"

echo "${locale_command}" | write_file "${locale_script}"
make_executable "${locale_script}"
}

create_daemon() {
local daemon_name="$1"
local script="$2"
local runas="$3"
local stdlogfile="$4"
local errlogfile="$5"

write_file "/etc/supervisor/conf.d/${daemon_name}.conf" << EOF
[program:${daemon_name}]
command=${script}
autostart=true
autorestart=true
startretries=3
stderr_logfile=${errlogfile}
stdout_logfile=${stdlogfile}
user=${runas}
EOF
reload_daemons
}

finished() {
delete "${HOME}/.cache/pip"

info '
################################################################################
#                                         rebooting in 1 minute to start service
################################################################################'

sudo shutdown --reboot +1
exit 0
}

################################################################################
#                                                         command line interface
################################################################################

case $1 in -h|--help) fail "${usage}";; esac

readonly opwen_webapp_config_client_name="$1"
readonly sim_type="$2"
readonly opwen_webapp_config_remote_account_name="$3"
readonly opwen_webapp_config_remote_account_key="$4"
readonly email_account_key="$5"
readonly server_tables_account_name="$6"
readonly server_tables_account_key="$7"
readonly cloudflare_user="$8"
readonly cloudflare_key="$9"
readonly cloudflare_zone="${10}"
readonly sync_schedule="${11}"

readonly opwen_network_name='Lokole'
readonly opwen_network_password='Ascoderu'
readonly opwen_server_read_host='api.mailserver.read.lokole.ca'
readonly opwen_server_write_host='api.mailserver.write.lokole.ca'
readonly opwen_server_inbox_host='api.mailserver.inbox.lokole.ca'
readonly opwen_server_locale='en_GB.UTF-8'
readonly opwen_server_timezone='Etc/UTC'
readonly opwen_user="${USER}"
readonly opwen_device="${HOSTNAME}"
readonly opwen_port="${LOKOLE_PORT:-80}"

info '
################################################################################
#                                                               verifying inputs
################################################################################'

required_param "${opwen_webapp_config_client_name}" 'client-name' "${usage}"
required_param "${sim_type}" 'sim-type' "${usage}"

if [ "${sim_type}" != "LocalOnly" ]; then
  required_param "${opwen_webapp_config_remote_account_name}" 'storage-account-name' "${usage}"
  required_param "${opwen_webapp_config_remote_account_key}" 'storage-account-key' "${usage}"
  required_param "${email_account_key}" 'email-key' "${usage}"
  required_param "${server_tables_account_name}" 'server-tables-name' "${usage}"
  required_param "${server_tables_account_key}" 'server-tables-key' "${usage}"
  required_param "${cloudflare_user}" 'cloudflare-user' "${usage}"
  required_param "${cloudflare_key}" 'cloudflare-key' "${usage}"
  required_param "${cloudflare_zone}" 'cloudflare-zone' "${usage}"
  required_param "${sync_schedule}" 'sync-schedule' "${usage}"
fi

set -o errexit
set -o pipefail

update_system_packages
install_system_package 'curl'

case "${sim_type}" in
  Hologram_World) ;;
  Ethernet) ;;
  LocalOnly) ;;
  *) fail "Unsupported sim-type: ${sim_type}" ;;
esac

if [ "${LOKOLE_WIFI}" != "no" ]; then
case "${opwen_device}" in
  OrangePI|orangepizero) ht_capab='[HT40][DSS_CCK-40]' ;;
  raspberrypi) ht_capab='[HT40][SHORT-GI-20][DSS_CCK-40]' ;;
  *) fail "Unsupported device: ${opwen_device}" ;;
esac
fi

opwen_webapp_config_client_domain="${opwen_webapp_config_client_name}.lokole.ca"
opwen_webapp_config_client_id="$(random_string 32)"

if [ "${sim_type}" != "LocalOnly" ]; then
  if http_get --header "Authorization: Bearer ${email_account_key}" \
    "https://api.sendgrid.com/v3/user/webhooks/parse/settings/${opwen_webapp_config_client_domain}"; then
    fail "Client ${opwen_webapp_config_client_name} already exists."
  fi
fi


info '
################################################################################
#                                                      running pre-install setup
################################################################################'

set_locale "${opwen_server_locale}"
set_timezone "${opwen_server_timezone}"

if [ -n "${LOKOLE_PASSWORD}" ]; then
  change_password "${opwen_user}" "${LOKOLE_PASSWORD}"
fi


info '
################################################################################
#                                                                installing wifi
################################################################################'
if [ "${LOKOLE_WIFI}" != "no" ]; then

install_system_package 'hostapd' 'dnsmasq'

opwen_ip_base='10.0.0'
opwen_ip="${opwen_ip_base}.1"

write_file '/etc/hosts' << EOF
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
127.0.0.1	localhost
127.0.0.1	${opwen_device}
127.0.1.1	${opwen_device}
${opwen_ip}	www.lokole.com
${opwen_ip}	www.lokole.org
${opwen_ip}	www.lokole.ca
${opwen_ip}	www.lokole.cd
${opwen_ip}	www.lokole
${opwen_ip}	www.opwen.com
${opwen_ip}	www.opwen.org
${opwen_ip}	www.opwen.ca
${opwen_ip}	www.opwen.cd
${opwen_ip}	www.opwen
${opwen_ip}	www.ascoderu.com
${opwen_ip}	www.ascoderu.org
${opwen_ip}	www.ascoderu.ca
${opwen_ip}	www.ascoderu.cd
${opwen_ip}	lokole.com
${opwen_ip}	lokole.org
${opwen_ip}	lokole.ca
${opwen_ip}	lokole.cd
${opwen_ip}	lokole
${opwen_ip}	opwen.com
${opwen_ip}	opwen.org
${opwen_ip}	opwen.ca
${opwen_ip}	opwen.cd
${opwen_ip}	opwen
${opwen_ip}	ascoderu.com
${opwen_ip}	ascoderu.org
${opwen_ip}	ascoderu.ca
${opwen_ip}	ascoderu.cd
EOF

write_file '/etc/dnsmasq.conf' << EOF
log-facility=/var/log/dnsmasq.log
dhcp-range=${opwen_ip_base}.10,${opwen_ip_base}.250,12h
interface=wlan0
no-resolv
log-queries
server=8.8.8.8
EOF

write_file '/etc/network/interfaces' << EOF
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp

auto wlan0
allow-hotplug wlan0
iface wlan0 inet static
  post-up service hostapd restart
  post-up service dnsmasq restart
  address ${opwen_ip}
  netmask 255.255.255.0
wireless-power off

auto ppp0
iface ppp0 inet wvdial
EOF

write_file '/etc/hostapd/hostapd.conf' << EOF
interface=wlan0
driver=nl80211
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
ht_capab=${ht_capab}
macaddr_acl=0
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ssid=${opwen_network_name}
wpa_passphrase=${opwen_network_password}
EOF

replace_file 's@^DAEMON_CONF=$@DAEMON_CONF=/etc/hostapd/hostapd.conf@' '/etc/init.d/hostapd'
disable_system_power_management


fi
info '
################################################################################
#                                                        installing email webapp
################################################################################'

install_system_package 'python3' 'python3-pip' 'python3-venv' 'python3-dev' 'libffi-dev' 'libssl-dev' 'bcrypt'

opwen_webapp_virtualenv="/home/${opwen_user}/python"
create_directory "${opwen_webapp_virtualenv}"

opwen_webapp_service='opwen_email_client'
opwen_webapp_directory="${opwen_webapp_virtualenv}/lib/python$(python_version)/site-packages/${opwen_webapp_service}/webapp"

create_virtualenv "${opwen_webapp_virtualenv}"
while ! "${opwen_webapp_virtualenv}/bin/pip" install --upgrade pip setuptools wheel; do sleep_a_bit; done
while ! "${opwen_webapp_virtualenv}/bin/pip" install "${opwen_webapp_service}"; do sleep_a_bit; done
"${opwen_webapp_virtualenv}/bin/pybabel" compile -d "${opwen_webapp_directory}/translations"


info '
################################################################################
#                                                  setting up webapp environment
################################################################################'

opwen_webapp_run_directory="/home/${opwen_user}/state"
create_directory "${opwen_webapp_run_directory}"

opwen_webapp_config_session_key="$(random_string 32)"
opwen_webapp_config_password_salt="$(random_string 16)"
opwen_webapp_admin_secret="$(random_string 32)"
opwen_webapp_envs="${opwen_webapp_run_directory}/webapp_secrets.sh"

write_file "${opwen_webapp_envs}" << EOF
export OPWEN_STATE_DIRECTORY='${opwen_webapp_run_directory}'
export OPWEN_SESSION_KEY='${opwen_webapp_config_session_key}'
export OPWEN_PASSWORD_SALT='${opwen_webapp_config_password_salt}'
export OPWEN_ADMIN_SECRET='${opwen_webapp_admin_secret}'
export OPWEN_REMOTE_ACCOUNT_NAME='${opwen_webapp_config_remote_account_name}'
export OPWEN_REMOTE_ACCOUNT_KEY='${opwen_webapp_config_remote_account_key}'
export OPWEN_CLIENT_ID='${opwen_webapp_config_client_id}'
export OPWEN_CLIENT_NAME='${opwen_webapp_config_client_name}'
export OPWEN_EMAIL_SERVER_READ_API='${opwen_server_read_host}'
export OPWEN_EMAIL_SERVER_WRITE_API='${opwen_server_write_host}'
EOF


info '
################################################################################
#                                             installing server for email webapp
################################################################################'

install_system_package 'nginx' 'supervisor'

memory_per_worker_kb=200000
max_workers=4
opwen_webapp_timeout_seconds=300
opwen_webapp_workers=$(min $(($(get_system_ram_kb) / memory_per_worker_kb)) ${max_workers})
opwen_webapp_socket="${opwen_webapp_run_directory}/nginx_gunicorn.sock"
opwen_webapp_log_level="error"
nginx_access_log="${opwen_webapp_run_directory}/nginx_access.log"
nginx_error_log="${opwen_webapp_run_directory}/nginx_error.log"

opwen_webapp_script="${opwen_webapp_run_directory}/webapp.sh"
write_file "${opwen_webapp_script}" << EOF
#!/usr/bin/env sh
. '${opwen_webapp_envs}'

'${opwen_webapp_virtualenv}/bin/gunicorn' \\
  --timeout='${opwen_webapp_timeout_seconds}' \\
  --workers='${opwen_webapp_workers}' \\
  --bind='unix:${opwen_webapp_socket}' \\
  --log-level='${opwen_webapp_log_level}' \\
  '${opwen_webapp_service}.webapp:app'
EOF
make_executable "${opwen_webapp_script}"

create_daemon \
  "${opwen_webapp_service}" \
  "${opwen_webapp_script}" \
  "${opwen_user}" \
  "${opwen_webapp_run_directory}/webapp_stdout.log" \
  "${opwen_webapp_run_directory}/webapp_stderr.log"

write_file "/etc/nginx/sites-available/${opwen_webapp_service}" << EOF
server {
  listen ${opwen_port};
  server_name localhost;

  location = /favicon.ico {
    alias ${opwen_webapp_directory}/static/favicon.ico;
  }

  location /static/ {
    root ${opwen_webapp_directory};
  }

  location / {
    include proxy_params;
    proxy_pass http://unix:${opwen_webapp_socket};
  }
}
EOF
create_link "/etc/nginx/sites-available/${opwen_webapp_service}" '/etc/nginx/sites-enabled'
delete '/etc/nginx/sites-available/default'

write_file '/etc/nginx/nginx.conf' << EOF
user www-data;
worker_processes 4;
pid /run/nginx.pid;

events {
  worker_connections 768;
}

http {
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  types_hash_max_size 2048;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
  ssl_prefer_server_ciphers on;
  access_log ${nginx_access_log};
  error_log ${nginx_error_log};
  gzip on;
  gzip_disable "msie6";
  include /etc/nginx/conf.d/*.conf;
  include /etc/nginx/sites-enabled/*;

  fastcgi_connect_timeout ${opwen_webapp_timeout_seconds};
  fastcgi_send_timeout ${opwen_webapp_timeout_seconds};
  fastcgi_read_timeout ${opwen_webapp_timeout_seconds};
}
EOF

if [ "${sim_type}" == "LocalOnly" ]; then
  finished
fi


info '
################################################################################
#                                                       registering email webapp
################################################################################'

registration_virtualenv="$(create_temp_directory /tmp/opwen_email_server.XXXXXX)"

create_virtualenv "${registration_virtualenv}"
while ! "${registration_virtualenv}/bin/pip" install --upgrade pip setuptools wheel; do sleep_a_bit; done
while ! "${registration_virtualenv}/bin/pip" install opwen_email_server; do sleep_a_bit; done

"${registration_virtualenv}/bin/registerclient.py" \
    --tables_account="${server_tables_account_name}" \
    --tables_key="${server_tables_account_key}" \
    --client_account="${opwen_webapp_config_remote_account_name}" \
    --client_key="${opwen_webapp_config_remote_account_key}" \
    --client="${opwen_webapp_config_client_id}" \
    --domain="${opwen_webapp_config_client_domain}"

delete "${registration_virtualenv}"


info '
################################################################################
#                                                       installing network stick
################################################################################'

install_system_package 'cron'

opwen_webapp_email_sync_script="${opwen_webapp_run_directory}/sync.sh"

if [ "${sim_type}" != "Ethernet" ]; then
install_system_package 'usb-modeswitch' 'usb-modeswitch-data' 'ppp' 'wvdial'

opwen_dialer_config_directory="/home/${opwen_user}/wvdial"
create_directory "${opwen_dialer_config_directory}"

internet_modem_config_e303='/etc/usb_modeswitch.d/12d1:14fe'
internet_modem_config_e353='/etc/usb_modeswitch.d/12d1:1f01'
internet_modem_config_e3131='/etc/usb_modeswitch.d/12d1:155b'
internet_dialer_config='/etc/wvdial.conf'

write_file "${opwen_dialer_config_directory}/Hologram_World" << EOF
[Dialer Defaults]
Init1 = ATZ
Init2 = ATQ0
Init3 = AT+CGDCONT=1,"IP","apn.konekt.io"
Phone = *99***1#
Stupid Mode = 1
Username = { }
Password = { }
Modem Type = Analog Modem
Modem = /dev/ttyUSB0
IDSN = 0
EOF

copy_file "${opwen_dialer_config_directory}/${sim_type}" "${internet_dialer_config}"

write_file "${internet_modem_config_e303}" << EOF
DefaultVendor = 0x12d1
DefaultProduct = 0x14fe
TargetVendor = 0x12d1
TargetProduct = 0x1506
MessageContent = "55534243123456780000000000000011062000000101000100000000000000"
EOF

write_file "${internet_modem_config_e353}" << EOF
DefaultVendor = 0x12d1
DefaultProduct = 0x1f01
TargetVendor = 0x12d1
TargetProduct = 0x1001
MessageContent = "55534243123456780000000000000011060000000000000000000000000000"
EOF

write_file "${internet_modem_config_e3131}" << EOF
DefaultVendor = 0x12d1
DefaultProduct = 0x155b
TargetVendor = 0x12d1
TargetProduct = 0x1506
MessageContent = "55534243123456780000000000000011062000000100000000000000000000"
EOF

write_file '/etc/ppp/peers/wvdial' << EOF
noauth
name wvdial
usepeerdns
defaultroute
replacedefaultroute
EOF
fi

write_file "${opwen_webapp_email_sync_script}" << EOF
#!/usr/bin/env sh

sync_secret='${opwen_webapp_admin_secret}'
dialer_config='${internet_dialer_config}'
sync_logfile='${opwen_webapp_run_directory}/sync_stdout.log'

dialer_logfile="\$(mktemp /tmp/dialer.log.XXXXXX)"
dialer_pidfile="\$(mktemp /tmp/dialer.pid.XXXXXX)"

modem_target_mode='1506'

modem_is_e303() { /usr/bin/lsusb | grep 'Huawei' | grep -q '12d1:14fe'; }
modem_is_e353() { /usr/bin/lsusb | grep 'Huawei' | grep -q '12d1:1f01'; }
modem_is_e3131() { /usr/bin/lsusb | grep 'Huawei' | grep -q '12d1:155b'; }
modem_is_plugged() { /usr/bin/lsusb | grep 'Huawei' | grep -q '12d1:'; }
modem_is_setup() { /usr/bin/lsusb | grep 'Huawei' | grep -q "12d1:\${modem_target_mode}"; }
dialer_is_running() { test -f "\${dialer_pidfile}" && read pid < "\${dialer_pidfile}" && ps -p "\${pid}" > /dev/null; }
connect_to_internet() { /usr/bin/wvdial --config="\${dialer_config}" 2> "\${dialer_logfile}" & echo \$! > "\${dialer_pidfile}"; }
dialer_is_connected() { test -f "\${dialer_logfile}" && grep -q 'secondary DNS address' "\${dialer_logfile}"; }
kill_dialer() { test -f "\${dialer_pidfile}" && read pid < "\${dialer_pidfile}" && kill "\${pid}" && rm "\${dialer_pidfile}" && rm "\${dialer_logfile}"; }
sync_emails() { /usr/bin/curl "http://localhost:${opwen_port}/sync?secret=\${sync_secret}"; }

setup_modem() {
  if   modem_is_e353;  then modem_target_mode='1001'; /usr/sbin/usb_modeswitch --config-file '${internet_modem_config_e353}'
  elif modem_is_e303;  then modem_target_mode='1506'; /usr/sbin/usb_modeswitch --config-file '${internet_modem_config_e303}'
  elif modem_is_e3131; then modem_target_mode='1506'; /usr/sbin/usb_modeswitch --config-file '${internet_modem_config_e3131}'
  else exit 1;         fi
}

main_modem() {
  if ! modem_is_plugged; then
    echo 'Modem not plugged in, exitting' >&2
    exit 1
  fi

  if ! modem_is_setup; then
    echo 'Setting up modem...'
    setup_modem
    while ! modem_is_setup; do sleep 1s; done
    echo '...done, modem is now set up'
  fi

  if ! dialer_is_running; then
    echo 'Dialing up...'
    connect_to_internet
    while ! dialer_is_connected; do sleep 1s; done
    echo '...done, connection to internet is established'
  fi

  echo 'Syncing emails...'
  sync_emails
  echo '...done, emails are synced'

  echo 'Killing dialer...'
  kill_dialer
  echo '...done, connection to internet is terminated'
}

main_ethernet() {
  echo 'Syncing emails...'
  sync_emails
  echo '...done, emails are synced'
}

main() {
  if [ "${sim_type}" = "Ethernet" ]; then
    main_ethernet
  else
    main_modem
  fi
}

main 2>&1 | tee --append "\${sync_logfile}"
EOF
make_executable "${opwen_webapp_email_sync_script}"

create_root_cron "${sync_schedule}" "${opwen_webapp_email_sync_script}"


info '
################################################################################
#                                            setting up email dns and forwarding
################################################################################'

opwen_cloudserver_endpoint="http://${opwen_server_inbox_host}/api/email/sendgrid/${opwen_webapp_config_client_id}"

http_post_json \
    --header "Authorization: Bearer ${email_account_key}" \
    --data "{\"hostname\":\"${opwen_webapp_config_client_domain}\",\"url\":\"${opwen_cloudserver_endpoint}\",\"spam_check\":true,\"send_raw\":true}" \
    'https://api.sendgrid.com/v3/user/webhooks/parse/settings'

http_post_json \
  --header "X-Auth-Key: ${cloudflare_key}" \
  --header "X-Auth-Email: ${cloudflare_user}" \
  --data "{\"type\":\"MX\",\"name\":\"${opwen_webapp_config_client_name}\",\"content\":\"mx.sendgrid.net\",\"proxied\":false,\"priority\":1}" \
  "https://api.cloudflare.com/client/v4/zones/${cloudflare_zone}/dns_records"


finished
