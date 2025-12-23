#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

help()
{
    echo "This script installs NGINX reverse proxy"
    echo ""
    echo "Options:"
    echo "    -u      Basic Authentication user name"
    echo "    -p      Basic Authentication passowrd"
    echo "    -n      TCP port number for NGINX to listen"
    echo "    -t      Target TCP port on local machine"
    echo "    -c      BASE64-encoded PFX file for TLS connection"
    echo "    -k      Optional password for PFX file needed to extract the RSA key"
    echo "    -h      view this help content"
}

# Custom logging with time so we can easily relate running times, also log to separate file so order is guaranteed.
# The Script extension output the stdout/err buffer in intervals with duplicates.
log()
{
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1"
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1" >> /var/log/nginx-install.log
}

#########################
# Parameter handling
#########################

AUTH_USERNAME=""
AUTH_PASSWORD=""
NGINX_PORT=0
TARGET_PORT=0
PFX_B64=""
PFX_PWD=""

#Loop through options passed
while getopts :u:p:n:t:c:k:h optname; do
  log "Option $optname set"
  case $optname in
    u) # basic auth user name
      AUTH_USERNAME="${OPTARG}"
      ;;
    p) # basic auth password
      AUTH_PASSWORD="${OPTARG}"
      ;;
    n) # TCP port number
      NGINX_PORT=${OPTARG}
      ;;
    t) # TCP port number
      TARGET_PORT=${OPTARG}
      ;;
    c) # base64 encoded PFX file
      PFX_B64="${OPTARG}"
      ;;
    k) # password for the PFX file
      PFX_PWD="${OPTARG}"
      ;;
    h) #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"ERROR: unknown option -${BOLD}$OPTARG${NORM}" >&2
      help
      exit 2
      ;;
  esac
done


if [ "${AUTH_USERNAME}" == "" -o "${AUTH_PASSWORD}" == "" -o ${NGINX_PORT} -eq 0 -o ${TARGET_PORT} -eq 0 -o "${PFX_B64}" == "" ];
then
    echo "ERROR: missing input arguments" >&2
    help
    exit 3
fi

#########################
# Constants
#########################

NGINX_DIR=/etc/nginx
NGINX_LOG_DIR=/var/log/nginx
BASIC_AUTH_PATH=$NGINX_DIR/.htpasswd
CERT_DIR=$NGINX_DIR/ssl
CRT_PATH=$CERT_DIR/host.crt
KEY_PATH=$CERT_DIR/host.key
DEFAULT_SITE_PATH=$NGINX_DIR/sites-available/default

#########################
# Installation functions
#########################

install_nginx()
{
  apt-get -yq install nginx
}

restart_nginx()
{
  systemctl restart nginx
}

# These utils contain the 'htpasswd'
install_apache_utils()
{
  apt-get -yq install apache2-utils
}

create_basic_auth_file()
{
  htpasswd -cb $BASIC_AUTH_PATH "$AUTH_USERNAME" "$AUTH_PASSWORD"
}

install_certificate()
{
  mkdir $CERT_DIR
  echo ${PFX_B64} | base64 -d >> $CERT_DIR/host.pfx
  openssl pkcs12 -in $CERT_DIR/host.pfx -clcerts -nokeys -out $CRT_PATH -passin pass:"$PFX_PWD"
  openssl pkcs12 -in $CERT_DIR/host.pfx -nodes -passin pass:"$PFX_PWD" | openssl rsa -out $KEY_PATH
  rm $CERT_DIR/host.pfx


  # ---- Auto-fetch intermediate from AIA ----
  echo "[INFO] Discovering CA Issuers AIA URL from leaf cert..."
  AIA_URL=$(openssl x509 -in "$CRT_PATH" -text -noout \
    | awk -F'URI:' '/CA Issuers/ {print $2; exit}' \
    | tr -d '[:space:]')
  
  if [[ -z "$AIA_URL" ]]; then
    echo "[WARN] No CA Issuers URI found in leaf certificate."
    echo "[HINT] You must provide the intermediate PEM manually at $CERT_DIR/intermediate.pem"
  else
    echo "[INFO] AIA URL: $AIA_URL"
    TMP_INT="$CERT_DIR/intermediate.der"
    INT_PEM="$CERT_DIR/intermediate.pem"
  
    echo "[INFO] Downloading intermediate from CA Issuers..."
    if [[ "$AIA_URL" =~ ^https?:// ]]; then
      if curl -fsSL "$AIA_URL" -o "$TMP_INT"; then
        echo "[INFO] Successfully downloaded intermediate certificate"
        
        # Detect format and convert to PEM if needed
        if file "$TMP_INT" | grep -qi 'ASCII text'; then
          echo "[INFO] Intermediate is already in PEM format"
          mv "$TMP_INT" "$INT_PEM"
        else
          echo "[INFO] Converting intermediate from DER to PEM..."
          if openssl x509 -inform DER -in "$TMP_INT" -out "$INT_PEM" 2>/dev/null; then
            rm -f "$TMP_INT"
          else
            echo "[ERROR] Failed to convert intermediate certificate"
            rm -f "$TMP_INT"
          fi
        fi
        
        # Verify we got a valid certificate
        if [[ -f "$INT_PEM" ]] && openssl x509 -in "$INT_PEM" -noout 2>/dev/null; then
          echo "[SUCCESS] Intermediate certificate obtained and validated"
        else
          echo "[ERROR] Failed to obtain valid intermediate certificate"
          rm -f "$INT_PEM"
        fi
      else
        echo "[ERROR] Failed to download from $AIA_URL"
      fi
    else
      echo "[ERROR] Unsupported AIA scheme: $AIA_URL"
      echo "[HINT] Provide intermediate PEM manually at $INT_PEM"
    fi
  fi

    # Some CAs chain multiple intermediates. If AIA serves a PKCS7 bundle, convert like:
    # openssl pkcs7 -print_certs -inform DER -in bundle.der -out intermediate.pem
    # (Add detection if you encounter pkcs7 bundles in your environment.)

  # ---- Build full chain (leaf + intermediate) ----
  FULLCHAIN="$CERT_DIR/fullchain.pem"
  if [[ -s "$CERT_DIR/intermediate.pem" ]]; then
    echo "[INFO] Building fullchain.pem (leaf + intermediate)..."
    cat "$CRT_PATH" "$CERT_DIR/intermediate.pem" > "$FULLCHAIN"
  else
    echo "[WARN] Intermediate PEM not available; using leaf only for now (will trigger scanner warnings)."
    cp "$CRT_PATH" "$FULLCHAIN"
  fi

  echo "[SUCCESS] Certificate install complete."
  echo "         Leaf:        $CRT_PATH"
  echo "         Key:         $KEY_PATH"
  echo "         Full chain:  $FULLCHAIN"
}

write_server_config()
{
  rm $NGINX_DIR/nginx.conf

  echo "user www-data;
worker_processes auto;
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

	default_type application/octet-stream;

	gzip on;
	gzip_disable "msie6";

	ssl_protocols TLSv1.2; # omit SSLv3 because of POODLE (CVE-2014-3566)
	ssl_prefer_server_ciphers on;
	ssl_certificate $FULLCHAIN;
	ssl_certificate_key $KEY_PATH;

	access_log $NGINX_LOG_DIR/access.log;
	error_log $NGINX_LOG_DIR/error.log;

	include $NGINX_DIR/conf.d/*.conf;
	include $NGINX_DIR/sites-enabled/*;
	include $NGINX_DIR/mime.types;
}" >> $NGINX_DIR/nginx.conf

}

write_site_config()
{
  rm $DEFAULT_SITE_PATH

  echo "server {
	listen $NGINX_PORT ssl default_server;
	listen [::]:$NGINX_PORT ssl default_server;
	proxy_read_timeout 300s;
	proxy_send_timeout 300s;
	location / {
		proxy_pass http://$(hostname):$TARGET_PORT;
		auth_basic "You_Shall_Not_Pass!";
		auth_basic_user_file $BASIC_AUTH_PATH;
	}
}" >> $DEFAULT_SITE_PATH

}

#########################
# Execution
#########################

log "[apt-get] updating apt-get"
(apt-get -y update || (sleep 15; apt-get -y update))
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
  log "[apt-get] failed updating apt-get. exit code: $EXIT_CODE"
  exit $EXIT_CODE
fi
log "[apt-get] updated apt-get"

log "Install NGINX"
install_nginx

log "Install Apache2 utils"
install_apache_utils

log "Create user file for basic authentication"
create_basic_auth_file

log "Install certificate for secure connection"
install_certificate

log "Write NGINX server configuration"
write_server_config

log "Write NGINX site configuration"
write_site_config

log "Re-start NGINX"
restart_nginx
