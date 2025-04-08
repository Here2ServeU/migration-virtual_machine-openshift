# VM to OpenShift Migration Project

## Prerequisites
- OpenShift 4.x Cluster (local or cloud-based)
- Access to OperatorHub (to install KubeVirt)
- Git, Tekton, ArgoCD CLI (optional)
- Persistent Volume provisioning

## Local Testing with Minikube (for dev)
```bash
minikube start --memory=8192 --cpus=4
minikube addons enable ingress
```
> Optional: Install KubeVirt and OpenShift Pipelines Operator manually

---

## Steps

### 1. Clone this repo
```bash
git clone https://github.com/your-org/vm-to-openshift-migration.git
cd vm-to-openshift-migration
```

### 2. Deploy Java App to OpenShift
```bash
oc apply -f containerized-apps/java-app/k8s-deploy.yaml
```

### 3. Deploy KubeVirt Virtual Machine
```bash
oc apply -f kubevirt-vms/pvc-template.yaml
oc apply -f kubevirt-vms/ubuntu-vm.yaml
```

### 4. Setup Tekton CI/CD Pipeline
```bash
oc apply -f tekton-pipeline/
```

### 5. Add ArgoCD App
```bash
oc apply -f argo-apps/java-app-argocd.yaml
```

### 6. Enforce Security Policies with Gatekeeper (OPA)
```bash
oc apply -f policies/opa-deny-privileged.yaml
```

---

## Useful Commands
```bash
oc get vm
oc get pods
oc get route
oc logs pod-name
```

---
For production use, consider integrating GitHub Actions and deploying to OpenShift on AWS using ROSA or IPI.


---

## <div align="center">About the Author</div>

<div align="center">
  <img src="assets/emmanuel-naweji.jpg" alt="Emmanuel Naweji" width="120" height="120" style="border-radius: 50%;" />
</div>

**Emmanuel Naweji** is a seasoned Cloud and DevOps Engineer with years of experience helping companies architect and deploy secure, scalable infrastructure. He is the founder of initiatives that train and mentor individuals seeking careers in IT and has helped hundreds transition into Cloud, DevOps, and Infrastructure roles.

- Book a free consultation: [https://here4you.setmore.com](https://here4you.setmore.com)
- Connect on LinkedIn: [https://www.linkedin.com/in/ready2assist/](https://www.linkedin.com/in/ready2assist/)

Let's connect and discuss how I can help you build reliable, automated infrastructure the right way.


——

MIT License © 2025 Emmanuel Naweji

You are free to use, copy, modify, merge, publish, distribute, sublicense, or sell copies of this software and its associated documentation files (the “Software”), provided that the copyright and permission notice appears in all copies or substantial portions of the Software.

This Software is provided “as is,” without any warranty — express or implied — including but not limited to merchantability, fitness for a particular purpose, or non-infringement. In no event will the authors be liable for any claim, damages, or other liability arising from the use of the Software.
