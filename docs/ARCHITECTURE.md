# Architecture Overview

This document explains the two architecture diagrams and how they relate to your deployment.

## Current Demo Deployment (architecture-current-demo.png)

This is what's actually running right now.

What you see:
- 2 Resource Groups (tfstate storage, workload app)
- Public Container App (accessible from internet via HTTPS)
- Public Storage Account (Terraform state)
- Public Container Registry (pulls images)
- GitHub Actions CI/CD (builds and deploys)

Why it's this way:
- Simplicity: Fewer resources, easier to understand
- Cost: No private endpoints, no premium networking
- Accessibility: Anyone can visit the app
- Learning: Shows core patterns without over-engineering

Security posture:
- HTTPS only (no plaintext traffic)
- Managed identity auth (no keys/passwords)
- Entra ID RBAC (fine-grained permissions)
- Health checks (auto-healing)
- Audit logging
- No secrets in GitHub (OIDC)

What it lacks:
- No network isolation (all public)
- No WAF (but basic Azure DDoS is free)
- No IP restrictions
- No private endpoints

This is appropriate for a demo because there's no sensitive data or customer traffic. The app does one thing: return a static response.

## Production Architecture (architecture-production.png)

This is what you'd build if you got customer signoff and security requirements.

What would change:

Network:
- VNet with private subnets
- Container App lives inside (no public IP)
- Private endpoints for ACR and storage
- Private DNS zones (internal service discovery)
- NSGs (stateful firewalls)

Security:
- Azure Front Door with WAF (blocks attacks)
- DDoS protection (included with Front Door)
- Rate limiting (100 req/IP/min)
- IP restrictions on Container App
- ACR accessible only via private endpoint
- Image vulnerability scanning (Snyk) in CI/CD
- ACR content trust (cryptographic image signing)

Secrets:
- Key Vault for runtime secrets
- Same OIDC approach, but runners in private ACA
- Entra ID auth unchanged

Cost:
- 2x higher than demo
- Front Door: ~$500/month
- Private endpoints: ~$200-300/month
- VNet: minimal cost
- Total: ~$300-400/month extra

Worth it when:
- Handling regulated data (PCI-DSS, HIPAA, SOC 2)
- Multi-tenant workload
- Compliance requirements
- Customer data at stake

Not worth it for:
- Internal demos
- Public content
- Stateless apps with no data
- One-off projects

## Migration Path

If you built the demo and want to move to production:

1. Build the network layer (VNet, subnets, NSGs)
   - 1-2 days of planning
   - Add private endpoint module to Terraform
   - Test connectivity

2. Move Container App into VNet
   - 1 day of testing
   - Update ingress settings
   - Verify scaling still works

3. Add Front Door
   - 2-3 days (config + testing)
   - Add WAF rules
   - Certificate setup

4. Lock down backend services
   - Set storage to private
   - Set ACR to private
   - Redirect through private endpoints

5. Update CI/CD
   - Move runners to private ACA
   - Update authentication flow
   - Test full pipeline

Estimated effort: 1-2 weeks for someone familiar with Azure

## Design Decisions Explained

Why Container Apps, not Kubernetes?
- Kubernetes is powerful but complex for stateless apps
- Container Apps gives 80% of the features with 20% of the complexity
- Good for demos, good for scaling, easier operations

Why OIDC, not stored secrets?
- Secrets in GitHub are a liability
- OIDC is industry standard for cloud auth
- Federated identity is more secure and auditable

Why ZRS storage for Terraform state?
- Terraform state is critical (losing it = losing infrastructure)
- ZRS (zone-redundant) means it survives zone failures
- Entra ID auth means only the right people can access it

Why split resource groups?
- Separates blast radius
- tfstate has long lifecycle, app updates frequently
- Different RBAC needs

Why managed identity for the app?
- No credentials to manage
- Fine-grained permissions per resource
- Audit trail in Azure AD

## Scaling Considerations

Current demo (2-5 replicas):
- Autoscales based on HTTP concurrent requests (100 requests per replica)
- Min 2 replicas for high availability, max 5 for cost control
- When concurrent requests exceed 100 per replica, a new replica is added
- When traffic drops, replicas scale down (but never below 2)
- Max cost per month: ~$40 for Container Apps

How scaling works:
- Scale rule: "If concurrent HTTP requests > 100 per replica, add another replica"
- Example: 250 concurrent requests = 3 replicas (250 ÷ 100 ≈ 2.5, rounds up)
- Scaling decisions happen every 30-60 seconds (automatic)
- No manual intervention needed

Scaling to production (10-20+ replicas):
- Add Front Door cache (reduces backend load)
- Add multi-region if needed (HA across geographies)
- Monitor actual traffic patterns first
- Could adjust concurrent_requests threshold based on observed load

Scaling further (100+ replicas):
- Consider Kubernetes (more efficient at scale)
- API Management for rate limiting and versioning
- Dedicated security infrastructure
- Multiple Container App environments for horizontal scaling

## Observability

What you get now:
- Container logs (stdout/stderr)
- Container metrics (CPU, memory, restarts)
- Scaling events
- Deployment history

What production would add:
- Distributed tracing (Application Insights)
- Custom metrics (business logic)
- Alerting on anomalies
- Security event logging
- Threat detection

The demo setup is enough to know if something is broken. Production setup tells you *why* it's broken and *who* accessed it.

## Supply Chain Security & Image Scanning

This is where the demo now has teeth.

Demo (what's here now):
- Snyk scanning in CI/CD pipeline
- Fails on CRITICAL vulnerabilities
- Blocks deployment if issues found
- Provides detailed report to developers
- Shows in GitHub security tab

Why this matters:
- Base images (alpine, ubuntu, etc.) can have CVEs
- Dependencies in app code can have CVEs
- Developers need to know *before* deploying
- Not catching these is how data breaches happen

Production would add:
- ACR content trust (cryptographic image signing)
- Registry scanning + policy enforcement
- Vulnerability exception approvals (for known-safe issues)
- Supply chain attestation (SLSA framework)

The workflow:
1. Developer pushes code
2. GitHub Actions builds image
3. Snyk scans the image
4. If CRITICAL CVE found: build fails, developer fixes
5. If HIGH CVE found: build passes but warning shows
6. If scan passes: image deployed to ACR
7. Container App pulls and runs

Snyk setup (required):
1. Create free Snyk account (snyk.io)
2. Add SNYK_TOKEN to GitHub repo secrets
3. Done - Snyk runs on every build

Cost:
- Free tier handles most projects
- Paid tier adds more scanning features (~$50-200/month)
- For the demo: free

This is where you show maturity: you're not just deploying code, you're scanning it for known issues. Most demos skip this step.

## Next Steps

For the interview:
- Explain the demo architecture honestly
- Discuss the production roadmap
- Mention specific costs (numbers matter)
- Explain the tradeoffs (security vs. complexity)

For real production:
- Get security/compliance requirements first
- Budget 2x the demo cost
- Plan 1-2 weeks for migration
- Use the production diagram as a reference architecture
