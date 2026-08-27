# Hybrid AWS Architecture & Blue/Green Simulation Harness

This repository contains a local, containerized simulation environment designed to mirror an AWS production architecture—incorporating **CloudFront, CloudFront Functions, an Application Load Balancer (ALB), ECS Containers utilizing Service Connect, S3, and Blue/Green deployment routing**. It leverages exported Postman collections to drive local API mock servers, allowing offline development and testing of zero-downtime deployment patterns.

---

## **1. Architecture Overview**

The local stack replicates a cloud-native AWS topology inside a Docker Compose environment to mimic edge routing, load balancing, service mesh orchestration, and blue/green traffic shifts.

* **Edge Layer:** NGINX with Lua/OpenResty or lightweight Node.js router simulating **CloudFront** and **CloudFront Functions** (URL rewrites, header injection, and edge validation).
* **Load Balancing Layer:** NGINX configured as an **ALB** proxy, handling path-based routing, health checks, and upstream blue/green traffic weight splits.
* **Orchestration Layer:** **ECS-style container sets** utilizing local service mesh patterns inspired by [Amazon ECS Service Connect](https://aws.amazon.com/blogs/containers/streamline-service-to-service-communication-during-deployments-with-amazon-ecs-service-connect/) and [ECS Blue/Green Patterns](https://github.com/aws-samples/sample-amazon-ecs-blue-green-deployment-patterns/blob/main/ecs-bluegreen-service-connect/README.md).
* **Storage Layer:** Local MinIO or containerized filesystem endpoints mocking **S3 buckets**.
* **Mock Backend Layer:** Prism or WireMock instances driven by version-controlled **Postman Collections**.

---

## **2. Component Specifications for AI Code Generation**

When instructing an AI LLM to generate, extend, or scaffold components within this repository, adhere strictly to the following technical blueprints:

### **A. Mock Microservices (Postman Collection Integration)**

* **Source of Truth:** Postman JSON collections located in `/postman/`.
* **Implementation Requirement:** Use **Prism** or **WireMock** containers to spin up mock endpoints matching the exact route, method, request payload schema, and response codes defined in the Postman collection.
* **Target Mapping:** Each mock microservice container must expose an environment variable pointing to its corresponding ECS/Lambda routing stub.

### **B. Mock S3 Buckets**

* **Implementation Requirement:** Deploy a lightweight **MinIO** service via Docker Compose with predefined bucket names matching production configuration (`assets-bucket`, `uploads-bucket`).
* **Permissions:** Implement basic public/private policy simulation via container environment setup to mirror AWS S3 access controls.

### **C. Mock ALB (Application Load Balancer)**

* **Implementation Requirement:** Configure an NGINX container to act as the primary ingress router.
* **Behavior:** Must support path-based routing rules (e.g., `/api/*` to backend services, `/static/*` to S3/MinIO), inject standard AWS headers (`X-Forwarded-For`, `X-Forwarded-Proto`, `X-Amzn-Trace-Id`), and manage weighted upstream blocks (`upstream blue` vs `upstream green`) for deployment testing.

### **D. Mock CloudFront with CloudFront Functions**

* **Implementation Requirement:** Implement an edge router layer (using Node.js Express or OpenResty) positioned in front of the mock ALB.
* **Behavior:** Must execute lightweight Javascript/Lua functions prior to upstream forwarding—handling request URI normalization, query string sorting, and custom header addition matching deployed AWS CloudFront Functions.

### **E. Terraform Infrastructure as Code (IaC)**

* **Implementation Requirement:** The AI LLM must generate corresponding Terraform configurations (`*.tf`) in a `/terraform/` directory that provision the exact cloud equivalents of the local simulation components.
* **Module Structure:**
* **`cloudfront.tf`:** Provisions the AWS CloudFront distribution, associated CloudFront Functions (written in JavaScript for edge execution), and caching policies.
* **`alb.tf`:** Provisions the Application Load Balancer, target groups (configured for blue/green weight shifting), listeners, and security groups.
* **`ecs.tf`:** Provisions the ECS Cluster, Task Definitions, ECS Services utilizing **Amazon ECS Service Connect** for service-to-service communication, and CodeDeploy deployment groups for blue/green rollouts.
* **`s3.tf`:** Provisions S3 buckets with appropriate versioning, encryption, and public access blocks mirroring the local MinIO storage.


* **Parameterization:** All resource configurations must utilize Terraform variables (`variables.tf`) and outputs (`outputs.tf`) to support multi-environment deployment (dev, staging, production) without hardcoded strings.

---

## **3. Blue/Green Simulation Workflow**

To validate zero-downtime deployments locally using the patterns referenced in the [ECS Blue/Green Service Connect Sample](https://github.com/aws-samples/sample-amazon-ecs-blue-green-deployment-patterns/blob/main/ecs-bluegreen-service-connect/README.md):

1. **Parallel Environments:** Spin up dual container sets (`service-app-blue` and `service-app-green`) on isolated internal Docker networks.
2. **Traffic Shifting:** Modify the NGINX upstream weight configuration or toggle active symlinks to transition traffic incrementally (canary) or atomically (blue/green cutover).
3. **Health Validation:** Run automated integration checks against the staging target group before committing the routing switch, ensuring seamless service-to-service communication via local service discovery.

