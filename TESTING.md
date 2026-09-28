# Testing Before You Touch a Real Cluster

**Rule:** nothing goes onto an IBM or client cluster until it has passed every level below, in order. Each level is cheaper and faster than the next. If a level fails, fix it there. Don't move up.

| Level | Where | What it proves | Time |
|---|---|---|---|
| 1. Static checks | Your laptop, no cluster | YAML is valid and matches the Kubernetes/KubeVirt/ArgoCD schemas | seconds |
| 2. Container test | Docker | The app builds and runs as a random non-root user, the way OpenShift runs it | 1–2 min |
| 3. Kubernetes | kind (throwaway cluster), **run automatically by GitHub Actions** | Deployment, probes, Service, Gatekeeper policy, Tekton objects and RBAC, a KubeVirt VM boot | 10–20 min |
| 4. Real OpenShift | IBM TechZone cluster (or CRC / Developer Sandbox) | OpenShift-only pieces: Routes, SCCs, OpenShift Virtualization, a full Tekton run, the real EC2 disk boot | hours, first time |
| 5. Client dry run | Client non-prod namespace, via `scripts/preflight-openshift.sh` | Their policies, quotas, registries and network rules accept it, **without changing anything** | minutes |

Levels 1–3 run **automatically on every push** in GitHub Actions (`.github/workflows/test.yaml`). Check the green tick on the commit or PR before you go further. You can also run them on your laptop:

```bash
scripts/test-local.sh all      # runs levels 1, 2 and 3
scripts/test-local.sh clean    # deletes the test cluster afterwards
```

Levels 4 and 5 use the same read-only preflight script against a real OpenShift cluster:

```bash
oc login ...                                  # the TechZone, CRC or client cluster
scripts/preflight-openshift.sh flask-app      # read-only: gets, can-i, dry runs, diff
```

---

## Tools you need (one time)

macOS:
```bash
brew install kind kubectl yamllint kubeconform
# optional, for the offline policy test: gator from
# https://github.com/open-policy-agent/gatekeeper/releases
# plus Docker Desktop, Rancher Desktop or Colima
```

Linux: install Docker, then [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation), [kubectl](https://kubernetes.io/docs/tasks/tools/), `pip install yamllint`, and [kubeconform](https://github.com/yannh/kubeconform/releases).

Give Docker at least **4 CPUs and 8 GB RAM**. The KubeVirt step needs it.

---

## Level 1: Static checks

```bash
scripts/test-local.sh lint
```

This catches typos, bad indentation and wrong field names in every manifest. It also checks KubeVirt `VirtualMachine`s and the ArgoCD `Application` against their real schemas. If `gator` is installed, it also proves the Gatekeeper policy blocks a privileged pod (`tests/policy/`) without needing a cluster. Run it before every commit.

## Level 2: Container test

```bash
scripts/test-local.sh image
```

This builds the image and runs it with the restrictions OpenShift applies by default:
- a random UID (`1000650000`) in group `0`
- a read-only root filesystem
- all Linux capabilities dropped, no privilege escalation

It then checks `/`, `/healthz` and the static image. If the app works here, it will work under OpenShift's `restricted-v2` SCC.

Try it by hand:
```bash
docker run --rm -p 8080:8080 --user 1000650000:0 flask-app:local
# open http://localhost:8080
```

## Level 3: Local Kubernetes (kind)

```bash
scripts/test-local.sh cluster
```

In a disposable kind cluster, this:
1. Installs **Gatekeeper** and the deny-privileged policy. It checks that a privileged pod is **rejected** and a normal pod is **allowed**.
2. Deploys the **Flask app** (2 replicas). It waits for readiness probes and calls it through the Service.
3. Installs **Tekton**, applies the RBAC, tasks and pipeline, and has the API server validate a PipelineRun. It checks that the `pipeline` ServiceAccount is allowed to update the Deployment.
4. Installs **KubeVirt** and boots `ubuntu-vm`. With no `/dev/kvm` (for example on macOS), it uses software emulation: slow, but fine for a test. It also dry-runs the migrated-VM manifests.

Useful options:
```bash
SKIP_VM=true scripts/test-local.sh cluster          # skip KubeVirt (fastest)
KUBEVIRT_VERSION=v1.5.0 scripts/test-local.sh cluster  # match your client's version
```

Look around while the cluster is up:
```bash
kubectl -n flask-app get pods,svc,vm,vmi
kubectl -n flask-app port-forward svc/flask-app-service 8080:80   # http://localhost:8080
```

**What kind cannot test:** Routes, SCCs, `oc new-project`, OpenShift's internal registry, and OpenShift Virtualization (Red Hat's packaging of KubeVirt). That is Level 4.

## Level 4: A real OpenShift you own

Pick the environment that can actually run everything:

| Option | Cost | Runs VMs? | Admin (operators, Gatekeeper)? | Best for |
|---|---|---|---|---|
| **[IBM Technology Zone](https://techzone.ibm.com)** (recommended) | Free for IBMers and IBM partners | Yes: reserve an OpenShift Virtualization environment on bare metal | Yes | The full rehearsal, including booting the real EC2 disk |
| [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) | Free | No | No (project-level access only) | Quick check of the app, Route and SCC in minutes |
| [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview) | Free | Only on a Linux host with KVM. **Not on macOS**, which has no nested virtualization | Yes | Offline testing on a big Linux workstation |

Because you work with IBM, **TechZone is the better path**: it is a real multi-node cluster like your clients run, with OpenShift Virtualization already available, and nothing to install on your laptop. Reserve the environment, `oc login` with the details it gives you, then:

```bash
oc new-project flask-app
scripts/preflight-openshift.sh flask-app     # rehearse Level 5 exactly as you will at the client
```

If you use CRC instead (Linux host, about 9 GB RAM for OpenShift alone, 16 GB+ with VMs):

```bash
crc setup
crc config set memory 16384
crc config set cpus 6
crc start
eval $(crc oc-env)
oc login -u kubeadmin https://api.crc.testing:6443
```

Then, on whichever cluster you chose, follow the README **exactly as you would on the client cluster**:
```bash
oc new-project flask-app
oc apply -f containerized-apps/flask-app/k8s-deploy.yaml
oc set image deployment/flask-app flask-app=quay.io/<your-org>/flask-app:<tag>
oc apply -f containerized-apps/flask-app/route.yaml
curl -k https://$(oc get route flask-app -o jsonpath='{.spec.host}')/healthz

# Confirm the pods got the restricted SCC (no special permissions needed)
oc get pod -l app=flask-app -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'
```

For VMs and pipelines, install the **OpenShift Virtualization** and **Red Hat OpenShift Pipelines** operators from OperatorHub. Then run the README's KubeVirt and Tekton steps, including a real `oc create -f tekton-pipeline/pipelinerun.yaml` that pushes to your own Quay repo.

This is also where you rehearse the **real migration**: upload the EC2 disk with `virtctl image-upload` and boot `ubuntu-vm-migrated`. Check that it boots, gets a network address and runs its services. EC2 images sometimes need `cloud-init` or network config changes to boot outside AWS. Find that out here, not at the client.

## Level 5: Client environment, safely

Even after Levels 1–4, go into a client cluster **read-only first**:

```bash
oc login ...                                   # the client's NON-PROD cluster
scripts/preflight-openshift.sh <their-namespace>
```

The script **cannot change anything**. It only uses `get`, `auth can-i`, `--dry-run=server` and `diff`. It:
- shows the user, server, namespace and OpenShift version, and asks you to confirm
- refuses to target `default`, `kube-*` or `openshift*`
- checks your permissions, and whether OpenShift Virtualization, CDI, Pipelines, GitOps, Gatekeeper and Kyverno are installed
- warns if a policy template with the same name already exists (don't overwrite the client's)
- sends every manifest through a **server-side dry run**, so their webhooks, quotas, SCCs and policies all judge it
- shows an `oc diff` of what a real apply would change

It ends with `0 blocker(s)` or a list of what to fix. Save the output and attach it to the change ticket.

Checklist before the real `apply`:
- [ ] Written approval / change ticket from the client for this namespace and time window
- [ ] Image pushed to a registry **the client's cluster can pull from** (many block Docker Hub and Quay; ask for their mirror)
- [ ] The `quay.io/your-repo/...` placeholders replaced with real image names
- [ ] Gatekeeper constraint set to `enforcementAction: dryrun` first. Check violations with `oc get k8spspprivilegedcontainer disallow-privileged -o yaml` and switch to `deny` only when that list is clean. Many client clusters already run Gatekeeper or Kyverno policies; coordinate with their platform team.
- [ ] ArgoCD `repoURL` and `targetRevision` point at the client-approved repo and branch, not `HEAD` of a personal repo
- [ ] A rollback plan written down (`oc rollout undo deployment/flask-app`, `virtctl stop <vm>`, the original EC2 instance kept running until sign-off)
- [ ] No customer data copied to your laptop for Level 4 testing without permission

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `COPY static/ ... not found` on build | You're on an old commit; `static/` now lives in `containerized-apps/flask-app/static/` |
| Pod `CrashLoopBackOff` with `Permission denied` on port 80 | Old image; the app now listens on 8080 |
| `no matches for kind "K8sPSPPrivilegedContainer"` | Apply `policies/privileged-constraint-template.yaml` first and wait a few seconds |
| `no matches for kind "Route"` | You're on plain Kubernetes; Routes exist only on OpenShift |
| VMI stuck `Scheduling` on kind | Docker has too little memory, or no `/dev/kvm` and emulation wasn't enabled |
| `build` step fails on OpenShift with a permission error | Kaniko runs as root. Use the `pipeline` ServiceAccount that OpenShift Pipelines creates (it gets the `pipelines-scc`), or switch to the `buildah` ClusterTask |
| Pipeline `deploy` step `forbidden` | `tekton-pipeline/rbac.yaml` not applied, or the run doesn't use the `pipeline` ServiceAccount |
