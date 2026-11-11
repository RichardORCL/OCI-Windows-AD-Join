# OCI Windows Server with Active Directory join

Upload `dist/oci-windows-ad-stack.zip` to **OCI Console → Developer Services → Resource Manager → Stacks → Create stack → My configuration → .zip file**. The archive has Terraform and `schema.yaml` at its root. Select the deployment region, complete the form, review a Plan, then Apply. Resource Manager supplies the tenancy OCID automatically. No resources have been deployed by creating this project.

The form provides Windows Server **2019 / 2022 / 2025**, an OCI shape dropdown filtered to x86 Standard Flex VMs, OCPUs, memory, boot volume, compartment, availability domain, existing VCN/subnet, optional NSGs and private IP, AD DNS/domain/OU, and a Vault secret picker. Defaults are 2 OCPUs, 16 GiB RAM, a 100 GiB boot disk and no public IP. Supported shapes, image availability, capacity and shape-specific sizing limits still depend on your region. Windows licensing is charged by OCI in addition to Compute.

## Credentials: select a secret, not a password input

Before launching the stack, create an OCI Vault, an AES encryption key, and a secret **in the deployment region**. In the Console's secret creation form choose **Plain-Text** secret content and paste a JSON object in this format:

```json
{"username":"join-service@corp.example.com","password":"REPLACE_WITH_REAL_PASSWORD"}
```

`CORP\\join-service` is also valid JSON syntax for a down-level username. Paste actual JSON, not a base64 encoding, when choosing Plain-Text. The Secrets API returns its content base64 encoded; the helper decodes it. Both fields must be nonempty JSON strings. Use the secret's CURRENT version. Grant this account only the rights needed to create/join computer accounts in the target OU; Domain Admin membership is unnecessary. Existing computer account reuse is subject to Microsoft's domain join hardening and account ownership rules.

Select the **secret compartment** and **AD join credential secret** in the stack form. The form intentionally has no username/password inputs: masking a Terraform variable or marking it `sensitive` only redacts presentation and does not reliably keep its value out of state. This stack never creates a Terraform-managed secret or reads a secret bundle through a Terraform data source.

Only the secret OCID enters Terraform variables, user data and state. The Windows instance retrieves username/password directly from Vault using instance-principal authentication. The helper passes JSON to its parent PowerShell process over a pipe; credentials are not passed as process arguments, written to a credential file, or included in Terraform outputs. Bootstrap status omits raw exception messages and does not enable request logging or PowerShell transcripts. Windows/AD may independently audit the account name; the password exists briefly in process memory. Guest administrators and any principal able to execute code on this instance may use its instance identity, so use a dedicated join account and rotate/revoke access after enrollment as appropriate.

## Prerequisites

- An existing AD domain and a **unique computer name** (1–15 characters). Optional OU distinguished name, such as `OU=Servers,DC=corp,DC=example,DC=com`.
- An existing IPv4 subnet with routing through your VCN, peering, VPN or FastConnect to the domain controllers. This stack does not create networks or firewall rules. Choose NSGs in the selected VCN and ensure the subnet belongs to it. RDP access must come through existing network rules/VPN/bastion; adding a public IP does not open RDP.
- Reachable AD DNS resolvers. The worker sets these DNS addresses on the primary interface. They must resolve the AD SRV records **and** public OCI/PyPI names, using forwarding where necessary. Allow AD traffic through security lists/NSGs, Windows Firewall and intervening firewalls: DNS TCP/UDP 53, Kerberos TCP/UDP 88 and 464, LDAP TCP/UDP 389, SMB TCP 445, RPC TCP 135 and dynamic RPC TCP 49152–65535, and time synchronization UDP 123 where applicable. Additional ports depend on your AD configuration; see Microsoft's reference below. Keep clocks synchronized with the domain.
- HTTPS access to regional OCI authentication and Secrets endpoints and to `pypi.org` / `files.pythonhosted.org`. A private subnet normally needs NAT for PyPI (a service gateway alone does not reach it). IMDS at `169.254.169.254` must remain reachable without a proxy. Do not block OCI Windows activation traffic at `169.254.169.253`.
- The platform image's Cloudbase-Init Python runtime with pip. The worker discovers the standard `Cloudbase-Init\Python\python.exe` location and installs `oci==2.191.0` into a separate `C:\ProgramData\OCI-ADJoin\sdk` directory. It does not modify Cloudbase-Init's site-packages. For restricted networks, prepare an **unjoined** custom image with this SDK and dependencies in that directory and a `.ready-2.191.0` marker; test the helper's imports under the bundled Python. A private package mirror can also be configured in the image's pip settings. Runtime and wheels must be compatible; this has not been boot-tested on every image family.
- Permissions for the stack operator/Resource Manager execution identity to create/manage instances and boot volumes, use subnets/VNICs/NSGs, inspect images, tenancy/regions, and list the form's compartments/network resources/secret metadata. Secret-bundle read permission is needed by the guest, not by Terraform. Resource Manager authorization must also permit any delegated execution mode you use.

## IAM

By default the stack creates a dynamic group in the tenancy home region matching **only the created instance OCID**, plus a root-compartment policy allowing that group to read **only the selected secret** in its secret compartment. The deployment identity therefore needs permission to manage dynamic groups and policies in the tenancy. IAM is configured through a separate home-region provider.

An administrator can instead prepare instance-principal access ahead of time and uncheck **Create instance-specific Vault access**. Use a tightly controlled compartment or defined-tag matching rule in that case; ensure it matches this instance before launch. The equivalent read policy is:

```text
Allow dynamic-group <group-name> to read secret-bundles in compartment id <secret-compartment-ocid> where target.secret.id = '<secret-ocid>'
```

The automatically created IAM resources necessarily follow instance creation, so the worker retries while IAM propagates. It does not need user API keys. Existing IAM mode does not create, inspect or manage your preconfigured policies. Deleting or replacing the instance updates/removes the stack-managed group and policy; deleting the stack does not delete the existing Vault secret.

## Bootstrap and verifying the join

1. Terraform resolves the latest compatible Windows Standard Edition VM platform image for the selected year and shape, unless an image override is provided. Override selection is filtered by Windows and shape; **you must choose an image of the intended year** with the required bootstrap components. Automatic selection is checked at every plan, so a newer platform image can propose instance replacement; pin `image_ocid` after initial deployment if that is undesirable.
2. Cloudbase-Init writes nonsecret configuration and the worker scripts to an Administrators/SYSTEM-only directory and registers `OCI-ADJoin`, a scheduled task running as SYSTEM. It does not join/reboot synchronously inside user data.
3. The task starts after five minutes, waits until the Cloudbase-Init service is no longer running, configures DNS, installs the isolated SDK, reads Vault, and calls `Add-Computer`, optionally renaming the machine and selecting an OU.
4. After successfully persisting its pending state, the worker schedules a reboot with a 60-second delay. On a subsequent boot it verifies domain membership, computer name and the secure channel before marking completion and removing its task. It does not rejoin a computer that already belongs to the requested domain.
5. Prerequisite attempts recur every five minutes and on startup, with a six-hour/72-attempt limit. A process is limited to 15 minutes; overlapping runs are suppressed. An `Add-Computer` error stops the task immediately to avoid repeatedly submitting an invalid password; fix the cause before restarting. An exhausted retry window removes the task at the next attempt. IAM propagation or DNS/network errors can delay enrollment.

**A successful Terraform Apply means Compute/IAM provisioning succeeded, not that the AD join succeeded.** Terraform intentionally does not receive credentials or poll the guest. Inspect this on Windows through your approved access method:

```powershell
Get-Content C:\ProgramData\OCI-ADJoin\status.json
Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain
Test-ComputerSecureChannel
Get-ScheduledTask -TaskName OCI-ADJoin -ErrorAction SilentlyContinue
```

Expected final status is `complete`, stage `verified-after-reboot`. Intermediate states include `scheduled`, `waiting`, `retrying` and `joined_pending_reboot`. Status stages distinguish DNS, SDK installation, Vault retrieval, join and secure-channel verification. For diagnosis inspect Task Scheduler history, Cloudbase-Init logs and `C:\Windows\debug\NetSetup.log` locally; do not enable credential/request dumps. Do not manually run `read_secret.py`: its stdout is deliberately consumed only by the parent process.

After fixing a failed prerequisite, use an elevated PowerShell session to start a fresh retry window. If the task was removed, re-register it:

```powershell
Remove-Item C:\ProgramData\OCI-ADJoin\progress.json -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\OCI-ADJoin\join-domain.ps1"'
$timer = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 1)
$startup = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName OCI-ADJoin -Action $action -Trigger @($timer, $startup) -Principal $principal -Settings $settings -Force
```

For a task that still exists, removing progress and running `Start-ScheduledTask OCI-ADJoin` starts a fresh retry window. Updating Terraform variables/user data on an existing instance does **not** cause Cloudbase-Init's first-boot user data to rerun. For a new domain, use a new instance; this stack does not migrate already joined machines between domains.

Destroy removes the Compute instance, its boot volume, and stack-managed IAM resources. It does not delete the AD computer account; arrange directory cleanup separately before reusing the computer name. Terraform lifecycle changes can replace the instance, so review every Plan.

## Local development

```sh
cp terraform.tfvars.example terraform.tfvars
# Fill in nonsecret OCIDs/domain/DNS; use your normal OCI provider authentication.
terraform init
terraform validate
terraform plan
```

Terraform >= 1.2 is required for deployment; offline mocked tests require >= 1.7. The lock file pins the validated OCI provider version with Linux/Apple Silicon checksums.

```sh
terraform fmt -check -recursive
terraform test
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/package_stack.py
```

Validation passed for Terraform/provider schema (Terraform 1.7.5 / OCI provider 8.29.0), all five offline plans, all five Python tests, and the YAML form against Oracle's published Resource Manager JSON schema. This does not replace a real deployment test with your AD, subnet, IAM and Windows image. PowerShell must be tested on Windows; it is not available in the development environment used to build this stack.

## References

- [Oracle Resource Manager form schema](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/terraformconfigresourcemanager_topic-schema.htm)
- [Oracle Windows platform images and Cloudbase-Init](https://docs.oracle.com/en-us/iaas/Content/Compute/References/images.htm)
- [Oracle Resource Manager state confidentiality](https://docs.oracle.com/en-us/iaas/Content/Security/Reference/resourcemanager_security.htm)
- [Oracle Python SDK instance-principal signing](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/signing.html)
- [Oracle Secrets API client](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/secrets/client/oci.secrets.SecretsClient.html)
- [Microsoft domain join firewall requirements](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/active-directory-domain-join-troubleshooting-guidance)
- [Microsoft domain join account reuse hardening](https://support.microsoft.com/en-us/topic/kb5020276-netjoin-domain-join-hardening-changes-2b65a0f3-1f4c-42ef-ac0f-1caaf421baf8)
