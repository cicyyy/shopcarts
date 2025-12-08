# Kubernetes Ingress Configuration

This document describes the Ingress setup for the Shopcarts microservice in Kubernetes.

## Overview

The Ingress resource provides external access to the Shopcarts service from outside the Kubernetes cluster. It routes traffic to the Shopcarts Service, which in turn forwards requests to the Shopcarts Pods.

## Configuration

### Ingress Resource

The Ingress is defined in `k8s/ingress.yaml`:

- **Name**: `shopcarts-ingress`
- **Ingress Controller**: Traefik (default in K3D)
- **Service**: Points to `shopcarts` service on port 80

### Access Methods

#### Method 1: Via LoadBalancer (K3D)

K3D automatically creates a LoadBalancer that maps port 8080 to port 80:

```bash
# Access the service
curl http://127.0.0.1:8080/shopcarts
curl http://127.0.0.1:8080/static/index.html
```

#### Method 2: Via Hostname

The Ingress also supports access via hostname `shopcarts.local`:

1. Add to `/etc/hosts`:
   ```bash
   echo "127.0.0.1 shopcarts.local" | sudo tee -a /etc/hosts
   ```

2. Access the service:
   ```bash
   curl http://shopcarts.local/shopcarts
   ```

## Deployment

The Ingress is automatically deployed when you run:

```bash
make deploy
```

Or manually:

```bash
kubectl apply -f k8s/ingress.yaml
```

## Verification

### Check Ingress Status

```bash
kubectl get ingress -n shopcarts
kubectl describe ingress shopcarts-ingress -n shopcarts
```

### Get Ingress URL

```bash
make url
```

This will display the Ingress URL that can be used for BDD tests.

## BDD Testing

The Ingress URL should be used as the `BASE_URL` environment variable in BDD tests:

```bash
# Get the Ingress URL
INGRESS_URL=$(make url | grep "http://" | head -1 | awk '{print $2}')

# Run BDD tests with Ingress URL
BASE_URL=$INGRESS_URL make bdd
```

Or set it directly:

```bash
export BASE_URL=http://127.0.0.1:8080
make bdd
```

## Endpoints

Once the Ingress is deployed, the following endpoints are accessible:

- **REST API**: `http://127.0.0.1:8080/shopcarts`
- **Web UI**: `http://127.0.0.1:8080/static/index.html`
- **Health Check**: `http://127.0.0.1:8080/health`
- **Service Root**: `http://127.0.0.1:8080/`

## TLS Configuration (Optional)

To enable TLS termination, uncomment the TLS section in `k8s/ingress.yaml` and configure certificates:

```yaml
tls:
  - hosts:
      - shopcarts.local
    secretName: shopcarts-tls
```

Then create the TLS secret:

```bash
kubectl create secret tls shopcarts-tls \
  --cert=path/to/cert.pem \
  --key=path/to/key.pem \
  -n shopcarts
```

## Troubleshooting

### Ingress Not Accessible

1. Check if Ingress Controller is running:
   ```bash
   kubectl get pods -n kube-system | grep traefik
   ```

2. Check Ingress status:
   ```bash
   kubectl get ingress -n shopcarts
   kubectl describe ingress shopcarts-ingress -n shopcarts
   ```

3. Check Service:
   ```bash
   kubectl get svc -n shopcarts
   kubectl get endpoints -n shopcarts
   ```

4. Check Pods:
   ```bash
   kubectl get pods -n shopcarts
   kubectl logs -n shopcarts deployment/shopcarts
   ```

### Port Already in Use

If port 8080 is already in use, modify the K3D cluster creation in `Makefile`:

```makefile
--port '8081:80@loadbalancer'
```

Then update the BASE_URL accordingly.

