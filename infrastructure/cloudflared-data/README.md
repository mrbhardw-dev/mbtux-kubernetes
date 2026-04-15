# Cloudflared Tunnel Deployment

## Overview

Cloudflared tunnel routes traffic from Cloudflare edge to Kubernetes services.

## Configuration

- **Namespace**: cloudflared-data
- **Replicas**: 2
- **Image**: cloudflare/cloudflared:latest

## Secrets

- `cloudflared-token`: Tunnel token from Cloudflare Dashboard

## Management

Manage routing via Cloudflare Dashboard:
1. Go to Cloudflare Dashboard → Zero Trust → Networks → Tunnels
2. Select your tunnel
3. Add Public Hostnames for each service

## DNS Records

Ensure CNAME records point to `*.cfargotunnel.com` for routed domains.

## Files

- `manifests/namespace.yaml` - Namespace
- `manifests/secret.yaml` - Tunnel token
- `manifests/deployment.yaml` - Deployment