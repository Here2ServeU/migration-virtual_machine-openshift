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

2. Create a raw disk image of the root volume:
```bash
sudo dd if=/dev/xvda of=ubuntu-vm.img bs=1M status=progress
```

3. Compress and download the image:
```bash
gzip ubuntu-vm.img
scp -i your-key.pem ubuntu@your-ec2-public-ip:~/ubuntu-vm.img.gz .
```

---

## Deploy Flask App to OpenShift

1. Start Minikube:
```bash
minikube start --memory=8192 --cpus=4
minikube addons enable ingress
```

2. Create project and deploy:
```bash
oc new-project flask-app
oc apply -f containerized-apps/flask-app/k8s-deploy.yaml
```

3. Expose the application:
```bash
oc expose svc flask-app-service
```

---

## Deploy VM with KubeVirt

1. Apply Persistent Volume Claim:
```bash
oc apply -f kubevirt-vms/pvc-template.yaml
```

2. Deploy the VM:
```bash
oc apply -f kubevirt-vms/ubuntu-vm.yaml
```

3. Start the VM:
```bash
virtctl start ubuntu-vm
```

4. Access VM console (optional):
```bash
virtctl console ubuntu-vm
```

---

## Setup CI/CD Pipeline with Tekton

Apply the tasks and pipeline:
```bash
oc apply -f tekton-pipeline/build-task.yaml
oc apply -f tekton-pipeline/deploy-task.yaml
oc apply -f tekton-pipeline/pipeline.yaml
```

Start the pipeline:
```bash
tkn pipeline start java-app-pipeline
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

Apply the OPA policy constraint:
```bash
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

