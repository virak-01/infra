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
.PHONY: help envs current render validate diff deploy rollout app-config aws-creds ecr-secret

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
	    | grep -oE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*[^[:space:]]+|^  replicas: .*' \
	    | sed 's/^ *-* *image: */  image    /; s/^  replicas: /  replicas /'; \
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

app-config: ## Load k8s/overlays/$(ENV)/app-config.env into the cluster as a ConfigMap
	@# The overlay has no configMapGenerator on purpose: app-config.env is
	@# gitignored, and Argo CD renders from git — a generator pointing at a file
	@# absent from the repo fails the whole sync. So the ConfigMap is applied
	@# out of band, the same way ecr-creds is.
	@#
	@# Trade-off: no content hash, so changing a value does NOT roll the pods.
	@# The rollout restart below is deliberate, not incidental.
	@test -f $(OVERLAY)/app-config.env \
	  || { echo "ERROR: $(OVERLAY)/app-config.env missing — copy app-config.env.example"; exit 1; }
	@echo "context: $$(kubectl config current-context)"
	kubectl -n $(NS) create configmap website-config \
	  --from-env-file=$(OVERLAY)/app-config.env \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo "→ restarting so the new values are picked up"
	@kubectl -n $(NS) rollout restart deploy/employee-web deploy/user-web 2>/dev/null || true

aws-creds: ## Store the IAM key the refresh job uses: make aws-creds AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
	@# Every line is @-prefixed: make echoes recipes by default, which would
	@# print the secret key into the terminal and any CI log.
	@test -n "$(AWS_ACCESS_KEY_ID)"     || { echo "ERROR: set AWS_ACCESS_KEY_ID=..."; exit 1; }
	@test -n "$(AWS_SECRET_ACCESS_KEY)" || { echo "ERROR: set AWS_SECRET_ACCESS_KEY=..."; exit 1; }
	@echo "context: $$(kubectl config current-context)"
	@kubectl -n $(NS) create secret generic aws-ecr-credentials \
	  --from-literal=AWS_ACCESS_KEY_ID='$(AWS_ACCESS_KEY_ID)' \
	  --from-literal=AWS_SECRET_ACCESS_KEY='$(AWS_SECRET_ACCESS_KEY)' \
	  $(if $(AWS_SESSION_TOKEN),--from-literal=AWS_SESSION_TOKEN='$(AWS_SESSION_TOKEN)',) \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo "stored. now run: make ecr-secret"

ecr-secret: ## Mint the ECR pull Secret now, by running the refresh CronJob immediately
	@# Runs the very job the 8-hourly schedule runs, so this needs no local AWS
	@# CLI: the credentials, the egress exception and the RBAC all live in the
	@# cluster. The CronJob cannot bootstrap itself — pods pull long before the
	@# first schedule fires — which is what this target is for.
	@echo "context: $$(kubectl config current-context)"
	kubectl -n $(NS) delete job ecr-credentials-refresh-now --ignore-not-found
	kubectl -n $(NS) create job ecr-credentials-refresh-now --from=cronjob/ecr-credentials-refresh
	@kubectl -n $(NS) wait --for=condition=complete --timeout=120s job/ecr-credentials-refresh-now \
	  || { echo; echo "job did not complete — logs:"; \
	       kubectl -n $(NS) logs job/ecr-credentials-refresh-now --all-containers --tail=30; exit 1; }
	@kubectl -n $(NS) get secret ecr-creds

rollout: ## Wait for both Deployments to finish rolling out
	@for site in $(SITES); do \
	  kubectl -n $(NS) rollout status deployment/$$site-web || exit 1; \
	done
