# Fleet Basics (Rancher GitOps)
> Module 18 · Lesson 04 | [↑ Course Index](../README.md)

## Table of Contents
- [Overview](#overview)
- [How Fleet Fits with Module 11](#how-fleet-fits-with-module-11)
- [Core Resources](#core-resources)
- [Lab: Deploy from a GitRepo Resource](#lab-deploy-from-a-gitrepo-resource)

---

## Overview

**Fleet** is Rancher’s GitOps engine for deploying to one or many clusters. In a Rancher-managed environment, Fleet is the typical answer to:
- “Deploy this app to 30 clusters.”
- “Show me drift and reconcile it.”
- “Target clusters by labels and environments.”

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## How Fleet Fits with Module 11

Module 11 covers Flux and ArgoCD, which are popular GitOps controllers.

Fleet differs mainly in multi-cluster targeting and being tightly integrated with Rancher. If you already use Flux/ArgoCD, Fleet is still worth knowing if Rancher is your control plane.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Core Resources

- `GitRepo` (CRD): points to a Git repository and paths to deploy
- `Bundle` (CRD): Fleet’s internal packaged unit derived from a GitRepo
- Targets: cluster groups and selectors used to decide where bundles go

Example GitRepo shape:

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: example
  namespace: fleet-local
spec:
  repo: https://github.com/example-org/example-repo
  paths:
    - clusters/management
```

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](../README.md)

---

## Lab: Deploy from a GitRepo Resource

1) Edit the repo URL and paths in:

- `18_rancher/labs/fleet-gitrepo.yaml`

2) Apply it to the management cluster:

```bash
kubectl apply -f 18_rancher/labs/fleet-gitrepo.yaml
```

3) Watch Fleet reconcile:

```bash
kubectl get gitrepo -A
kubectl describe gitrepo -n fleet-local my-repo
```

---

*Licensed under [CC BY-NC-SA 4.0](../LICENSE.md) · © 2026 UncleJS*
