# NGINX Ingress Controller Deployment

## Overview

NGINX Ingress Controller handles HTTP/HTTPS routing for Kubernetes services.

## Configuration

- **Namespace**: ingress-nginx
- **Chart**: ingress-nginx (kubernetes.github.io)
- **Version**: 4.10.0

## Features

- TLS termination with Let's Encrypt (via cert-manager)
- Path-based routing
- Rate limiting
- WebSocket support

## TLS Certificates

Certificates are managed by cert-manager with Let's Encrypt:
- Uses DNS-01 challenge with Cloudflare
- Auto-renewal 30 days before expiry

## Service

- **Type**: LoadBalancer
- **External IPs**: 192.168.0.212, 192.168.0.213, 192.168.0.214
- **Ports**: 80, 443

## Files

- `fleet.yaml` - Fleet configuration
- `manifests/namespace.yaml` - Namespace
- `manifests/values.yaml` - Helm values