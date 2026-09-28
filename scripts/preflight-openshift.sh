#!/usr/bin/env bash
# Read-only preflight for a real OpenShift cluster (Level 4 and Level 5 in TESTING.md).
#
# It NEVER changes the cluster: it only uses `get`, `auth can-i`,
# `--dry-run=server` and `diff`. The cluster's own admission webhooks, quotas,
# SCCs and policies (Gatekeeper, Kyverno, ...) check every manifest, and
# nothing is created.
#
# Usage:
#   oc login ...              # log in to the target cluster first
#   scripts/preflight-openshift.sh <namespace>
#
# Exit code: 0 = no blockers, 1 = at least one FAIL. WARNs are for a human to review.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${1:-}"
FAILS=0
WARNS=0

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; WARNS=$((WARNS + 1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

[ -n "$NS" ] || { echo "usage: $0 <namespace>"; exit 2; }
command -v oc >/dev/null || { echo "oc is not installed"; exit 2; }

case "$NS" in
  default|kube-*|openshift*)
    echo "Refusing to target system namespace '$NS'. Use a dedicated project."; exit 2 ;;
esac

step "Target (make sure this is the cluster you mean)"
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run 'oc login' first."; exit 2; }
echo "User:      $(oc whoami)"
echo "Server:    $(oc whoami --show-server)"
echo "Namespace: $NS"
echo "Version:   $(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo unknown)"
if [ -t 0 ] && [ "${YES:-}" != "true" ]; then
  read -r -p "Continue with read-only checks against this cluster? [y/N] " ok
  [ "$ok" = "y" ] || exit 1
fi

step "Namespace and permissions"
if oc get namespace "$NS" >/dev/null 2>&1; then
  pass "namespace $NS exists"
else
  bad "namespace $NS does not exist (ask the cluster owner to create it; this script will not)"
fi
for check in "create deployments.apps" "create services" "create routes.route.openshift.io" \
             "create virtualmachines.kubevirt.io" "create pipelines.tekton.dev" \
             "create rolebindings.rbac.authorization.k8s.io"; do
  # shellcheck disable=SC2086
  if [ "$(oc auth can-i $check -n "$NS" 2>/dev/null)" = "yes" ]; then
    pass "can $check"
  else
    warn "cannot $check in $NS"
  fi
done

step "Platform features this repo needs"
has_api() { oc api-resources --api-group="$1" -o name 2>/dev/null | grep -q "^$2"; }
feature() {  # feature <group> <resource> <level-if-missing> <ok message> <missing message>
  if has_api "$1" "$2"; then pass "$4"; else "$3" "$5"; fi
}
feature route.openshift.io routes bad "Routes (OpenShift)" "no Route API: this is not OpenShift"
feature kubevirt.io virtualmachines warn "OpenShift Virtualization / KubeVirt installed" \
  "OpenShift Virtualization not installed: VM manifests will be skipped"
feature cdi.kubevirt.io datavolumes warn "CDI installed (virtctl image-upload will work)" \
  "CDI not installed: you cannot upload the EC2 disk"
feature tekton.dev pipelines warn "OpenShift Pipelines / Tekton installed" \
  "OpenShift Pipelines not installed: pipeline manifests will be skipped"
feature argoproj.io applications warn "OpenShift GitOps / ArgoCD installed" \
  "OpenShift GitOps not installed"
if has_api templates.gatekeeper.sh constrainttemplates; then
  pass "Gatekeeper installed"
  oc get constrainttemplate k8spspprivilegedcontainer >/dev/null 2>&1 \
    && warn "a k8spspprivilegedcontainer template ALREADY exists: coordinate with the platform team, do not overwrite it"
else
  warn "Gatekeeper not installed: the policy in policies/ cannot be applied"
fi
has_api kyverno.io clusterpolicies && warn "Kyverno is also installed: its policies apply too (checked by the dry runs below)"
if oc get storageclass -o name 2>/dev/null | grep -q .; then
  pass "default storage: $(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || echo none)"
else
  warn "no StorageClass visible: the VM disk PVC may stay Pending"
fi

step "Images"
placeholders=$(grep -rhoE 'quay\.io/your-repo[^" ]*' "$ROOT"/containerized-apps "$ROOT"/tekton-pipeline 2>/dev/null | sort -u)
if [ -n "$placeholders" ]; then
  printf '%s\n' "$placeholders"
  warn "replace the quay.io/your-repo placeholders with a registry this cluster can pull from"
else
  pass "no placeholder images left"
fi

dry_apply() {  # dry_apply <label> <files...>
  local label="$1"; shift
  local out
  if out=$(oc apply -n "$NS" --dry-run=server "$@" 2>&1); then
    pass "$label accepted by the API server, webhooks and policies"
  else
    bad "$label rejected:"; printf '%s\n' "$out"
  fi
}

step "Server-side dry runs (nothing is created)"
APP="$ROOT/containerized-apps/flask-app"
dry_apply "Flask app" -f "$APP/k8s-deploy.yaml" -f "$APP/route.yaml"
if has_api tekton.dev pipelines; then
  dry_apply "Tekton RBAC, tasks and pipeline" -f "$ROOT/tekton-pipeline/rbac.yaml" \
    -f "$ROOT/tekton-pipeline/build-task.yaml" -f "$ROOT/tekton-pipeline/deploy-task.yaml" \
    -f "$ROOT/tekton-pipeline/pipeline.yaml"
fi
if has_api kubevirt.io virtualmachines; then
  dry_apply "VMs and disk PVC" -f "$ROOT/kubevirt-vms/"
fi
if has_api templates.gatekeeper.sh constrainttemplates; then
  dry_apply "Gatekeeper template" -f "$ROOT/policies/privileged-constraint-template.yaml"
fi

step "What would change (oc diff)"
oc diff -n "$NS" -f "$APP/k8s-deploy.yaml" -f "$APP/route.yaml"
case $? in
  0) pass "no changes: already matches the cluster" ;;
  1) warn "the diff above shows what a real apply would change: review it" ;;
  *) bad "oc diff failed" ;;
esac

step "Summary"
echo "$FAILS blocker(s), $WARNS warning(s). Nothing on the cluster was changed."
[ "$FAILS" -eq 0 ]
