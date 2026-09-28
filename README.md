# VM to OpenShift Migration Project

## Overview
This project demonstrates how to migrate legacy applications from virtual machines (VMs) to a containerized environment using OpenShift. It includes both containerized app deployment and VM migration with KubeVirt, along with CI/CD integration using Tekton and GitOps deployment via ArgoCD. Security policies are enforced using Open Policy Agent (OPA) and Gatekeeper.

## Tools Used and Why

### OpenShift CLI (oc)
The `oc` command-line tool allows developers and administrators to manage OpenShift clusters. It is used to apply manifests, create routes, manage resources, and interact with the OpenShift API.

### Minikube
Minikube is a local Kubernetes cluster used for testing and development. It allows simulation of a real Kubernetes/OpenShift environment without needing a cloud provider.

### kubectl
kubectl is the Kubernetes CLI used to interact with Kubernetes clusters. While `oc` is specific to OpenShift, `kubectl` can be used for lower-level Kubernetes management.

### virtctl (KubeVirt CLI)
virtctl is used to interact with VMs managed by KubeVirt inside Kubernetes/OpenShift. It provides commands for starting, stopping, and accessing VM consoles.

### Tekton CLI (tkn)
Tekton is a Kubernetes-native CI/CD pipeline system. The CLI allows interaction with pipelines, tasks, and runs. Tekton automates build and deployment workflows.

### ArgoCD
ArgoCD is a GitOps tool for Kubernetes. It continuously monitors Git repositories and automatically applies changes to the cluster. It ensures infrastructure and app deployment stay synchronized with version control.

### Open Policy Agent (OPA) + Gatekeeper
OPA is a policy engine for Kubernetes. Gatekeeper integrates OPA with Kubernetes admission controls to enforce security policies. In this project, it is used to block privileged containers.

---

## Test Locally First

Test everything on your own machine before you use it on any shared or client cluster. See **[TESTING.md](TESTING.md)**, or run:
```bash
scripts/test-local.sh all
```

---

## Installation Instructions

### Local Machine Setup (macOS/Linux)
```bash
brew install --no-quarantine openshift-cli
brew install minikube
brew install kubectl
brew install tektoncd-cli
brew install argocd
curl -LO https://github.com/kubevirt/kubevirt/releases/download/v1.1.0/virtctl-v1.1.0-linux-amd64
chmod +x virtctl-v1.1.0-linux-amd64
sudo mv virtctl-v1.1.0-linux-amd64 /usr/local/bin/virtctl
```

### EC2 Ubuntu Setup (for exporting VM image)
```bash
sudo apt update
sudo apt install -y qemu-utils cloud-utils genisoimage
```

---

## Exporting Ubuntu VM from EC2

1. SSH into EC2 Ubuntu:
```bash
ssh -i your-key.pem ubuntu@your-ec2-public-ip
```

2. Create a disk image. Do not `dd` the live root disk of a running server: the copy can be corrupted. Instead, snapshot the volume, create a new volume from the snapshot, attach it to a helper instance, then copy that volume (on Nitro instances it shows up as `/dev/nvme1n1`; check with `lsblk`):
```bash
lsblk
sudo dd if=/dev/nvme1n1 of=ubuntu-vm.img bs=1M status=progress
qemu-img convert -p -O qcow2 ubuntu-vm.img ubuntu-vm.qcow2
```

3. Download the image:
```bash
scp -i your-key.pem ubuntu@your-ec2-public-ip:~/ubuntu-vm.qcow2 .
```

---

## Deploy Flask App to OpenShift

1. Start Minikube:
```bash
minikube start --memory=8192 --cpus=4
minikube addons enable ingress
```

2. Create project and deploy (set `image:` in `k8s-deploy.yaml` to the image you pushed first):
```bash
oc new-project flask-app
oc apply -f containerized-apps/flask-app/k8s-deploy.yaml
```

3. Expose the application (OpenShift only; Minikube and kind have no Routes):
```bash
oc apply -f containerized-apps/flask-app/route.yaml
```

---

## Deploy VM with KubeVirt

1. Smoke test: boot a stock Ubuntu VM to prove KubeVirt works:
```bash
oc apply -f kubevirt-vms/ubuntu-vm.yaml
virtctl start ubuntu-vm
```

2. Migrated VM: upload the exported EC2 disk into a PVC (requires CDI, which OpenShift Virtualization includes), then boot it:
```bash
virtctl image-upload pvc ubuntu-vm-pvc --size=10Gi --image-path=ubuntu-vm.qcow2
oc apply -f kubevirt-vms/ubuntu-vm-migrated.yaml
virtctl start ubuntu-vm-migrated
```

3. Access VM console (optional):
```bash
virtctl console ubuntu-vm-migrated
```

---

## Setup CI/CD Pipeline with Tekton

Apply the RBAC, tasks and pipeline:
```bash
oc apply -f tekton-pipeline/rbac.yaml
oc apply -f tekton-pipeline/build-task.yaml
oc apply -f tekton-pipeline/deploy-task.yaml
oc apply -f tekton-pipeline/pipeline.yaml
```

Create a registry push secret (for example a Quay robot account), then start the pipeline:
```bash
oc create secret generic quay-push --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=$HOME/quay-robot.json
# Set the image in tekton-pipeline/pipelinerun.yaml first
oc create -f tekton-pipeline/pipelinerun.yaml
tkn pipelinerun logs --last -f
```

---

## Setup GitOps with ArgoCD

Deploy the ArgoCD application manifest:
```bash
oc apply -f argo-apps/flask-app-argocd.yaml
```

This will sync your Git repo with your cluster and automatically deploy the app defined in the manifest.

---

## Enforce Security with Gatekeeper

Apply the policy template first, then the constraint:
```bash
oc apply -f policies/privileged-constraint-template.yaml
oc apply -f policies/opa-deny-privileged.yaml
```

This will prevent any deployment of containers using privileged mode.

---

## Monitor and Manage Resources
```bash
oc get pods        # List running pods
oc get vm          # List virtual machines
oc get routes      # Check exposed app routes
oc logs pod-name   # View logs from a specific pod
```

---

## <div align="center">About the Author</div>

<div align="center">
  <img src="assets/emmanuel-naweji.jpg" alt="Emmanuel Naweji" width="120" height="120" style="border-radius: 50%;" />
</div>

**Emmanuel Naweji** is a seasoned Cloud and DevOps Engineer with years of experience helping organizations build modern, automated, and secure infrastructure.

- Book a free consultation: [https://here4you.setmore.com](https://here4you.setmore.com)
- Connect on LinkedIn: [https://www.linkedin.com/in/ready2assist/](https://www.linkedin.com/in/ready2assist/)

Let's connect and discuss how I can help you build reliable, automated infrastructure the right way.

---

MIT License © 2025 Emmanuel Naweji

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files to deal in the Software without restriction, including the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies.

