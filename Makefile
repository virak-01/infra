# Every command in the docs, in one place, so README and reality cannot drift.
# Override any variable on the command line: `make build TAG=1.0.1`.

REGISTRY ?= ranvirak
TAG      ?= 1.0.0
ENV      ?= prod
SITES    := employee user

OVERLAY  := k8s/overlays/$(ENV)
NS       := company

.DEFAULT_GOAL := help
.PHONY: help envs render validate diff deploy build push rollout

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  vars: REGISTRY=$(REGISTRY) TAG=$(TAG) ENV=$(ENV)"
	@echo "  note: staging and prod are separate clusters — check your context"
	@echo "        before deploy/diff: kubectl config current-context"

envs: ## Show what each environment is pinned to
	@for o in k8s/overlays/*/; do \
	  printf "\033[36m%s\033[0m\n" "$$(basename $$o)"; \
	  kubectl kustomize $$o \
	    | grep -E '^      - image:|^  replicas:' \
	    | sed 's/^ *- image: /  image    /; s/^  replicas: /  replicas /'; \
	done

render: ## Print the manifests this repo would apply
	kubectl kustomize $(OVERLAY)

validate: ## Render and check against the Kubernetes API schema (what CI runs)
	@command -v kubeconform >/dev/null \
	  || { echo "kubeconform not installed: brew install kubeconform"; exit 1; }
	kubectl kustomize $(OVERLAY) | kubeconform -strict -summary -

diff: ## Show what applying would change in the live cluster
	@echo "context: $$(kubectl config current-context)"
	@# kubectl diff exits 1 when differences exist, which is the normal case and
	@# not an error. Anything above 1 is a real failure and still propagates.
	@kubectl diff -k $(OVERLAY) || test $$? -eq 1

deploy: ## Apply the overlay
	@echo "context: $$(kubectl config current-context)"
	kubectl apply -k $(OVERLAY)
	kubectl -n $(NS) get pods,svc,ingress

build: ## Build both site images
	@for site in $(SITES); do \
	  echo "==> $$site"; \
	  docker build -t $(REGISTRY)/$$site-web:$(TAG) apps/$$site || exit 1; \
	done

push: ## Push both site images (needs a Read & Write Docker Hub token)
	@for site in $(SITES); do \
	  docker push $(REGISTRY)/$$site-web:$(TAG) || exit 1; \
	done

rollout: ## Wait for both Deployments to finish rolling out
	@for site in $(SITES); do \
	  kubectl -n $(NS) rollout status deployment/$$site-web || exit 1; \
	done
