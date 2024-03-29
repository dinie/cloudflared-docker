#!/bin/bash
set -e

echo "**** Cloudflared setup script init... ****"

echo "**** Checking cloudflared setup script requirements... ****"
ARCH="$(command arch)"
if [ "${ARCH}" = "x86_64" ]; then 
  ARCH="amd64"
elif [ "${ARCH}" = "aarch64" ]; then 
  ARCH="arm64" 
elif [ "${ARCH}" = "armv7l" ]; then 
  ARCH="armhf" 
else
  echo "**** Unsupported Linux architecture ${ARCH} found, exiting... ****"
  exit 1
fi
echo "**** Linux architecture found: ${ARCH} ****"

echo "**** Checking for cloudflared setup script dependencies... ****"
YQARCH="${ARCH}"
if [ "${YQ_ARCH}" = "armhf" ]; then 
  YQARCH="arm" 
fi

echo "*** Set UDP receive buffer size for quic-go ***"
echo "net.core.rmem_max=2500000" >> /etc/sysctl.conf
sysctl -w net.core.rmem_max=2500000

echo "**** Temporarily installing /tmp/yq... ****"
curl -sLo /tmp/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQARCH}
chmod +x /tmp/yq

echo "**** Installing cloudflared...****"
if [ -d "/cloudflared/" ]; then
  echo "**** Moving /cloudflared/cloudflared-${ARCH} to /usr/local/bin/cloudflared... ****"
  mv /cloudflared/cloudflared-${ARCH} /usr/local/bin/cloudflared

  echo "**** Deleting tmp /cloudflared dir... ****"
  rm -rf /cloudflared 

  echo "**** Cloudflared installed ****"
elif [ -x "$(command -v cloudflared)" ]; then
  echo "**** Cloudflared already installed, skipping... ****"
else
  echo "**** Cloudflared missing, exiting... ****"
  exit 1
fi
cloudflared -v

echo "**** Checking for cloudflare tunnel parameters... ****"
if [[ ${#CF_ZONE_ID} -gt 0 ]] && [[ ${#CF_ACCOUNT_ID} -gt 0 ]] && [[ ${#CF_API_TOKEN} -gt 0 ]] && [[ ${#CF_TUNNEL_NAME} -gt 0 ]]; then
  if [[ ${#CF_TUNNEL_PASSWORD} -lt 32 ]]; then
    echo "**** Cloudflare tunnel password must be at least 32 characters long, exiting... ****"
    exit 1 
  else
    echo "**** Cloudflare tunnel parameters found, starting cloudflare tunnel setup... ****"
    echo "**** Creating cloudflare tunnel (${CF_TUNNEL_NAME}) via API... ****"

    CF_TUNNEL_SECRET="$(command echo ${CF_TUNNEL_PASSWORD} | base64 -w 0)"
    echo "*** Secret is: ${CF_TUNNEL_SECRET} ***"
    echo "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/tunnels" \
         " Authorization: Bearer ${CF_API_TOKEN}" \
         " Content-Type: application/json"
    JSON_RESULT=$(curl -sX \
      POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/tunnels" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"name\":\"${CF_TUNNEL_NAME}\",\"tunnel_secret\":\"${CF_TUNNEL_SECRET}\"}")
    echo ${JSON_RESULT} | jq

    JSON_CODE_VALUE=$(echo ${JSON_RESULT} | jq -rc ".code // .errors[].code")
    if [[ ${JSON_CODE_VALUE} -eq 1013 ]]; then
      echo "**** You already have a cloudflare tunnel named ${CF_TUNNEL_NAME} ****"
    
      echo "**** Searching existing cloudflare tunnels via API... ****"
      JSON_RESULT=$(curl -sX \
        GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/tunnels?name=${CF_TUNNEL_NAME}&is_deleted=false" \
          -H "Authorization: Bearer ${CF_API_TOKEN}" \
          -H "Content-Type: application/json")
      echo ${JSON_RESULT} | jq

      echo "**** Fetching existing cloudflare tunnel (${CF_TUNNEL_NAME}) via API... ****"
      CF_TUNNEL_ID=$(echo ${JSON_RESULT} | jq -rc ".[].id? // .result[].id")
      JSON_RESULT=$(curl -sX \
        GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/tunnels/${CF_TUNNEL_ID}?" \
          -H "Authorization: Bearer ${CF_API_TOKEN}" \
          -H "Content-Type: application/json")

      JSON_RESULT=$(echo ${JSON_RESULT} | jq -rc ". |= .+ {\"credentials_file\": {\"AccountTag\": \"${CF_ACCOUNT_ID}\",\"TunnelID\": \"${CF_TUNNEL_ID}\",\"TunnelName\": \"${CF_TUNNEL_NAME}\",\"TunnelSecret\": \"${CF_TUNNEL_SECRET}\"}}")
      echo ${JSON_RESULT} | jq
    fi
    CF_TUNNEL_ID=$(echo ${JSON_RESULT} | jq -rc ".id // .result.id")
    CREDENTIALS_FILE=$(echo ${JSON_RESULT} | jq -rc ".credentials_file // .result.credentials_file")
    echo "**** Saving cloudflare tunnel (${CF_TUNNEL_NAME}) credentials json... ****"
    if [ ! -d "/etc/cloudflared/" ]; then
      mkdir -p "/etc/cloudflared";
    fi
    printf "${CREDENTIALS_FILE}" > "/etc/cloudflared/${CF_TUNNEL_ID}.json"
    echo ${JSON_RESULT} | jq -r ".result.credentials_file"
    echo "**** Cloudflare tunnel (${CF_TUNNEL_NAME}) credentials saved to /etc/cloudflared/${CF_TUNNEL_ID}.json ****"

    echo "**** Cloudflare CertFile check ***"
    echo "${CF_ORIGIN_CERT}" | base64 -d > /etc/cloudflared/cert.pem
    cat /etc/cloudflared/cert.pem

    echo "**** Generating config.yml for cloudflare tunnel (${CF_TUNNEL_NAME})... ****"
    printf "tunnel: ${CF_TUNNEL_ID}\n" > "/etc/cloudflared/config.yml"
    printf "credentials-file: /etc/cloudflared/${CF_TUNNEL_ID}.json\n" >> "/etc/cloudflared/config.yml"
    printf "no-autoupdate: true\n\n" >> "/etc/cloudflared/config.yml"
    if test -f "$CF_TUNNEL_CONFIG_FILE"; then
      echo "*** Found config file contents - copying to /etc/cloudflared/config.yaml ***"
      cat "${CF_TUNNEL_CONFIG_FILE}" >> "/etc/cloudflared/config.yml"
    else
      echo "*** Using config string - printfing to /etc/cloudflared/config.yaml ***"
      printf "${CF_TUNNEL_CONFIG}" >> "/etc/cloudflared/config.yml"
    fi
    /tmp/yq e /etc/cloudflared/config.yml
    echo "**** Config for cloudflare tunnel (${CF_TUNNEL_NAME}) saved to /etc/cloudflared/config.yml ****"

    echo "**** Validating cloudflared tunnel rules... ****"
    cloudflared tunnel ingress validate

    echo "**** Updating cloudflare zone... ****"
    for HOSTNAME in $(/tmp/yq e ".ingress.[].hostname" /etc/cloudflared/config.yml); do
      if [ ! "${HOSTNAME}" = "null" ]; then
        echo "**** Searching zone for hostname (${HOSTNAME}) via API... ****"
        JSON_RESULT=$(curl -sX \
          GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${HOSTNAME}&type=CNAME&match=all" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json")

        COUNT=$(echo ${JSON_RESULT} | jq -rc ".result_info.count")
        if [[ ${COUNT} -eq 0 ]]; then
          echo "**** Creating new CNAME for hostname (${HOSTNAME}) via API... ****"
          JSON_RESULT=$(curl -sX \
            POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
              -H "Authorization: Bearer ${CF_API_TOKEN}" \
              -H "Content-Type: application/json" \
              --data "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}")
          echo ${JSON_RESULT} | jq
        else
          echo "**** Updating existing CNAME for hostname (${HOSTNAME}) via API... ****"
          RECORD_ID=$(echo ${JSON_RESULT} | jq -rc ".result[].id")
          JSON_RESULT=$(curl -sX \
            PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${RECORD_ID}" \
              -H "Authorization: Bearer ${CF_API_TOKEN}" \
              -H "Content-Type: application/json" \
              --data "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}")
          echo ${JSON_RESULT} | jq
        fi
      fi
    done
  fi
else
  echo "**** Cloudflare parameters blank or missing, skipped cloudflare tunnel setup ****"
  rm -rf /etc/services.d/cloudflared
fi

cloudflared tunnel --config=${CF_TUNNEL_CONFIG_FILE} run ${CF_TUNNEL_NAME}
echo "**** Cloudflared setup script done, exiting... ****"
