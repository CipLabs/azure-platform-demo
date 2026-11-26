# Custom Domain & Certificate Setup - Container Apps

## Quick Reference for Interview

### Question: "How would you attach a custom domain and certificate?"

**Answer Strategy**: Lead with the simplest, most production-ready approach (Azure-managed certificates), then explain alternatives.

---

## Three Approaches

### 🥇 Option 1: Azure-Managed Certificate (Recommended)

**Best for**: Most production workloads, minimum operational overhead

**Setup**:
```bash
# 1. Create Azure DNS zone for your domain
az network dns zone create \
  --resource-group rg-helloworld-prod-uks-001 \
  --name example.com

# 2. Create managed certificate (auto-issued via ACME)
az containerapp env certificate create \
  --name cae-hw-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --certificate-name cert-example-com \
  --hostname example.com

# 3. Bind custom domain to Container App
az containerapp custom-domain add \
  --name ca-helloworld-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --domain-name example.com \
  --certificate-name cert-example-com

# 4. Update DNS (point nameservers or CNAME to Azure DNS)
# In your registrar (GoDaddy, Namecheap, etc):
#   example.com CNAME → ca-helloworld-prod-uks-001--xxxx.azurecontainerapps.io
```

**Benefits**:
- ✅ Automatic renewal (30 days before expiry)
- ✅ Zero manual cert management
- ✅ Free (included with Container Apps)
- ✅ Works with custom domains seamlessly

**Limitations**:
- One domain per certificate (wildcard not supported by Azure-managed)

---

### 🥈 Option 2: Key Vault + BYOC (Bring Your Own Certificate)

**Best for**: Wildcard certificates, specific CA requirements, centralized cert management

**Setup**:
```bash
# 1. Generate or buy SSL certificate (.pfx format)
# Example: Get wildcard cert from Let's Encrypt or commercial CA

# 2. Create Key Vault (or use existing)
az keyvault create \
  --name kv-helloworld-prod \
  --resource-group rg-helloworld-prod-uks-001 \
  --sku standard

# 3. Import certificate to Key Vault
az keyvault certificate import \
  --vault-name kv-helloworld-prod \
  --name cert-wildcard-example-com \
  --file certificate.pfx \
  --password <cert-password>

# 4. Grant Container App permission to Key Vault
# (Requires managed identity of Container App)
az keyvault set-policy \
  --name kv-helloworld-prod \
  --object-id <container-app-managed-identity-oid> \
  --secret-permissions get list \
  --certificate-permissions get list

# 5. Bind custom domain with KV certificate
az containerapp custom-domain add \
  --name ca-helloworld-prod-uks-001 \
  --resource-group rg-helloworld-prod-uks-001 \
  --domain-name *.example.com \
  --certificate-id /subscriptions/<sub-id>/resourceGroups/rg-helloworld-prod-uks-001/providers/Microsoft.KeyVault/vaults/kv-helloworld-prod/secrets/cert-wildcard-example-com
```

**Benefits**:
- ✅ Wildcard support (*.example.com)
- ✅ Control over certificate
- ✅ Works with any CA
- ✅ Centralized management (Key Vault)

**Limitations**:
- ❌ Manual renewal 30 days before expiry
- ❌ More operational overhead
- ❌ RBAC/Key Vault access control needed

---

### 🥉 Option 3: Front Door + Managed Certificate (Enterprise)

**Best for**: WAF protection, DDoS mitigation, multi-region, multiple domains

**Architecture**:
```
Internet Users
        ↓
    [Azure Front Door] ← Handles HTTPS, WAF, DDoS, CDN
        ↓
 [Container App] ← Can be internal (private)
```

**Setup**:
```bash
# 1. Create Azure Front Door
az afd profile create \
  --resource-group rg-helloworld-prod-uks-001 \
  --profile-name afd-helloworld \
  --sku Premium

# 2. Create origin (backend)
az afd origin create \
  --resource-group rg-helloworld-prod-uks-001 \
  --profile-name afd-helloworld \
  --origin-group-name og-helloworld \
  --origin-name ca-helloworld \
  --origin-host-header ca-helloworld-prod-uks-001--xxxx.azurecontainerapps.io \
  --priority 1 \
  --weight 1000 \
  --http-port 80 \
  --https-port 443

# 3. Create HTTPS listener (handles cert)
az afd rule set create \
  --resource-group rg-helloworld-prod-uks-001 \
  --profile-name afd-helloworld \
  --rule-set-name helloworld-rules

# 4. Configure custom domain + managed cert
az afd custom-domain create \
  --resource-group rg-helloworld-prod-uks-001 \
  --profile-name afd-helloworld \
  --custom-domain-name example-com \
  --host-name example.com \
  --certificate-type ManagedCertificate
```

**Benefits**:
- ✅ Single certificate for multiple domains
- ✅ WAF (Web Application Firewall) included
- ✅ DDoS Protection (Standard included, Advanced available)
- ✅ Global CDN caching
- ✅ Container App stays private (security benefit)

**Limitations**:
- ❌ Significant cost (~$438/month minimum)
- ❌ More complex architecture
- ❌ Adds ~10-50ms latency (acceptable for most)

---

## Terraform Example (Option 1 - Recommended)

```hcl
# Azure DNS Zone for custom domain
resource "azurerm_dns_zone" "helloworld" {
  name                = "example.com"
  resource_group_name = azurerm_resource_group.helloworld_rg.name
}

# Managed certificate (auto-issued via ACME)
resource "azurerm_container_app_environment_certificate" "helloworld" {
  name                           = "cert-helloworld-prod"
  container_app_environment_id   = azurerm_container_app_environment.helloworld_cae.id
  certificate_blob_base64        = ""  # Azure will auto-generate
  certificate_password           = ""  # Not needed for managed
}

# Bind custom domain to Container App
resource "azurerm_container_app_custom_domain" "helloworld" {
  name                                     = "example.com"
  container_app_id                         = azurerm_container_app.helloworld_app.id
  container_app_environment_certificate_id = azurerm_container_app_environment_certificate.helloworld.id
}

# Output the FQDN for DNS configuration
output "custom_domain_fqdn" {
  value = "example.com"
}

output "container_app_target" {
  value = azurerm_container_app.helloworld_app.ingress[0].fqdn
}
```

**DNS Configuration**:
In your domain registrar (GoDaddy, Namecheap, Route53, etc):
```
example.com CNAME → ca-helloworld-prod-uks-001--6alzv7d.politeriver-012b0bda.uksouth.azurecontainerapps.io
```

---

## Interview Talking Points

### Why Azure-Managed Certificates?

1. **Security**: Certificate is managed by Azure, never exposed in code
2. **Automation**: Auto-renewal removes operational burden
3. **Cost**: Free (included with Container Apps)
4. **Alignment**: Fits our zero-trust, secrets-free architecture
5. **Simplicity**: Minimal configuration required

### When to Use Alternatives?

- **Key Vault (Option 2)**: If you need wildcard certs or specific CA requirements
- **Front Door (Option 3)**: If you need WAF + DDoS for public APIs

### Security Best Practices

✅ **DO**:
- Use HTTPS everywhere (Azure-managed or Key Vault)
- Rotate certificates before expiry
- Use private DNS zones for internal traffic
- Keep Container App FQDN obscured (use custom domain)

❌ **DON'T**:
- Store certificate passwords in code or git
- Use self-signed certificates in production
- Expose Container App FQDN publicly (use custom domain instead)
- Forget to update DNS when migrating domains

---

## Cost Summary

| Option | Monthly Cost | Setup Time | Automation |
|--------|-------------|-----------|-----------|
| Azure-Managed | $0 | 10 mins | 100% (auto-renewal) |
| Key Vault BYOC | $0.50-6 | 15 mins | 50% (manual renewal) |
| Front Door | $438+ | 30 mins | 100% (auto-renewal) |

---

## Checklist for Implementation

- [ ] Domain registered (GoDaddy, Namecheap, etc)
- [ ] Azure DNS zone created (or nameservers updated)
- [ ] Managed certificate created in Container Apps
- [ ] Custom domain bound to Container App
- [ ] DNS CNAME record added in registrar
- [ ] DNS propagation verified (nslookup/dig)
- [ ] HTTPS working: `curl -I https://example.com`
- [ ] Certificate auto-renewal monitored (optional alerts)

---

**Last Updated**: November 2026  
**Author**: Azure Platform Engineering Team
