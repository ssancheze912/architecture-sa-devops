# Onboarding de Nuevo Servicio

## Infraestructura (deploy repo)

1. Agregar a `project-config.dev.yaml` (namespaces, services con roles IAM)
2. Artifact Registry repo en TF (`terraform/modules/artifact-registry/`)
3. Service account + IAM bindings en TF (`terraform/modules/iam/`)
4. Namespace K8s en TF (`terraform/modules/namespaces/`)
5. HTTPRoute en `routes/dev/{service-name}-route.yaml` — ver patrón en `docs/mfe-conventions.md`
5b. **HealthCheckPolicy obligatoria:** crear `healthcheck/{service-name}-api-hc.yaml` (TCP:8080) y `healthcheck/{service-name}-mfe-hc.yaml` (TCP:80). Sin ella, el GKE L7 LB usa HTTP en puerto 80 para todos los backends → la API en puerto 8080 queda unhealthy → 503. Ver patrón en `healthcheck/base-config-api-hc.yaml`.
6. Componentes Dapr en `dapr/{service-name}/` (statestore, pubsub, secretstore)
7. Pub/Sub topics + subscriptions en `terraform/environments/dev/main.tf`
8. Actualizar import-map si es MFE: `import-map/import-map.yaml`
9. **Actualizar CLAUDE.md, .gemini/GEMINI.md y docs/troubleshooting.md**

## Repo del servicio (`SiesaTeams/business-financiero-{service-name}`)

10. Crear repo con estructura `src/backend/` + `src/frontend/` (si tiene MFE)
11. Copiar templates CI/CD de `cicd-templates/` al repo del servicio
12. **MFE — vite.config.ts obligatorio:** ver `docs/mfe-conventions.md`
13. **MFE — Dockerfile obligatorio:** `ARG VITE_MODE=production`, `ARG VITE_API_BASE_URL=/api`
14. **MFE — nunca usar `/api/v1/` hardcodeado.** Todo via `apiClient` o `createFetcher('/api')`
15. **MFE — `client.ts`:** `baseURL: import.meta.env.VITE_API_BASE_URL || '/api/v1'`
16. Configurar Dapr sidecar en `k8s/base/deployment-api.yaml` (anotaciones + sidecar cloud-sql-proxy)
17. Secret en Secret Manager: `{service-name}-dev-db-connection`
