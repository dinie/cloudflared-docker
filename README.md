## Cloudflared Docker

This docker image can be useful in scenarios where you wish to run a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/) (formerly Argo Tunnnel) alongside other containerised services on the same host. It runs an instance of `cloudflared` 

In a nutshell, the startup process is as follows:
- Build and install any dependencies, including `cloudflared` itself
- Generate the [config file](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/configuration/local-management/configuration-file/) used to run the tunnel, including [ingress rules](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/configuration/local-management/ingress/)
- Validate tunnel config
- Parse the provided ingress rules, creating any DNS records required by services using this tunnel instance

## Prerequisites
The following are required and must be set as environment variables at runtime:
- CF_ZONE_ID: Identifier of the DNS zone 
- CF_ACCOUNT_ID: You Cloudflare account ID
- CF_TUNNEL_NAME: Name to use when creating this tunnel (must be unique)
- CF_API_TOKEN: API Token (not key!) created via [CF dashboard](https://dash.cloudflare.com/profile/api-tokens) with the following permissions:
	- Cloudflare Tunnel:Edit, Cloudflare Tunnel:Read
	- Zone:Read, DNS:Read, Zone:Edit, DNS:Edit
- CF_TUNNEL_PASSWORD: Must be >= 32 characters long
- CF_TUNNEL_CONFIG_FILE: Path to configuration file relative to the Dockerfile. If unset then `./config.yml` will be used
- CF_ORIGIN_CERT: Base64 encoded [account certificate](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/tunnel-useful-terms/#certpem), used to authenticate your instance of `cloudflared` against your Cloudflare account. If you have not created a tunnel before, you can obtain this file by downloading `cloudflared` and running `cloudflared tunnel login` on your local machine.


## Architecture compatibility
Supports x86_64, ARM64, and ARMv7 architectures.  

## Usage

Included are examples using this service in a docker-compose file (I use this when deploying to a RaspberryPi via Balena), or to cloud-based infrastructure via Fly.io. In the fly.io example, it is possible to use the tunnel to point to services on a completely different host. 