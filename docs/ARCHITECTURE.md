# Architecture — IT-Stack ODOO

## Overview

Odoo provides ERP, accounting, HR, inventory, and purchasing modules, integrated with FreeIPA for employee directory sync.

## Role in IT-Stack

- **Category:** business
- **Phase:** 3
- **Server:** lab-biz1 (10.0.50.17)
- **Ports:** 8069 (HTTP), 8072 (WebSocket)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → odoo → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
