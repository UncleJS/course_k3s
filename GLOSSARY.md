# Glossary
> [↑ Course Index](README.md)


[![Course Index](https://img.shields.io/badge/Course-Index-0f766e)](README.md)
[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](LICENSE.md)

A reference dictionary of terms used throughout this course, covering Kubernetes/k3s core concepts, k3s-specific components, and the wider ecosystem tooling.

## Table of Contents
- [A](#a) · [B](#b) · [C](#c) · [D](#d) · [E](#e) · [F](#f) · [G](#g) · [H](#h) · [I](#i) · [J](#j) · [K](#k) · [L](#l) · [M](#m) · [N](#n) · [O](#o) · [P](#p) · [R](#r) · [S](#s) · [T](#t) · [V](#v) · [W](#w)

---

## A

**Admission Controller**
A Kubernetes API server plugin that intercepts requests before objects are persisted. Admission controllers can validate, mutate, or reject requests (e.g., enforcing security policies, injecting sidecars). k3s ships with a default set of admission controllers enabled. See [Module 09 – Security](09_security/).

**Agent** *(k3s-specific)*
A k3s process that runs on worker nodes. The agent registers with the k3s server, runs kubelet and kube-proxy, and manages pods on that node. Start an agent with `k3s agent --server <url> --token <token>`. Contrast with *Server*. See [Module 06 – Multi-Node Clusters](06_multi_node_cluster/).

**Air-Gap Installation**
Installing k3s (and deploying workloads) on nodes with no internet access. Requires pre-downloading the k3s binary, container images, and Helm charts, then transferring them to the nodes manually. See [Module 16 – Images and Registries](16_podman_to_k3s/03_images_and_registries.md).

**Annotation**
A key-value pair attached to a Kubernetes object (in `metadata.annotations`) that stores non-identifying metadata. Used by tools and controllers to communicate configuration (e.g., `cert-manager.io/cluster-issuer: letsencrypt`). Contrast with *Label*.

**ArgoCD**
A declarative GitOps continuous delivery tool for Kubernetes. ArgoCD watches Git repositories and synchronises the cluster state to match the desired state defined in Git. See [Module 11 – GitOps](11_gitops/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## B

**Buildah**
A rootless, daemonless OCI image build tool that integrates tightly with Podman. Buildah can build images from Containerfiles or via scripted layer manipulation. See [Module 16 – Images and Registries](16_podman_to_k3s/03_images_and_registries.md).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## C

**cert-manager**
A Kubernetes add-on that automates the issuance and renewal of TLS certificates from sources such as Let's Encrypt, Vault, and self-signed CAs. cert-manager uses `Certificate`, `ClusterIssuer`, and `Issuer` CRDs. See [Module 07 – Ingress and TLS](07_ingress_and_tls/).

**ClusterIP**
The default Kubernetes Service type. Creates a virtual IP address reachable only within the cluster. Used for internal service-to-service communication. Contrast with *NodePort* and *LoadBalancer*.

**ClusterIssuer**
A cert-manager CRD that defines a certificate authority configuration available cluster-wide (as opposed to a namespaced `Issuer`). See [Module 07 – Ingress and TLS](07_ingress_and_tls/).

**CNI (Container Network Interface)**
A specification and set of plugins that configure networking for containers. k3s bundles *Flannel* as its default CNI. Other common CNIs include Calico, Cilium, and Weave. See [Module 04 – Networking](04_networking/).

**ConfigMap**
A Kubernetes object for storing non-sensitive configuration data as key-value pairs or files. Injected into pods as environment variables or mounted volumes. Contrast with *Secret*.

**containerd**
The industry-standard container runtime used by k3s (and most Kubernetes distributions). containerd manages the lifecycle of containers — pulling images, creating namespaces, running containers. k3s embeds containerd directly; there is no Docker dependency.

**Containerfile**
The Podman/Buildah equivalent of a `Dockerfile`. Uses the same syntax and is fully compatible with `docker build`. The name `Dockerfile` also works with Podman.

**CRI (Container Runtime Interface)**
A Kubernetes plugin API that allows kubelet to use different container runtimes (Docker, containerd, CRI-O, etc.) without modification. k3s uses containerd via CRI.

**CronJob**
A Kubernetes workload object that creates Jobs on a schedule (using cron syntax). Used for periodic tasks such as backups, database cleanup, and report generation. See [Module 13 – Backup and DR](13_backup_and_dr/).

**CSI (Container Storage Interface)**
A specification that allows storage vendors to write plugins that work with any Kubernetes distribution. k3s ships with the *local-path-provisioner* CSI driver by default. *Longhorn* is a popular distributed CSI driver. See [Module 05 – Storage](05_storage/).

**ctr**
The low-level containerd CLI. k3s wraps it as `k3s ctr` to ensure commands run in the `k8s.io` containerd namespace. Used to list, pull, and import container images directly on a node. See [Module 16 – Images and Registries](16_podman_to_k3s/03_images_and_registries.md).

**CustomResourceDefinition (CRD)**
A Kubernetes extension mechanism that allows users to define new API types (custom resources). Helm, Flux, ArgoCD, cert-manager, Traefik, and Longhorn all install their own CRDs. See [Module 08 – Helm](08_helm/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## D

**DaemonSet**
A Kubernetes workload object that ensures one pod runs on every (or a subset of) node(s) in the cluster. Used for node-level agents such as log collectors, monitoring exporters, and CNI plugins.

**Deployment**
The most common Kubernetes workload object. Manages a set of identical, stateless pods with rolling updates, rollback capability, and desired-replica enforcement via a *ReplicaSet*. See [Module 03 – First Steps](03_first_steps/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## E

**etcd**
A distributed key-value store used by Kubernetes as its backing state store. Full Kubernetes uses etcd in a cluster. k3s replaces etcd with *SQLite* (default for single-node) or supports embedded etcd for HA multi-node setups. See [Module 06 – Multi-Node Clusters](06_multi_node_cluster/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## F

**Flannel**
A simple, lightweight CNI plugin bundled with k3s by default. Flannel creates an overlay network so pods on different nodes can communicate. k3s uses the VXLAN backend by default. See [Module 04 – Networking](04_networking/).

**Flux**
A set of GitOps controllers for Kubernetes (part of the CNCF). Flux watches Git repositories and automatically applies changes to the cluster. Includes `source-controller`, `helm-controller`, `kustomize-controller`, and `notification-controller`. See [Module 11 – GitOps](11_gitops/).

**Fleet**
A GitOps engine from Rancher designed for multi-cluster continuous delivery. Fleet watches Git repositories and deploys content as bundles across one or many clusters, with rich targeting and drift reconciliation. See [Module 18 – Rancher](18_rancher/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## G

**Grafana**
An open-source dashboarding and visualisation platform. In k3s monitoring stacks, Grafana is deployed alongside Prometheus to render metrics as graphs and dashboards. See [Module 10 – Monitoring](10_monitoring/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## H

**Helm**
The package manager for Kubernetes. Helm packages applications as *Charts* — collections of Kubernetes manifests with templating. `helm install`, `helm upgrade`, and `helm rollback` manage application lifecycle. See [Module 08 – Helm](08_helm/).

**HelmChart** *(k3s CRD)*
A k3s-specific CRD that allows Helm charts to be installed and managed declaratively as Kubernetes objects (without running `helm` CLI commands manually). k3s uses this internally to deploy Traefik and other built-in components. See [Module 08 – Helm](08_helm/).

**HelmChartConfig** *(k3s CRD)*
A k3s CRD for supplying override `values.yaml` content to a `HelmChart` object. Used to customise k3s-managed Helm deployments (e.g., Traefik configuration). See [Module 08 – Helm](08_helm/).

**HorizontalPodAutoscaler (HPA)**
A Kubernetes controller that automatically scales the number of pod replicas in a Deployment or StatefulSet based on CPU utilisation, memory, or custom metrics. See [Module 10 – Monitoring](10_monitoring/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## I

**Init Container**
A special container that runs and completes before the main application containers in a pod start. Used to perform setup tasks (waiting for a database, loading configuration, seeding data). See [Module 16 – Compose to k3s](16_podman_to_k3s/02_compose_to_k3s.md).

**Ingress**
A Kubernetes API object that defines HTTP(S) routing rules from external traffic to internal Services. Requires an *Ingress Controller* (such as Traefik or nginx) to implement the rules. See [Module 07 – Ingress and TLS](07_ingress_and_tls/).

**IngressRoute** *(Traefik CRD)*
A Traefik-specific CRD that extends standard Kubernetes Ingress with additional features: TCP/UDP routing, middleware chains, and TLS configuration. k3s's built-in Traefik uses IngressRoutes. See [Module 07 – Ingress and TLS](07_ingress_and_tls/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## J

**Job**
A Kubernetes workload object that runs one or more pods to completion (rather than indefinitely). Used for batch processing, database migrations, and one-off tasks. Contrast with *Deployment*; see also *CronJob*.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## K

**k3s**
A lightweight, certified Kubernetes distribution by Rancher Labs (now SUSE). k3s packages the entire Kubernetes control plane into a single binary (`< 100 MB`), replaces etcd with SQLite, bundles Traefik, Flannel, and local-path-provisioner, and is designed for edge, IoT, and resource-constrained environments. See [Module 01 – Introduction](01_introduction/).

**kubeconfig**
A YAML file that stores cluster connection details, credentials, and context. `kubectl` reads `~/.kube/config` by default. k3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml`. See [Module 02 – Installation](02_installation/).

**kubectl**
The official Kubernetes command-line client. Used to deploy applications, inspect resources, view logs, and manage cluster state. k3s bundles `kubectl` as `k3s kubectl`. See [Module 03 – First Steps](03_first_steps/).

**kubelet**
The primary node agent in Kubernetes. Runs on every node (server and agent in k3s). Watches the API server for pods scheduled to its node and manages their lifecycle via the container runtime. See [Module 06 – Multi-Node Clusters](06_multi_node_cluster/).

**kube-proxy**
A network proxy that runs on each node and maintains network rules for Service routing. k3s runs kube-proxy on agent nodes. See [Module 04 – Networking](04_networking/).

**Kustomize**
A Kubernetes-native configuration management tool. Kustomize overlays allow you to customise base manifests for different environments (dev/staging/prod) without templating. Built into `kubectl` as `kubectl apply -k`. See [Module 11 – GitOps](11_gitops/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## L

**Label**
A key-value pair in `metadata.labels` used to identify and select Kubernetes objects. Services use label selectors to route traffic to matching pods. Contrast with *Annotation*.

**Let's Encrypt**
A free, automated certificate authority. cert-manager integrates with Let's Encrypt to automatically issue and renew TLS certificates for Kubernetes Ingress/IngressRoute resources. See [Module 07 – Ingress and TLS](07_ingress_and_tls/).

**LoadBalancer**
A Kubernetes Service type that provisions an external load balancer (cloud provider or MetalLB on bare metal) and assigns an external IP. k3s supports MetalLB or ServiceLB (formerly klipper-lb) for bare-metal LoadBalancer Services. See [Module 04 – Networking](04_networking/).

**local-path-provisioner** *(k3s built-in)*
A simple dynamic storage provisioner bundled with k3s. Creates `PersistentVolumes` backed by directories on the node's local filesystem. Suitable for development and single-node clusters; not replicated across nodes. See [Module 05 – Storage](05_storage/).

**Longhorn**
A cloud-native distributed block storage system for Kubernetes. Longhorn replicates volumes across nodes, provides snapshots and backups, and is a recommended persistent storage solution for production k3s clusters. See [Module 05 – Storage](05_storage/) and [Module 13 – Backup and DR](13_backup_and_dr/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## M

**Manifest**
A YAML (or JSON) file that declaratively describes a Kubernetes object. Manifests are applied with `kubectl apply -f`. The Kubernetes API server reconciles the cluster state to match the manifest.

**MetalLB**
A bare-metal LoadBalancer implementation for Kubernetes. MetalLB assigns real IP addresses to LoadBalancer Services in clusters that don't have a cloud provider. Used with k3s on physical/VM infrastructure. See [Module 04 – Networking](04_networking/).

**Middleware** *(Traefik CRD)*
A Traefik CRD that defines request/response transformations applied to matched routes — e.g., rate limiting, authentication, header injection, redirect rules. See [Module 07 – Ingress and TLS](07_ingress_and_tls/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## N

**Namespace**
A logical isolation boundary within a Kubernetes cluster. Namespaces scope resource names, RBAC policies, NetworkPolicies, and resource quotas. k3s creates `kube-system`, `kube-public`, `kube-node-lease`, and `default` namespaces by default.

**NetworkPolicy**
A Kubernetes object that controls ingress and egress traffic between pods using label selectors. Requires a CNI that supports NetworkPolicy (Flannel alone does not; use Calico or Cilium). See [Module 09 – Security](09_security/).

**Node**
A physical or virtual machine in the cluster. In k3s terminology: *server nodes* run the control plane, *agent nodes* run workloads only. See [Module 06 – Multi-Node Clusters](06_multi_node_cluster/).

**NodePort**
A Kubernetes Service type that exposes a Service on a static port (30000–32767) on every node's IP address. Useful for development and simple external access without a load balancer.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## O

**OCI (Open Container Initiative)**
An open industry standard for container image formats and runtimes. All modern container tools (Podman, Docker, containerd, buildah) produce OCI-compatible images.

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## P

**PersistentVolume (PV)**
A piece of storage provisioned in the cluster (manually or dynamically). A PV has a lifecycle independent of any pod. See [Module 05 – Storage](05_storage/).

**PersistentVolumeClaim (PVC)**
A request for storage by a user or pod. A PVC binds to a matching PV. The *local-path-provisioner* dynamically creates PVs to satisfy PVC requests. See [Module 05 – Storage](05_storage/).

**Pod**
The smallest deployable unit in Kubernetes. A pod wraps one or more containers that share a network namespace and storage volumes. Pods are ephemeral; higher-level controllers (Deployments, StatefulSets) manage their lifecycle. See [Module 03 – First Steps](03_first_steps/).

**Podman**
A rootless, daemonless container engine compatible with the Docker CLI. Podman uses the same OCI image format as Docker and k3s/containerd. Module 16 covers migrating Podman workloads to k3s. See [Module 16 – Moving from Podman to k3s](16_podman_to_k3s/).

**Probe**
A mechanism for kubelet to assess pod health. Kubernetes supports three probe types: `readinessProbe` (is the pod ready to receive traffic?), `livenessProbe` (should the pod be restarted?), and `startupProbe` (has the app finished starting?). See [Module 16 – Compose to k3s](16_podman_to_k3s/02_compose_to_k3s.md).

**Prometheus**
An open-source time-series metrics database and monitoring system. The standard monitoring backend for Kubernetes clusters. Scrapes metrics from pods via `/metrics` endpoints. See [Module 10 – Monitoring](10_monitoring/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## R

**Rancher**
A multi-cluster Kubernetes management platform (Rancher Manager) providing a central UI and API for cluster inventory, RBAC, authentication integration, and GitOps at scale (via Fleet). Commonly run on a dedicated management cluster that manages downstream clusters. See [Module 18 – Rancher](18_rancher/).

**RBAC (Role-Based Access Control)**
A Kubernetes authorisation mechanism that controls which users and service accounts can perform which operations on which resources. Defined with `Role`, `ClusterRole`, `RoleBinding`, and `ClusterRoleBinding` objects. See [Module 09 – Security](09_security/).

**ReplicaSet**
A Kubernetes controller that maintains a specified number of identical pod replicas. Normally managed by a *Deployment* rather than created directly. See [Module 03 – First Steps](03_first_steps/).

**registries.yaml** *(k3s-specific)*
The k3s configuration file at `/etc/rancher/k3s/registries.yaml` that defines registry mirrors, credentials, and TLS settings for containerd image pulls. See [Module 16 – Images and Registries](16_podman_to_k3s/03_images_and_registries.md).

**Resource Quota**
A Kubernetes object that limits the total resources (CPU, memory, object counts) consumable within a namespace. Used to enforce fair-use policies in multi-tenant clusters. See [Module 09 – Security](09_security/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## S

**Secret**
A Kubernetes object for storing sensitive data (passwords, tokens, certificates) as base64-encoded key-value pairs. Secrets should be encrypted at rest and managed with tools like SealedSecrets or External Secrets Operator in production. Contrast with *ConfigMap*. See [Module 09 – Security](09_security/).

**SealedSecret**
A Bitnami tool that encrypts Kubernetes Secrets into `SealedSecret` objects safe to commit to Git. The Sealed Secrets controller decrypts them inside the cluster. See [Module 11 – GitOps](11_gitops/).

**Server** *(k3s-specific)*
A k3s process that runs the Kubernetes control plane components (API server, scheduler, controller manager) as well as kubelet and kube-proxy. A k3s cluster requires at least one server node. Start with `k3s server`. Contrast with *Agent*. See [Module 06 – Multi-Node Clusters](06_multi_node_cluster/).

**Service**
A Kubernetes abstraction that provides a stable network endpoint (DNS name + ClusterIP) for a set of pods selected by labels. Service types: *ClusterIP*, *NodePort*, *LoadBalancer*, *ExternalName*. See [Module 03 – First Steps](03_first_steps/).

**ServiceAccount**
A Kubernetes identity for processes running inside pods. Used for RBAC — pods authenticate to the API server using their ServiceAccount token. See [Module 09 – Security](09_security/).

**SQLite**
A lightweight embedded relational database. k3s uses SQLite as its default backing store (replacing etcd) for single-node and small-cluster deployments. For HA multi-node setups, k3s supports embedded etcd or external databases (MySQL, PostgreSQL). See [Module 06 – Multi-Node Clusters](06_multi_node_cluster/).

**StatefulSet**
A Kubernetes workload object for stateful applications (databases, message queues). Provides stable pod names (`pod-0`, `pod-1`), stable network identities, and ordered rolling updates. Contrast with *Deployment*. See [Module 05 – Storage](05_storage/) and [Module 16 – Migration Walkthrough](16_podman_to_k3s/04_migration_walkthrough.md).

**StorageClass**
A Kubernetes object that defines a "class" of storage with a specific provisioner and parameters. Pods claim storage by referencing a StorageClass in their PVC. k3s ships with `local-path` as the default StorageClass. See [Module 05 – Storage](05_storage/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## T

**Taint and Toleration**
A mechanism to control pod scheduling. A *taint* on a node repels pods; a *toleration* on a pod allows it to be scheduled on a tainted node. Used to dedicate nodes for specific workloads or prevent workloads from running on control-plane nodes. See [Module 06 – Multi-Node Clusters](06_multi_node_cluster/).

**Traefik**
A modern reverse proxy and Ingress controller bundled with k3s. Traefik integrates with cert-manager for automatic TLS, supports TCP/UDP routing, and provides a dashboard UI. k3s deploys Traefik automatically via a `HelmChart` CRD. See [Module 07 – Ingress and TLS](07_ingress_and_tls/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## V

**Velero**
An open-source tool for backing up and restoring Kubernetes cluster resources and persistent volumes. Velero snapshots PVs to object storage (S3, GCS, Azure Blob). See [Module 13 – Backup and DR](13_backup_and_dr/).

**Volume**
A directory accessible to containers in a pod. Kubernetes supports many volume types: `emptyDir`, `configMap`, `secret`, `persistentVolumeClaim`, `hostPath`, and CSI volumes. Volumes outlive individual containers but not necessarily the pod. See [Module 05 – Storage](05_storage/).

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)


---

## W

**Workload**
A general term for applications running on Kubernetes. The built-in workload resources are: *Deployment*, *StatefulSet*, *DaemonSet*, *Job*, and *CronJob*.

---

[↑ Back to TOC](#table-of-contents) · [↑ Course Index](README.md)

---
*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*
