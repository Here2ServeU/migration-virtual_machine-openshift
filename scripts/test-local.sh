#!/usr/bin/env bash
# Local test harness for this repo. Nothing here touches a real OpenShift,
# IBM, or client cluster: everything runs in Docker and a throwaway kind cluster.
#
# Usage:
#   scripts/test-local.sh lint      # 1. static checks, no cluster needed (seconds)
#   scripts/test-local.sh image     # 2. build + run the container like OpenShift would
#   scripts/test-local.sh cluster   # 3. kind cluster: app, Gatekeeper, Tekton, KubeVirt
#   scripts/test-local.sh all       # 1 + 2 + 3
#   scripts/test-local.sh clean     # delete the kind cluster and test container
#
# Requires: docker, kind, kubectl, yamllint, kubeconform, curl. Optional: gator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-vm2ocp}"
IMAGE="${IMAGE:-flask-app:local}"
NS="${NS:-flask-app}"
GATEKEEPER_VERSION="${GATEKEEPER_VERSION:-v3.20.1}"
TEKTON_VERSION="${TEKTON_VERSION:-v1.6.0}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.9.0}"
SKIP_VM="${SKIP_VM:-false}"

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

need() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null || fail "missing tool: $bin"
  done
}

lint() {
  need yamllint kubeconform
  step "yamllint"
  yamllint -d '{extends: relaxed, rules: {line-length: disable}}' \
    "$ROOT"/argo-apps "$ROOT"/kubevirt-vms "$ROOT"/tekton-pipeline \
    "$ROOT"/policies "$ROOT"/containerized-apps/flask-app/*.yaml
  pass "YAML syntax"

  step "kubeconform (Kubernetes + CRD schemas)"
  # Tekton and Route schemas are not in the public catalog; the cluster
  # stage validates Tekton against the real API server instead.
  kubeconform -strict -summary -ignore-missing-schemas \
    -skip K8sPSPPrivilegedContainer \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$ROOT"/argo-apps "$ROOT"/kubevirt-vms "$ROOT"/tekton-pipeline "$ROOT"/policies \
    "$ROOT"/containerized-apps/flask-app/k8s-deploy.yaml \
    "$ROOT"/containerized-apps/flask-app/route.yaml
  pass "manifest schemas"

  step "Gatekeeper policy, offline (gator)"
  if ! command -v gator >/dev/null; then
    echo "gator not installed, skipping (the cluster stage still tests the policy)"
    return 0
  fi
  gator test -f "$ROOT"/policies -f "$ROOT"/tests/policy/privileged-pod.yaml </dev/null >/dev/null \
    && fail "privileged pod was NOT rejected"
  gator test -f "$ROOT"/policies -f "$ROOT"/tests/policy/system-namespace-pod.yaml </dev/null \
    || fail "pod in an excluded platform namespace was rejected"
  gator test -f "$ROOT"/policies -f "$ROOT"/containerized-apps/flask-app/k8s-deploy.yaml </dev/null \
    || fail "the Flask app violates the policy"
  pass "policy blocks privileged pods, allows platform namespaces and the app"
}

image() {
  need docker curl
  step "docker build"
  docker build -t "$IMAGE" "$ROOT"/containerized-apps/flask-app
  pass "image builds"

  step "run as a random non-root UID (how OpenShift runs it)"
  docker rm -f flask-app-test >/dev/null 2>&1 || true
  docker run -d --name flask-app-test \
    --user 1000650000:0 --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    -p 18080:8080 "$IMAGE" >/dev/null
  for _ in $(seq 1 20); do
    curl -fsS localhost:18080/healthz >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS localhost:18080/healthz >/dev/null || { docker logs flask-app-test; fail "/healthz"; }
  curl -fsS localhost:18080/ | grep -q "<html" || fail "index page"
  curl -fsS -o /dev/null localhost:18080/static/emmanuel-thumbnail.jpg || fail "static image"
  docker rm -f flask-app-test >/dev/null
  pass "app serves /, /healthz and /static as UID 1000650000"
}

wait_for() {  # wait_for <description> <seconds> <command...>
  local what="$1" secs="$2"; shift 2
  for _ in $(seq 1 "$secs"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "timed out waiting for $what"
}

cluster() {
  need docker kind kubectl curl
  step "kind cluster"
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 180s
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  docker image inspect "$IMAGE" >/dev/null 2>&1 || image
  kind load docker-image "$IMAGE" --name "$CLUSTER"
  pass "cluster ready"

  step "Gatekeeper $GATEKEEPER_VERSION + deny-privileged policy"
  kubectl apply -f "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/$GATEKEEPER_VERSION/deploy/gatekeeper.yaml" >/dev/null
  kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager --timeout=300s
  kubectl apply -f "$ROOT"/policies/privileged-constraint-template.yaml
  wait_for "K8sPSPPrivilegedContainer CRD" 120 kubectl get crd k8spspprivilegedcontainer.constraints.gatekeeper.sh
  kubectl apply -f "$ROOT"/policies/opa-deny-privileged.yaml
  # The webhook can refuse connections for a few seconds after the rollout reports ready.
  wait_for "namespace $NS (Gatekeeper webhook ready)" 120 bash -c \
    "kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -"
  # Gatekeeper needs a few seconds to start enforcing a new constraint.
  wait_for "policy enforcement" 120 bash -c \
    "! kubectl -n $NS run priv-probe --image=busybox --restart=Never --dry-run=server \
       --overrides='{\"spec\":{\"containers\":[{\"name\":\"p\",\"image\":\"busybox\",\"securityContext\":{\"privileged\":true}}]}}'"
  pass "privileged pod is rejected"
  kubectl -n "$NS" run ok-probe --image=busybox --restart=Never --dry-run=server >/dev/null \
    || fail "a normal pod was rejected"
  pass "normal pod is allowed"

  step "Flask app deployment"
  kubectl -n "$NS" apply -f "$ROOT"/containerized-apps/flask-app/k8s-deploy.yaml
  kubectl -n "$NS" set image deployment/flask-app flask-app="$IMAGE"
  kubectl -n "$NS" patch deployment flask-app --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
  kubectl -n "$NS" rollout status deployment/flask-app --timeout=180s
  kubectl -n "$NS" port-forward svc/flask-app-service 18081:80 >/dev/null 2>&1 &
  local pf=$!
  wait_for "service port-forward" 30 curl -fsS localhost:18081/healthz
  curl -fsS localhost:18081/ | grep -q "<html" || { kill $pf; fail "index via Service"; }
  kill $pf
  pass "2 replicas ready, Service reachable, probes passing"

  step "Tekton $TEKTON_VERSION: pipeline accepted by the API server"
  kubectl apply -f "https://storage.googleapis.com/tekton-releases/pipeline/previous/$TEKTON_VERSION/release.yaml" >/dev/null
  kubectl -n tekton-pipelines rollout status deploy/tekton-pipelines-webhook --timeout=300s
  kubectl -n "$NS" apply -f "$ROOT"/tekton-pipeline/rbac.yaml
  kubectl -n "$NS" apply -f "$ROOT"/tekton-pipeline/build-task.yaml \
    -f "$ROOT"/tekton-pipeline/deploy-task.yaml -f "$ROOT"/tekton-pipeline/pipeline.yaml
  kubectl -n "$NS" get pipeline flask-app-pipeline >/dev/null
  kubectl -n "$NS" create --dry-run=server -f "$ROOT"/tekton-pipeline/pipelinerun.yaml >/dev/null
  kubectl -n "$NS" auth can-i patch deployments --as="system:serviceaccount:$NS:pipeline" | grep -qx yes \
    || fail "pipeline ServiceAccount cannot update the Deployment"
  pass "tasks + pipeline valid, deploy ServiceAccount has the RBAC it needs"

  if [ "$SKIP_VM" = "true" ]; then
    echo "SKIP_VM=true, skipping KubeVirt"
  else
    step "KubeVirt $KUBEVIRT_VERSION: boot ubuntu-vm"
    kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/$KUBEVIRT_VERSION/kubevirt-operator.yaml" >/dev/null
    kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/$KUBEVIRT_VERSION/kubevirt-cr.yaml" >/dev/null
    if ! docker exec "$CLUSTER-control-plane" test -e /dev/kvm; then
      echo "No /dev/kvm: using software emulation (slow, test only)"
      kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
        -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
    fi
    kubectl -n kubevirt wait kv kubevirt --for=condition=Available --timeout=600s
    kubectl -n "$NS" apply -f "$ROOT"/kubevirt-vms/ubuntu-vm.yaml
    kubectl -n "$NS" patch vm ubuntu-vm --type=merge -p '{"spec":{"runStrategy":"Always"}}'
    if ! kubectl -n "$NS" wait vm ubuntu-vm --for=condition=Ready --timeout=600s; then
      kubectl -n "$NS" get vm ubuntu-vm -o jsonpath='{.status}{"\n"}'
      fail "ubuntu-vm did not become Ready"
    fi
    pass "ubuntu-vm is running"
    kubectl -n "$NS" apply --dry-run=server -f "$ROOT"/kubevirt-vms/pvc-template.yaml \
      -f "$ROOT"/kubevirt-vms/ubuntu-vm-migrated.yaml >/dev/null
    pass "migrated-VM manifests accepted (dry run; needs your uploaded disk to boot)"
    kubectl -n "$NS" patch vm ubuntu-vm --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
  fi

  step "Done"
  pass "all cluster checks passed"
}

clean() {
  docker rm -f flask-app-test >/dev/null 2>&1 || true
  kind delete cluster --name "$CLUSTER"
}

case "${1:-all}" in
  lint) lint ;;
  image) image ;;
  cluster) cluster ;;
  all) lint; image; cluster ;;
  clean) clean ;;
  *) echo "usage: $0 [lint|image|cluster|all|clean]"; exit 2 ;;
esac
