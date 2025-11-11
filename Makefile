# These can be overidden with env vars.
REGISTRY ?= docker.io
ORG ?= your-username
IMAGE_NAME ?= shopcarts
IMAGE_TAG ?= 1.0
IMAGE ?= $(REGISTRY)/$(ORG)/$(IMAGE_NAME):$(IMAGE_TAG)
PLATFORM ?= "linux/amd64,linux/arm64"
CLUSTER ?= nyu-devops
LOCAL_REGISTRY_HOST ?= registry.localhost
LOCAL_REGISTRY_PORT ?= 5001
LOCAL_REGISTRY ?= $(LOCAL_REGISTRY_HOST):$(LOCAL_REGISTRY_PORT)
BASE_URL ?= http://127.0.0.1:8080

.SILENT:

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: all
all: help

##@ Development

.PHONY: clean
clean:	## Removes all dangling build cache
	$(info Removing all dangling build cache..)
	-docker rmi $(IMAGE)
	docker image prune -f
	docker buildx prune -f

.PHONY: install
install: ## Install Python dependencies
	$(info Installing dependencies...)
	sudo pipenv install --system --dev

.PHONY: lint
lint: ## Run the linter
	$(info Running linting...)
	-flake8 service tests --count --select=E9,F63,F7,F82 --show-source --statistics
	-flake8 service tests --count --max-complexity=10 --max-line-length=127 --statistics
	-pylint service tests --max-line-length=127

.PHONY: test
test: ## Run the unit tests
	$(info Running tests...)
	export RETRY_COUNT=1; pytest --pspec --cov=service --cov-fail-under=95 --disable-warnings

.PHONY: bdd
bdd: ## Run the Behave Selenium UI scenarios (service must be running)
	$(info Running BDD UI tests against $(BASE_URL)...)
	BASE_URL=$(BASE_URL) pipenv run behave

.PHONY: run
run: ## Run the service
	$(info Starting service...)
	honcho start

.PHONY: secret
secret: ## Generate a secret hex key
	$(info Generating a new secret key...)
	python3 -c 'import secrets; print(secrets.token_hex())'

##@ Kubernetes

.PHONY: cluster
cluster: ## Create a K3D Kubernetes cluster with load balancer and registry
	@if k3d cluster list | grep -q $(CLUSTER); then \
		echo "Cluster $(CLUSTER) already exists. Use 'make cluster-rm' to remove it first."; \
	else \
		echo "Creating Kubernetes cluster $(CLUSTER) with registry and 2 agents..."; \
		k3d cluster create $(CLUSTER) --servers 1 --agents 2 \
			--registry-create $(LOCAL_REGISTRY_HOST):0.0.0.0:$(LOCAL_REGISTRY_PORT) \
			--port '8080:80@loadbalancer' \
			--timeout 300s --no-rollback 2>&1 || true; \
		echo "Writing kubeconfig..."; \
		k3d kubeconfig merge $(CLUSTER) --kubeconfig-switch-context 2>&1 || \
			k3d kubeconfig write $(CLUSTER) --kubeconfig-switch-context 2>&1 || true; \
		kubectl wait --context k3d-$(CLUSTER) node --all --for=condition=Ready --timeout=180s || exit 1; \
		echo "Cluster ready."; \
	fi

.PHONY: cluster-rm
cluster-rm: ## Remove a K3D Kubernetes cluster
	$(info Removing Kubernetes cluster $(CLUSTER)...)
	k3d cluster delete $(CLUSTER)

.PHONY: deploy
deploy: build ## Deploy the service on local Kubernetes
	$(info Publishing image to local registry and deploying...)
	@if ! getent hosts $(LOCAL_REGISTRY_HOST) >/dev/null; then \
		echo "Adding $(LOCAL_REGISTRY_HOST) to /etc/hosts so Docker can reach the local registry..."; \
		echo "127.0.0.1 $(LOCAL_REGISTRY_HOST)" | sudo tee -a /etc/hosts >/dev/null; \
	fi
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(LOCAL_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(LOCAL_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/postgres/service.yaml
	kubectl apply -f k8s/postgres/statefulset.yaml
	kubectl apply -f k8s/shopcarts-configmap.yaml
	kubectl apply -f k8s/shopcarts-deployment.yaml
	kubectl -n shopcarts set image deployment/shopcarts \
	  shopcarts=$(LOCAL_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	kubectl apply -f k8s/ingress.yaml
	@echo "Waiting for workloads..."
	@kubectl -n shopcarts rollout status statefulset/postgres --timeout=300s
	@kubectl -n shopcarts rollout status deployment/shopcarts --timeout=300s || { \
	  echo "[DIAG] shopcarts not ready"; \
	  kubectl -n shopcarts get pods,svc; \
	  kubectl -n shopcarts describe deploy/shopcarts | sed -n '1,160p'; \
	  exit 1; }
	@echo "Deploy complete. Access via http://127.0.0.1:8080"

.PHONY: url
url: ## Show the ingress URL
	$(info Getting ingress URL...)
	@kubectl get ingress -n shopcarts -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null && echo "" || kubectl get ingress -n shopcarts -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "No ingress found. Run 'make deploy' first."

############################################################
# COMMANDS FOR BUILDING THE IMAGE
############################################################

##@ Image Build and Push

.PHONY: init
init: export DOCKER_BUILDKIT=1
init:	## Creates the buildx instance
	$(info Initializing Builder...)
	-docker buildx create --use --name=qemu
	docker buildx inspect --bootstrap

.PHONY: build
build:	## Build the project container image for local platform
	$(info Building $(IMAGE)...)
	docker build --rm --pull --tag $(IMAGE) --tag $(IMAGE_NAME):$(IMAGE_TAG) .

.PHONY: push
push: ## Push the image to the local registry
	$(info Pushing $(IMAGE_NAME):$(IMAGE_TAG) to local registry...)
	@if ! getent hosts $(LOCAL_REGISTRY_HOST) >/dev/null; then \
		echo "Adding $(LOCAL_REGISTRY_HOST) to /etc/hosts so Docker can reach the local registry..."; \
		echo "127.0.0.1 $(LOCAL_REGISTRY_HOST)" | sudo tee -a /etc/hosts >/dev/null; \
	fi
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(LOCAL_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(LOCAL_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: cluster-import-image
cluster-import-image: build ## Import the image to the K3D cluster
	$(info Importing $(IMAGE_NAME):$(IMAGE_TAG) to cluster $(CLUSTER)...)
	@k3d images import $(IMAGE_NAME):$(IMAGE_TAG) -c $(CLUSTER)

.PHONY: buildx
buildx:	## Build multi-platform image with buildx
	$(info Building multi-platform image $(IMAGE) for $(PLATFORM)...)
	docker buildx build --file Dockerfile --pull --platform=$(PLATFORM) --tag $(IMAGE) --push .

.PHONY: remove
remove:	## Stop and remove the buildx builder
	$(info Stopping and removing the builder image...)
	docker buildx stop
	docker buildx rm
