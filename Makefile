# Thin wrapper over script/. THE LOGIC LIVES IN THE SCRIPTS, NOT HERE.
#
# This file used to hold every recipe inline. It now delegates, because two copies of
# the same commands would drift — and the header of the old version said exactly that
# about the docs: "so README and reality cannot drift". The same argument applies to a
# Makefile and a scripts directory.
#
# WHY KEEP THE MAKEFILE AT ALL, rather than deleting it:
#   * `make deploy ENV=uat` is in the README, in docs/, and in muscle memory;
#   * `make` with no arguments is a discoverable entry point;
#   * every recipe below is one line, so there is nothing here to drift.
#
# WHY THE SCRIPTS ARE THE IMPLEMENTATION, not the other way round:
#   * they run on a node, in CI, or over SSH, where make is often absent;
#   * they take --flags and can prompt — script/aws-creds.sh reads the secret from an
#     invisible prompt rather than a command line, which a Makefile cannot do;
#   * they are testable with `bash -n` and shellcheck;
#   * a shell error message names a file and a line, not a recipe.
#
# Both invocations are equivalent:
#   make deploy ENV=uat            ENV=uat ./script/deploy.sh
#
# Anything not listed here — --skip-cluster, --timeout, --stdin, --all — is a script
# flag. Run `./script/<name>.sh --help`.

ENV   ?= prod
CLOUD ?= aws
HOST  ?=

# Exported, not passed as arguments: the scripts read ENV, CLOUD and HOST from the
# environment, which is what makes the two invocation styles identical.
export ENV CLOUD HOST

.DEFAULT_GOAL := help
.PHONY: help envs current render validate diff deploy cluster rollout app-config aws-creds ecr-secret

help: ## Show this help
	@./script/help.sh

envs: ## Show what each environment is pinned to
	@./script/envs.sh

current: ## Show what ENV's namespace is running, and which overlay it matches
	@./script/current.sh

render: ## Print the manifests this repo would apply
	@./script/render.sh

validate: ## Render and check against the Kubernetes API schema (what CI runs)
	@./script/validate.sh

diff: ## Show what applying would change in the live cluster
	@./script/diff.sh

cluster: ## Apply k8s/cluster/<CLOUD> add-ons — one set per CLUSTER, not per ENV
	@./script/cluster.sh

deploy: ## Apply the overlay (HOST=<fqdn> overrides the Ingress host)
	@./script/deploy.sh

app-config: ## Load k8s/overlays/$(ENV)/app-config.env into the cluster as a ConfigMap
	@./script/app-config.sh

# NO LONGER TAKES THE SECRET ON THE COMMAND LINE. The script prompts without echoing,
# so the key never enters shell history — and it writes a mode-600 file rather than
# passing the value as a kubectl argument, where it would be visible in `ps`.
#
# For CI, set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment, or pipe
# a KEY=value file to `./script/aws-creds.sh --stdin`.
aws-creds: ## Store the IAM key the refresh job uses (prompts; never echoes)
	@./script/aws-creds.sh

ecr-secret: ## Mint the ECR pull Secret now, by running the refresh CronJob immediately
	@./script/ecr-secret.sh

rollout: ## Wait for every Deployment in ENV to finish rolling out
	@./script/rollout.sh
