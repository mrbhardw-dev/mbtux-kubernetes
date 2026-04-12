# Cloudflare Origin Protection Configuration

## Overview

This document describes how to configure Cloudflare to protect your Kubernetes origin (Traefik) from direct access.

## Step 1: Generate Origin CA Certificate

1. **Navigate to Cloudflare Dashboard**
   - Go to: SSL/TLS → Origin Server

2. **Create Origin Certificate**
   - Click "Create Certificate"
   - Hostname: `*.mbtux.com`
   - Validity: 15 years (recommended)
   - Private key type: RSA 2048 (or ECDSA P-256)

3. **Download Certificates**
   - Save the Origin Certificate and Private Key
   - Update `infrastructure/traefik/02-origin-ca.yaml`

```bash
# Encode certificates for Kubernetes secret
echo -n "-----BEGIN CERTIFICATE-----" | base64 -w0
echo -n "-----BEGIN PRIVATE KEY-----" | base64 -w0
```

## Step 2: Enable Authenticated Origin Pulls

1. **Navigate to**: SSL/TLS → Origin Server
2. **Toggle**: "Authenticated Origin Pulls" to ON
3. **Note**: This forces all requests to present a valid Cloudflare-issued client certificate

## Step 3: Configure Firewall (Optional - Additional Protection)

For additional security, configure your network to only allow traffic from Cloudflare IPs:

| IP Range | Description |
|----------|-------------|
| 173.245.48.0/20 | Cloudflare primary |
| 103.21.244.0/20 | Cloudflare |
| 103.22.200.0/20 | Cloudflare |
| 103.31.4.0/20 | Cloudflare |
| 141.101.64.0/18 | Cloudflare |
| 108.162.192.0/18 | Cloudflare |
| 172.64.0.0/13 | Cloudflare |
| 172.80.0.0/10 | Cloudflare |
| 131.0.32.0/19 | Cloudflare |
| 151.101.0.0/16 | Cloudflare |
| 194.60.96.0/19 | Cloudflare |
| 190.93.240.0/20 | Cloudflare |
| 188.114.96.0/20 | Cloudflare |

Apply via network policy or firewall rules on the node/cluster.

## Step 4: WAF Configuration

In Cloudflare Dashboard → Security → WAF:

| Rule Type | Configuration |
|-----------|---------------|
| Rate Limiting | 100 requests/10 seconds per IP |
| Security Level | High |
| Bot Fight Mode | Enabled |
| Browser Challenge | Optional for suspicious traffic |

## Step 5: Traffic Manager (Optional - Blue/Green)

For canary deployments:

1. **Create Origin Pool**: `traefik-prod` (primary)
2. **Create Origin Pool**: `traefik-canary` (secondary)
3. **Configure Load Balancer**: Use percentage-based steering
4. **Health Check**: Configure on origin pools

## Verification Checklist

- [ ] Origin CA certificate generated and stored in Kubernetes
- [ ] Authenticated Origin Pulls enabled
- [ ] TLS mode set to "Full (Strict)"
- [ ] WAF rules configured
- [ ] DNS points to Cloudflare (proxied)
- [ ] Direct origin IP access blocked at network level