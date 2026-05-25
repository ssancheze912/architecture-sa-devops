# Módulo Dapr (placeholder)

Este directorio existe como referencia arquitectónica pero **no contiene recursos Terraform**.

## Por qué Dapr no se gestiona con Terraform

Dapr se instala y actualiza vía Helm directamente desde el pipeline CI/CD:

```bash
helm upgrade --install dapr dapr/dapr \
  --namespace dapr-system \
  --version 1.17.3 \
  --wait --timeout 5m
```

Ver el job `k8s-manifests` en `.github/workflows/infra-pipeline-sandbox.yml`.

Usar `helm_release` en Terraform para Dapr requiere un provider `kubernetes` activo
durante el `plan` — lo que causa problemas con el patrón Pass 1/Pass 2 del pipeline
(el cluster aún no existe en Pass 1). La instalación vía CI/CD evita este problema.

## Qué sí se gestiona aquí (K8s manifests, no TF)

| Recurso | Archivo |
|---|---|
| Redis StatefulSet (con PVC) | `redis/statefulset.yaml` |
| Redis Service | `redis/service.yaml` |
| Dapr Components (statestore, pubsub, secretstore) | `dapr/{service}/` |

## Path a producción

- **Redis:** Migrar a Google Cloud Memorystore. El recurso `google_redis_instance`
  sí se gestionaría con Terraform en este módulo. Actualizar `redisHost` en los
  componentes Dapr de cada servicio.
- **Pub/Sub topics:** Los `google_pubsub_topic` y `google_pubsub_subscription` se
  crean en `terraform/environments/sandbox/main.tf` y deben existir antes de que
  los componentes Dapr los usen (`disableEntityManagement: true`).
