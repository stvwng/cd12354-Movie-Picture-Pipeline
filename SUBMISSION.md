# Movie Picture Pipeline: Submission

**Repository:** https://github.com/stvwng/cd12354-Movie-Picture-Pipeline

GitHub Actions CI/CD for the Movie Picture frontend (React) and backend (Flask),
deployed to Amazon EKS. For the full design, see [`docs/PIPELINE.md`](docs/PIPELINE.md).
For the concepts behind it, see the [`docs/PRIMER.md`](docs/PRIMER.md) review guide.

## Deliverables

| Rubric item | File | Evidence |
| --- | --- | --- |
| Frontend Continuous Integration | `.github/workflows/frontend-ci.yaml` | [passing run](https://github.com/stvwng/cd12354-Movie-Picture-Pipeline/actions/runs/37146908478) · `screenshots/01` |
| Backend Continuous Integration | `.github/workflows/backend-ci.yaml` | [passing run](https://github.com/stvwng/cd12354-Movie-Picture-Pipeline/actions/runs/37146908489) · `screenshots/02` |
| Frontend Continuous Deployment | `.github/workflows/frontend-cd.yaml` | [passing run](https://github.com/stvwng/cd12354-Movie-Picture-Pipeline/actions/runs/37149223355) · `screenshots/06` |
| Backend Continuous Deployment | `.github/workflows/backend-cd.yaml` | [passing run](https://github.com/stvwng/cd12354-Movie-Picture-Pipeline/actions/runs/37149223420) · `screenshots/07` |
| Frontend displays movies from backend | | `screenshots/08-frontend-app-movie-list.png` |
| Backend API returns movies | | `screenshots/09-backend-api-movies.png` |
| Images in ECR, tagged with git SHA | | `screenshots/10-cluster-and-ecr-state.txt` |
| A failing test blocks the build | | [PR #2](https://github.com/stvwng/cd12354-Movie-Picture-Pipeline/pull/2) · `screenshots/03`, `04` |

> The load balancer URLs in the screenshots (`http://ada34c11…elb.amazonaws.com`
> for the frontend and `http://ad35f450…elb.amazonaws.com/movies` for the backend) were live on
> 2026-10-03 and have since been torn down to stop AWS charges. The CD runs
> linked above show the deploy and the smoke tests passing against them.

## Automatic-fail checks

| Condition | Status |
| --- | --- |
| AWS credentials hard-coded | **No.** `secrets.AWS_ACCESS_KEY_ID` / `secrets.AWS_SECRET_ACCESS_KEY` only |
| Any pipeline fails or has failed steps | **No.** All four latest runs are green |
| A pipeline can pass with a failing test | **No.** `build.needs: [lint, test]` and `deploy.needs: build`. PR #2 shows Test ❌ → Build skipped → run failed |
| Image not uploaded to ECR | **Uploaded.** `frontend:e3f334d…` and `backend:e3f334d…` |
| App not running on the cluster | **Running.** The frontend lists all 3 movies fetched from the backend |

## Stand-out extras (all four suggestions, plus more)

1. **Composite actions.** `.github/actions/setup-frontend` and `setup-backend` replace the setup steps that were repeated in every job.
2. **Docker layer caching.** `docker/setup-buildx-action` plus `docker/build-push-action` with `cache-from/to: type=gha` (`mode=max`), scoped per app.
3. **Reporting results.**
   - CI posts one sticky PR comment per app and edits it on each push (`screenshots/05`).
   - Every run writes a job summary.
   - CD posts to Slack when the `SLACK_WEBHOOK_URL` secret is set.
4. **Post-deployment smoke test** (`.github/scripts/smoke-test.sh`). It runs after `kubectl rollout status`.
   - Backend: `GET /movies` must return a non-empty list.
   - Frontend: the served JS bundle must contain the backend URL, which proves `REACT_APP_MOVIE_API_URL` was baked in.
   - On failure, the job runs `kubectl rollout undo` and still fails the run.
5. **Also included:**
   - The backend URL is discovered from the live Service, so nothing is hard-coded. An override is available through a repo variable or a dispatch input.
   - `concurrency` cancels superseded CI runs but never interrupts a deploy.
   - Least-privilege `permissions`.
   - GitHub Environments record deploy history.
   - `.dockerignore` files.
   - `linux/amd64` builds to match the EKS nodes.
   - Node 24 action majors.
   - Runners pinned to `ubuntu-24.04`.

## Required secrets

| Secret | Purpose |
| --- | --- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | access key for `github-action-user` (created by Terraform) |
| `AWS_SESSION_TOKEN` | optional, only for temporary (lab/STS) credentials |
| `SLACK_WEBHOOK_URL` | optional, enables deploy notifications |

## Screenshots

| File | Shows |
| --- | --- |
| `01-frontend-ci-pass.png` | Frontend CI: lint ∥ test → build, all green |
| `02-backend-ci-pass.png` | Backend CI: lint ∥ test → build, all green |
| `03-frontend-ci-gated-on-test-failure.png` | broken frontend test → build skipped, run failed |
| `04-backend-ci-gated-on-test-failure.png` | broken backend test → build skipped, run failed |
| `05-pr-sticky-ci-comments.png` | sticky CI result comments on the PR |
| `06-frontend-cd-pass.png` | Frontend CD: lint ∥ test → build/push → deploy (env URL) → notify |
| `07-backend-cd-pass.png` | Backend CD: same shape |
| `08-frontend-app-movie-list.png` | deployed frontend listing movies from the backend |
| `09-backend-api-movies.png` | deployed backend `/movies` JSON |
| `10-cluster-and-ecr-state.txt` | `kubectl get deploy,svc`, `curl /movies`, ECR image tags |
