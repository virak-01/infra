# Every command in the docs, in one place, so README and reality cannot drift.
# Override any variable on the command line: `make deploy ENV=staging`.
#
# This repo deploys images; it does not build them. The sites are built and
# pushed wherever their source lives, and the cluster pulls the tag named in
# k8s/overlays/<env>/kustomization.yaml. Nothing here needs Docker.

ENV      ?= prod
SITES    := employee user

OVERLAY  := k8s/overlays/$(ENV)
NS       := company

AWS_REGION   ?= us-east-1
ECR_REGISTRY ?= 043309361013.dkr.ecr.$(AWS_REGION).amazonaws.com

.DEFAULT_GOAL := help
.PHONY: help envs current render validate diff deploy rollout ecr-secret

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  vars: ENV=$(ENV)   (overlays: $$(ls k8s/overlays | tr '\n' ' '))"
	@echo "  note: staging and prod are separate clusters — check your context"
	@echo "        before deploy/diff: kubectl config current-context"

envs: ## Show what each environment is pinned to
	@for o in k8s/overlays/*/; do \
	  printf "\033[36m%s\033[0m\n" "$$(basename $$o)"; \
	  kubectl kustomize $$o \
	    | grep -E '^      - image:|^  replicas:' \
	    | sed 's/^ *- image: /  image    /; s/^  replicas: /  replicas /'; \
	done

current: ## Show what the live cluster is running, and which overlay it matches
	@# ENV selects what you would apply, not what is deployed. Both overlays use
	@# the same namespace and resource names, so the only way to tell them apart
	@# is to compare the live objects against each overlay in turn.
	@echo "context:   $$(kubectl config current-context)"
	@echo "namespace: $(NS)"
	@echo
	@kubectl -n $(NS) get deploy -o \
	  jsonpath='{range .items[*]}  {.metadata.name}{"  x"}{.spec.replicas}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}' \
	  2>/dev/null || echo "  (no deployments — nothing applied yet)"
	@echo
	@# kubectl diff exits 0 only when the live state already equals the overlay.
	@# Exit 1 means differences; anything higher is a real error, so it is not
	@# treated as a mismatch.
	@matched=""; \
	for o in k8s/overlays/*/; do \
	  env=$$(basename $$o); \
	  kubectl diff -k $$o >/dev/null 2>&1; \
	  if [ $$? -eq 0 ]; then echo "  => live cluster matches: $$env"; matched=1; fi; \
	done; \
	[ -n "$$matched" ] || echo "  => matches no overlay exactly (mid-rollout, drifted, or a tag was edited)"

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

ecr-secret: ## Create/refresh the ECR pull Secret now (needed once, before the first deploy)
	@# The CronJob in k8s/base/ecr-credentials.yaml keeps this fresh every 8h,
	@# but cannot bootstrap it: pods pull before the first schedule fires.
	@# create --dry-run | apply so re-running is idempotent.
	@echo "context: $$(kubectl config current-context)"
	kubectl -n $(NS) create secret docker-registry ecr-creds \
	  --docker-server=$(ECR_REGISTRY) \
	  --docker-username=AWS \
	  --docker-password="$$(aws ecr get-login-password --region $(AWS_REGION))" \
	  --dry-run=client -o yaml | kubectl apply -f -

rollout: ## Wait for both Deployments to finish rolling out
	@for site in $(SITES); do \
	  kubectl -n $(NS) rollout status deployment/$$site-web || exit 1; \
	done
