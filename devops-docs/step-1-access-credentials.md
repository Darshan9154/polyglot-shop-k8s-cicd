# Step 1 — Access and credentials setup

**Status:** core AWS CLI access is working for the existing AWS account. No application infrastructure has been created.

**Recorded:** 2026-10-13  
**Project location:** local-only workspace; the agent project has not yet been initialized as its own Git repository.  
**Source application:** shallow clone `aws-containers/retail-store-sample-app`, currently clean on `main` at `d7a380b`.

## Goal of this step

Set up a non-root identity for the development agent, use short-lived AWS CLI credentials instead of long-lived access keys, confirm the selected region and account access, and check that Amazon ECR is reachable. Do not create billable workload resources in this step.

## What we actually did

### AWS account and region

- Used the existing AWS account; did not follow the AWS Settings **Create project** link because it redirected to AWS sign-up. No new project or account was created.
- Selected region `eu-north-1` (Europe, Stockholm) for the development profile.
- The Billing console showed **$100.00 credits remaining** and **$0.00 used**. The Console Home free-plan widget showed **183 days remaining**, through 2027-04-13, while the active credit entry itself listed 2027-10-13 as its expiry. Treat the earlier free-plan end date as the effective limit unless AWS account-plan details indicate otherwise.
- Cost Explorer data was not available yet, and the `devops-agent` Console Home showed **Access denied** for cost breakdowns. No cost estimate was obtained from billing data.

### IAM identity

Created IAM user **`devops-agent`** in the existing account. It is a non-root user with console sign-in, and it has these directly attached AWS-managed policies:

- `AdministratorAccess` — broad administrator permissions, as requested for this development prototype.
- `SignInLocalDevelopmentAccess` — permits the AWS CLI's browser-based local-development sign-in flow.
- `IAMUserChangePassword` — allows changing the generated password at first sign-in.

AWS generated a one-time initial console password; the user downloaded it, signed in, and changed it at first use without sharing it in chat. The user then registered a **passkey/security key** for MFA. The IAM page later showed **Console access: Enabled with MFA** and **MFA (1)**.

**Security note:** `AdministratorAccess` is full account-level IAM permission. Keep this identity in the development account only. Replace it with scoped permissions after the real workflow is known; do not use it as a production deployment identity. The user created no access keys, and no password, MFA code, passkey material, or auth URL is recorded here.

### AWS CLI

- The harness tool installer did not include AWS CLI, so we installed AWS CLI v2 with AWS's official current-user PowerShell installer. The installer reported that its MSI Authenticode signature was verified.
- Installed version: **AWS CLI 2.37.13** at `C:\Users\darsh\AppData\Local\Programs\Amazon\AWSCLIV2`.
- Created the local AWS CLI profile `retail-store-dev` and set its region to `eu-north-1`.
- Authenticated with AWS CLI `aws login` using the IAM user's console credentials. The resulting CLI credentials are temporary; no static access keys were created. AWS documents that this flow caches a short-lived session (up to the IAM session duration, at most 12 hours): [AWS CLI console-credential sign-in](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).
- A lingering `aws login` process was stopped after authentication; the profile continued to pass STS verification afterward.

### GitHub access

- The user supplied GitHub username `Darshan9154` and said they were signed in through a browser.
- No GitHub repository has been created or selected, no push has been made, and shell-based GitHub authentication has not been verified. At the time checked, `gh` was not installed. The user chose to start local-only and defer repository creation.

### ECR and workload resources

- Ran a read-only ECR repository listing in `eu-north-1`. It succeeded and returned no repositories.
- No ECR repository, image, EC2 instance, EKS cluster, load balancer, NAT gateway, or other workload resource was created.
- AWS Budgets showed no saved budget. The create-budget screen was opened earlier but was not submitted; the user had explicitly asked not to save it.

## Verification evidence

| Check | Result |
|---|---|
| AWS CLI version | `aws-cli/2.37.13 Python/3.14.6 Windows/11 script-exe/AMD64` |
| Local profile region | `AWS_PROFILE_REGION=eu-north-1` |
| AWS identity | `AWS_STS_AFTER_CLEANUP=success; identity_matches_devops_agent=True` |
| ECR inventory | `ECR_REPOSITORIES=none` (read-only list succeeded) |
| IAM user and MFA | IAM console showed `devops-agent`, `Console access: Enabled with MFA`, `MFA (1)`, and `Access keys (0)` |
| AWS spend/resource creation | No workload resources created; billing view showed `$100.00` remaining and `$0.00` used |

Commands used for the final CLI checks (account identifiers and full ARNs are intentionally omitted from this log):

```powershell
aws configure get region --profile retail-store-dev
aws sts get-caller-identity --profile retail-store-dev --region eu-north-1 --query Arn --output text
aws ecr describe-repositories --profile retail-store-dev --region eu-north-1 --query 'repositories[].repositoryName' --output text
```

## Failures and fixes

### Failure 1 — Harness installer did not provide AWS CLI

- **Where:** `devops_tools.py install --only aws`.
- **What happened:** `unknown tool(s): aws`; AWS CLI is not one of the tools supported by that installer.
- **Fix:** used the Windows current-user installer published by AWS and verified the MSI Authenticode signature.

### Failure 2 — `aws` was not found immediately after installation

- **Where:** version check in the same PowerShell process that ran the installer.
- **What happened:** PowerShell reported that `aws` was not recognized because the current process had not refreshed its PATH.
- **Fix:** ran the installed binary by its full path; it returned `aws-cli/2.37.13 ... Windows/11`.

### Failure 3 — Initial CLI identity check had no credentials

- **Where:** first `aws sts get-caller-identity` check.
- **What happened:** `NoCredentials: Unable to locate credentials.` An AWS Console sign-in alone had not configured the local CLI.
- **Fix:** created the non-root `devops-agent` user with `SignInLocalDevelopmentAccess`, then used the AWS CLI browser-based `aws login` flow. STS succeeded afterward.

### Failure 4 — First IAM sign-in attempt used the username in the account field

- **Where:** AWS IAM user sign-in page.
- **What happened:** AWS displayed `Authentication failed` because `devops-agent` was entered as the **Account ID or alias** instead of the **IAM username**.
- **Fix:** used the account's 12-digit ID in the first field and `devops-agent` in the username field. The user completed the password reset and passkey setup in the browser; no password or MFA code was shared.

### Safety stop — AWS CLI initially offered the root session

- **Where:** first AWS CLI browser-login attempt.
- **What happened:** the browser offered a session labeled `root`.
- **Action:** did not select it; stopped that login process and created the dedicated IAM user instead. No root credentials were cached by that attempt.

### Cleanup — Login process remained open after successful authentication

- **Where:** final `aws login` session.
- **What happened:** the local login process remained running after STS and ECR checks succeeded.
- **Fix:** stopped the lingering process, then reran STS. The result remained `AWS_STS_AFTER_CLEANUP=success; identity_matches_devops_agent=True`.

## Still open

1. Budget alerts at $25 / $50 / $75 have **not** been saved. Do not create them unless the user asks to save them.
2. Root-user MFA status has not been checked in this run; the `devops-agent` passkey MFA is verified.
3. Billing visibility is not available to `devops-agent` in the Console Home cost widget. Any billing-permission change needs a separate review.
4. GitHub shell authentication, a destination repository, and the Step 2 fork-versus-copy choice remain open.
5. ECR repositories are still absent. Create them only after the service inventory and names are confirmed; do not push images yet.

## Next safe action

Finish Step 2's service inventory and source-handling choice, then run the local Docker Compose validation before provisioning AWS infrastructure. Before any billable AWS resource is created, show the current cost estimate and wait for the user's approval. EKS, worker nodes, load balancers, and related resources have not been created.

## References

- [AWS CLI sign-in with temporary console credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [IAM user sign-in](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_sign-in.html)
- [Assign a passkey or security key](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_enable_fido.html)
- [AWS Free Tier in the new experience](https://docs.aws.amazon.com/accounts/latest/reference/bcm-lite-free-tier.html)
- [AWS CLI installation](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
