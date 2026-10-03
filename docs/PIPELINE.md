# Movie Picture Pipeline — CI/CD Design

GitHub Actions pipelines that lint, test, build and deploy the Movie Picture
frontend (React) and backend (Flask) to Amazon EKS.

## Files

| Path | Purpose |
| --- | --- |
| `.github/workflows/frontend-ci.yaml` | **Frontend Continuous Integration**: PRs to `main` touching the frontend, plus manual runs |
| `.github/workflows/backend-ci.yaml` | **Backend Continuous Integration**: PRs to `main` touching the backend, plus manual runs |
| `.github/workflows/frontend-cd.yaml` | **Frontend Continuous Deployment**: pushes to `main` touching the frontend, plus manual runs |
| `.github/workflows/backend-cd.yaml` | **Backend Continuous Deployment**: pushes to `main` touching the backend, plus manual runs |
| `.github/actions/setup-frontend/action.yml` | Composite action: Node.js from `.nvmrc`, npm cache, `npm ci` |
| `.github/actions/setup-backend/action.yml` | Composite action: Python 3.10, pipenv cache, `pipenv install --dev` |
| `.github/scripts/smoke-test.sh` | Post-deploy smoke test, shared by both CD workflows |
| `starter/*/.dockerignore` | Keeps `node_modules`, caches and manifests out of the Docker build context |

## Pipeline shape

```
  CI  (pull_request -> main, path-filtered | workflow_dispatch)

   +--------+
   |  lint  |---+
   +--------+   |    +-------------------+     +------------------+
                +--->|  build (docker)   |---->|  report          |
   +--------+   |    |  needs: lint,test |     |  if: always()    |
   |  test  |---+    +-------------------+     |  summary + PR    |
   +--------+                                  |  sticky comment  |
                                               +------------------+

  CD  (push -> main, path-filtered | workflow_dispatch)

   +--------+
   |  lint  |---+
   +--------+   |    +----------------------+    +----------------------+    +-----------+
                +--->| build                |--->| deploy               |--->| notify    |
   +--------+   |    | - AWS creds (secret) |    | - update-kubeconfig  |    | always()  |
   |  test  |---+    | - ECR login          |    | - kustomize set image|    | summary + |
   +--------+        | - buildx build+push  |    | - kubectl apply      |    | Slack     |
                     |   tag = git SHA      |    | - rollout status     |    | (opt.)    |
                     +----------------------+    | - smoke test         |    +-----------+
                                                 | - rollout undo on    |
                                                 |   failure            |
                                                 +----------------------+
```

A failed lint or test means `build` is skipped, which also skips `deploy`, and
the run is marked failed. The `report` and `notify` jobs run either way so the
team hears about it, but they cannot turn a failed run green.

## Requirements traceability

| Requirement | Where |
| --- | --- |
| CI on `pull_request` to `main`, only when the app changes | `on.pull_request.branches/paths` in `*-ci.yaml` |
| CD on `push` to `main`, only when the app changes | `on.push.branches/paths` in `*-cd.yaml` |
| Manual runs | `workflow_dispatch` in all four |
| Lint and test run in parallel | separate `lint` and `test` jobs with no `needs` |
| Build only after lint and test pass | `build.needs: [lint, test]` |
| Lint/test/build steps: checkout, setup Node, cache, install | `setup-frontend` composite action (`actions/setup-node` with `cache: npm`, then `npm ci`) |
| Frontend build uses `REACT_APP_MOVIE_API_URL` build arg | `build-args:` on `docker/build-push-action` (CI: `env.REACT_APP_MOVIE_API_URL`; CD: resolved backend URL) |
| Image tagged with git SHA | `${ECR_REGISTRY}/${ECR_REPOSITORY}:${GITHUB_SHA}` |
| AWS credentials from GitHub Secrets | `aws-actions/configure-aws-credentials` with `secrets.AWS_*` |
| ECR login | `aws-actions/amazon-ecr-login@v2` |
| Push to ECR | `docker/build-push-action` with `push: true` |
| Deploy with kubectl | `kustomize edit set image ...` then `kustomize build \| kubectl apply -f -` |

## Stand-out extras

1. **Composite actions.** Node and pipenv setup are each defined once in `.github/actions/*` and reused by every job.
2. **Docker layer caching.** Buildx with `cache-from/to: type=gha` (scoped per app), so unchanged layers like `npm ci` and `apk add` are reused between runs.
3. **Reporting.** CI posts one *sticky* PR comment per app and edits it on each push instead of adding new comments. Every run writes a job summary, and CD sends a Slack message when `SLACK_WEBHOOK_URL` is set.
4. **Post-deployment smoke test and automatic rollback.** CD waits for `kubectl rollout status`, then polls the load balancer.
   - Backend: `GET /movies` must return a non-empty `movies` array.
   - Frontend: the page must render, and its JS bundle must contain the backend URL. That proves `REACT_APP_MOVIE_API_URL` was baked in correctly, not just that the static server answers.
   - If either check fails, the job runs `kubectl rollout undo` and still fails the run.
5. **Backend URL discovery.** Frontend CD reads the backend Service's live ELB hostname from the cluster, so nobody has to copy and paste it. A `REACT_APP_MOVIE_API_URL` repo variable or a `workflow_dispatch` input overrides it.
6. **Safety.** Least-privilege `permissions:`. Runners are pinned to `ubuntu-24.04`, because `ubuntu-latest` silently moves to Ubuntu 26 on 2026-10-19. CI `concurrency` cancels stale PR runs, while CD queues deploys instead of killing them mid-apply. Untrusted values go through `env:` rather than inline `${{ }}` in scripts. GitHub Environments (`backend-production`, `frontend-production`) record deployment history with links.

## One-time setup

1. `cd setup/terraform && terraform init && terraform apply`. This creates the VPC, EKS `cluster`, ECR `frontend`/`backend` and IAM `github-action-user`. The Terraform also grants that user cluster-admin through an EKS access entry, so `init.sh` is not needed.
2. Create an access key for `github-action-user` and save it as repo secrets:
   ```bash
   gh secret set AWS_ACCESS_KEY_ID
   gh secret set AWS_SECRET_ACCESS_KEY
   # only for temporary (lab/STS) credentials:
   gh secret set AWS_SESSION_TOKEN
   # optional
   gh secret set SLACK_WEBHOOK_URL
   ```
3. Push to `main` or run the CD workflows manually. Deploy the backend first. Frontend CD waits up to 5 minutes for the backend load balancer.

## Teardown

```bash
kubectl delete svc frontend backend   # removes the ELBs, which would otherwise block VPC deletion
cd setup/terraform && terraform destroy
```

## Local verification performed

| Check | Result |
| --- | --- |
| `npm run lint` / `CI=true npm test` | pass (3/3 tests) |
| `FAIL_LINT=true npm run lint` / `FAIL_TEST=true CI=true npm test` | fail as expected |
| `pipenv run lint` / `pipenv run test` (Python 3.10) | pass (3/3 tests) |
| `pipenv run lint-fail` / `FAIL_TEST=true pipenv run test` | fail as expected |
| `docker build` both images (linux/amd64) | pass |
| `smoke-test.sh` against local containers | pass. Fails as expected when the bundle has the wrong API URL |
| `actionlint`, `shellcheck` | clean |

## Verification on GitHub and AWS (2026-10-03)

| Check | Result |
| --- | --- |
| Frontend and Backend CI on PR #1 | all jobs green |
| PR #2 with broken tests | Test ❌, Build skipped, run failed, sticky comments posted |
| Frontend and Backend CD on merge to `main` | all jobs green. Images `frontend:e3f334d…` and `backend:e3f334d…` pushed to ECR and deployed |
| Backend URL discovery | frontend build waited about 70 s for the backend ELB, then baked in `http://ad35f450…elb.amazonaws.com` |
| Smoke tests | backend `/movies` returned 3 movies. Frontend bundle confirmed wired to the backend URL |
| Teardown | Services deleted (ELBs removed), access key deleted, `terraform destroy` |
