# OCI Windows Server with Active Directory join

First deploy the separate reusable IAM stack described in `iam/README.md`, then upload `dist/oci-windows-ad-stack.zip` to **OCI Console → Developer Services → Resource Manager → Stacks → Create stack → My configuration → .zip file**. The archive has Terraform and `schema.yaml` at its root. Select the deployment region, complete the form, review a Plan, then Apply. No resources have been deployed by creating this project.

The form provides Windows Server **2019 / 2022 / 2025**, an OCI shape dropdown filtered to x86 Standard Flex VMs, OCPUs, memory, boot volume, compartment, availability domain, existing VCN/subnet, optional NSGs and private IP, AD DNS/domain/OU, and a Vault secret picker. Defaults are 2 OCPUs, 16 GiB RAM, a 100 GiB boot disk and no public IP. Supported shapes, image availability, capacity and shape-specific sizing limits still depend on your region. Windows licensing is charged by OCI in addition to Compute.

## Credentials: select a secret, not a password input

Before launching the stack, create an OCI Vault, an AES encryption key, and a secret **in the deployment region**. In the Console's secret creation form choose **Plain-Text** secret content and paste a JSON object in this format:

```json
{"username":"join-service@corp.example.com","password":"REPLACE_WITH_REAL_PASSWORD"}
```

`CORP\\join-service` is also valid JSON syntax for a down-level username. Paste actual JSON, not a base64 encoding, when choosing Plain-Text. The Secrets API returns its content base64 encoded; the helper decodes it. Both fields must be nonempty JSON strings. Use the secret's CURRENT version. Grant this account only the rights needed to create/join computer accounts in the target OU; Domain Admin membership is unnecessary. Existing computer account reuse is subject to Microsoft's domain join hardening and account ownership rules.

Select the **secret compartment** and **AD join credential secret** in the stack form. The form intentionally has no username/password inputs: masking a Terraform variable or marking it `sensitive` only redacts presentation and does not reliably keep its value out of state. This stack never creates a Terraform-managed secret or reads a secret bundle through a Terraform data source.

Only the secret OCID enters Terraform variables, user data and state. The Windows instance retrieves username/password directly from Vault using instance-principal authentication. The helper passes JSON to its parent PowerShell process over a pipe; credentials are not passed as process arguments, written to a credential file, or included in Terraform outputs. Bootstrap status omits raw exception messages and does not enable request logging or PowerShell transcripts. Windows/AD may independently audit the account name; the password exists briefly in process memory. The temporary bootstrap tag grants instance-principal access only during enrollment. After verified join the worker removes it and waits for Vault denial; see the IAM and revocation section below for propagation and guest-administrator limitations.

## Prerequisites

- An existing AD domain and a **unique computer name** (1–15 characters). Optional OU distinguished name, such as `OU=Servers,DC=corp,DC=example,DC=com`.
- An existing IPv4 subnet with routing through your VCN, peering, VPN or FastConnect to the domain controllers. This stack does not create networks or firewall rules. Enter optional NSGs as comma-separated OCIDs (up to five); leave the field blank to attach none. Choose NSGs in the selected VCN and ensure the subnet belongs to it. RDP access must come through existing network rules/VPN/bastion; adding a public IP does not open RDP.
- Reachable AD DNS resolvers. Enable **Override DNS servers before AD join** to set the supplied DNS addresses on the primary interface and clear the DNS cache before domain discovery and joining. The override persists after reboot. Leave it unchecked (the default) to retain subnet/DHCP DNS; those resolvers must already resolve the AD domain. When enabled, at least one valid IPv4 address is required; separate multiple addresses with commas. For CLI use set `override_dns = true` together with `ad_dns_servers`. They must resolve the AD SRV records **and** public OCI/PyPI names, using forwarding where necessary. Allow AD traffic through security lists/NSGs, Windows Firewall and intervening firewalls: DNS TCP/UDP 53, Kerberos TCP/UDP 88 and 464, LDAP TCP/UDP 389, SMB TCP 445, RPC TCP 135 and dynamic RPC TCP 49152–65535, and time synchronization UDP 123 where applicable. Additional ports depend on your AD configuration; see Microsoft's reference below. Keep clocks synchronized with the domain.
- HTTPS access to regional OCI authentication and Secrets endpoints and to `pypi.org` / `files.pythonhosted.org`. A private subnet normally needs NAT for PyPI (a service gateway alone does not reach it). IMDS at `169.254.169.254` must remain reachable without a proxy. Do not block OCI Windows activation traffic at `169.254.169.253`.
- The platform image's Cloudbase-Init Python runtime with pip. The worker discovers the standard `Cloudbase-Init\Python\python.exe` location and installs `oci==2.191.0` with `--no-compile` to skip installation-time bytecode compilation into a separate `C:\ProgramData\OCI-ADJoin\sdk` directory. It does not modify Cloudbase-Init's site-packages. For restricted networks, prepare an **unjoined** custom image with this SDK and dependencies in that directory and a `.ready-2.191.0` marker; test the helper's imports under the bundled Python. A private package mirror can also be configured in the image's pip settings. Runtime and wheels must be compatible; this has not been boot-tested on every image family.
- Permissions for the stack operator/Resource Manager execution identity to create/manage instances and boot volumes, use subnets/VNICs/NSGs, inspect images/regions, and list the form's compartments/network resources/secret metadata. The server deployment identity must also be allowed to use the bootstrap tag namespace. Secret-bundle read permission is needed by the guest, not by Terraform. Resource Manager authorization must also permit any delegated execution mode you use.

## Shared IAM and temporary access

Deploy the **reusable IAM stack** from `iam/` once, with the allowed server compartment and selected Vault secret. Use the `server_stack_settings` output when configuring each server stack: compartment, secret compartment/OCID and bootstrap tag namespace/key/value must agree. This server stack creates **only the instance**, with `ADJoinBootstrap.State=pending` by default. It creates no dynamic groups or IAM policies and requires no IAM administration rights.

After reboot, the worker verifies the domain, computer name and secure channel, then removes its own bootstrap tag through the Compute API. It preserves other defined tags and uses an ETag to avoid overwriting concurrent changes. Terraform ignores later `defined_tags` changes so subsequent plans do not restore the authorization tag. All defined tags on this instance are consequently managed outside Terraform after launch; instance replacement still gets a fresh bootstrap tag.

The shared policy permits only the selected secret, self-only `INSTANCE_READ`/`INSTANCE_UPDATE`, and use of the bootstrap tag namespace. The group matches the server compartment plus the defined tag; free-form tags do not work. Do not grant another group/policy secret access independently, and do not set this bootstrap tag as a compartment default.

**Revocation is eventual.** OCI documents about an hour for dynamic-group membership changes. After tag removal the worker makes a fresh Vault request every five minutes until it receives 403/404. If still authorized, the returned bundle is discarded in memory. Authentication, connectivity, throttling and server errors do not count as confirmed revocation. A separate two-hour cleanup window bounds these attempts. `complete` means the domain is verified, tag removal succeeded, and the fresh probe was denied; existing issued identities/caches can take time to expire.

Guest administrators could reapply the tag during the temporary self-update permission window; `INSTANCE_UPDATE` also permits other updates to the caller's own instance. The bootstrap must be trusted. An external trusted cleanup/credential service is required for an enforced boundary against a compromised guest. Previously read AD credentials are not erased by revoking Vault access. Failed/unreachable instances may retain their tag: remove it administratively or terminate them, and verify revocation.

The companion IAM guide (`iam/README.md` in the repository) documents setup, permissions and migration from the old combined stack. Deploy v2 as new server stacks. Replacing an existing v1 stack's source can destroy its old group/policy and does not rerun user data; review the migration guidance first.

## Optional NSGs and existing stack configurations

`nsg_ocids` is a string to accommodate Resource Manager submitting empty optional fields as `""`. Blank means no NSGs. Supply comma-separated OCIDs, or a JSON array encoded as a string for CLI/API use:

```hcl
nsg_ocids = "ocid1.networksecuritygroup.oc1..first,ocid1.networksecuritygroup.oc1..second"
# Alternative: nsg_ocids = "[\"ocid1.networksecuritygroup.oc1..first\"]"
```

If an existing stack fails with `Missing expression` for `var.nsg_ocids`, edit the stack and upload the updated deployment ZIP before retrying Plan. Existing stacks retain their old Terraform source until explicitly updated. Then leave the NSG field blank or enter valid OCIDs. As a temporary workaround for the old list-typed configuration, set its saved `nsg_ocids` variable to the literal string `[]` via the Resource Manager API/CLI; an empty string is not a valid Terraform list expression.

## Bootstrap and verifying the join

1. Terraform resolves the latest compatible Windows Standard Edition VM platform image for the selected year and shape, unless an image override is provided. Override selection is filtered by Windows and shape; **you must choose an image of the intended year** with the required bootstrap components. Automatic selection is checked at every plan, so a newer platform image can propose instance replacement; pin `image_ocid` after initial deployment if that is undesirable.
2. Cloudbase-Init expands the gzip/base64-embedded scripts using built-in .NET support and writes nonsecret configuration and the worker scripts to an Administrators/SYSTEM-only directory and registers `OCI-ADJoin`, a scheduled task running as SYSTEM. It does not join/reboot synchronously inside user data.
3. The task starts after five minutes, waits until the Cloudbase-Init service is no longer running, applies the optional DNS override and checks AD SRV records, installs the isolated SDK, reads Vault, and calls `Add-Computer`, optionally renaming the machine and selecting an OU.
4. After successfully persisting its pending state, the worker schedules a reboot with a 60-second delay. On a subsequent boot it verifies domain membership, computer name and the secure channel before removing the bootstrap tag, waiting for Vault access denial, marking completion and removing its task. It does not rejoin a computer that already belongs to the requested domain.
5. Prerequisite attempts recur every five minutes and on startup, with a six-hour/72-attempt enrollment limit plus a separate two-hour post-join cleanup window. A process is limited to 15 minutes; overlapping runs are suppressed. An `Add-Computer` error stops the task immediately to avoid repeatedly submitting an invalid password; fix the cause before restarting. An exhausted retry window removes the task at the next attempt. IAM propagation or DNS/network errors can delay enrollment.

**A successful Terraform Apply means Compute provisioning succeeded, not that the AD join succeeded.** Terraform intentionally does not receive credentials or poll the guest. Inspect this on Windows through your approved access method:

```powershell
Get-Content C:\ProgramData\OCI-ADJoin\status.json
Get-Content C:\ProgramData\OCI-ADJoin\worker.log -Tail 50
Get-Content C:\ProgramData\OCI-ADJoin\sdk-install.log -Tail 50 -ErrorAction SilentlyContinue
Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain
Test-ComputerSecureChannel
Get-ScheduledTask -TaskName OCI-ADJoin -ErrorAction SilentlyContinue
```

Expected final status is `complete`, stage `domain-verified-tag-removed-vault-denied`. Intermediate states include `running` (with the current stage), `scheduled`, `waiting`, `retrying`, `joined_pending_reboot` and `revocation_pending`. A `bootstrap-tag-removal` or `vault-revocation` retry means access cleanup is unfinished. Status updates at the start of each stage. `worker.log` appends UTC stage transitions plus exception type/HRESULT/native error codes, without raw exception messages or credentials. `sdk-install.log` contains pip installation diagnostics only; Vault helper output is never routed there. If the first install is slow, check this file and the Python process; the SDK marker is created only after installation succeeds. Both logs reside in the Administrators/SYSTEM-only bootstrap directory. For diagnosis inspect Task Scheduler history, Cloudbase-Init logs and `C:\Windows\debug\NetSetup.log` locally; do not enable credential/request dumps. Do not manually run `read_secret.py`: its stdout is deliberately consumed only by the parent process.

### Stage timings

`C:\ProgramData\OCI-ADJoin\timings.jsonl` is an append-only JSON Lines file for analysis. It records `bootstrap_scheduled`, `run_start`, `stage_start`, `stage_end`, `run_end`, numeric error records, and SDK cache/configuration details. Each worker invocation gets its own `run_id`, including retries and post-reboot runs.

Every stage records its UTC start and end timestamps, outcome, and `duration_ms`. Elapsed durations use a monotonic Stopwatch rather than the wall clock. The final stage is flushed on success, a handled failure, waiting/retry exits and reboot scheduling. A forced process kill or power loss can leave a `stage_start` without an end record; treat that stage as interrupted, not as zero-duration. `status.json` includes the run ID, active stage, its start timestamp and elapsed time at the last status write. `worker.log` also records completed-stage durations.

Stage durations cover active work in each task run. Five-minute retry intervals and reboot downtime are gaps between runs, not active stage time; UTC timestamps and the initial `bootstrap_scheduled.first_run_utc` allow those waits to be analyzed separately. The `sdk_configuration` event distinguishes a fresh `--no-compile` install (`cache_hit=false`) from reusing an existing SDK. Updating a VM with an already installed SDK does not benchmark installation again. Use a new server stack/instance for a clean comparison; OCI user_data is set at launch and is not a mechanism for updating an existing guest script.

```powershell
$events = Get-Content C:\ProgramData\OCI-ADJoin\timings.jsonl |
    ForEach-Object { $_ | ConvertFrom-Json }
$stages = $events | Where-Object { $_.event -eq 'stage_end' }
$stages | Select-Object run_id, stage, outcome, started_utc, ended_utc,
    @{Name='seconds'; Expression={[Math]::Round($_.duration_ms / 1000, 3)}} |
    Format-Table -AutoSize
$stages | Export-Csv C:\ProgramData\OCI-ADJoin\stage-timings.csv -NoTypeInformation
```

Timing events contain fixed stage labels, identifiers and numeric diagnostics. They never contain the join credentials, config contents, raw helper output or exception messages. SDK install details remain in `sdk-install.log`. Run the logging regression tests with `pwsh -NoProfile -File tests/test_stage_logging.ps1`; these exercise transitions, failures, early exits and JSON output without calling OCI or AD.

Existing VMs keep their installed script until explicitly updated; a GitHub/ZIP update alone does not add these logs to an already-running VM.

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

Destroying this server stack removes the Compute instance and its boot volume; it leaves the separate reusable IAM stack intact. It does not delete the AD computer account; arrange directory cleanup separately before reusing the computer name. Terraform lifecycle changes can replace the instance, so review every Plan.

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

Validation passed for Terraform/provider schema (Terraform 1.7.5 / OCI provider 8.29.0), the offline plans for both server and IAM stacks, the Python credential/cleanup/package tests, and the YAML form against Oracle's published Resource Manager JSON schema. This does not replace a real deployment test with your AD, subnet, IAM and Windows image. PowerShell syntax and timing regression checks pass under portable PowerShell 7.7 on macOS, including the worker initialization-failure path. The production Windows PowerShell 5.1 execution, live AD join and measured performance still require Windows testing.

## References

- [Oracle Resource Manager form schema](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/terraformconfigresourcemanager_topic-schema.htm)
- [Oracle Windows platform images and Cloudbase-Init](https://docs.oracle.com/en-us/iaas/Content/Compute/References/images.htm)
- [Oracle Resource Manager state confidentiality](https://docs.oracle.com/en-us/iaas/Content/Security/Reference/resourcemanager_security.htm)
- [Oracle Python SDK instance-principal signing](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/signing.html)
- [Oracle dynamic-group propagation](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm)
- [Oracle self-update permission example](https://docs.oracle.com/en-us/iaas/stack-monitoring/doc/service-requirements.html)
- [Oracle Secrets API client](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/secrets/client/oci.secrets.SecretsClient.html)
- [Microsoft domain join firewall requirements](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/active-directory-domain-join-troubleshooting-guidance)
- [Microsoft domain join account reuse hardening](https://support.microsoft.com/en-us/topic/kb5020276-netjoin-domain-join-hardening-changes-2b65a0f3-1f4c-42ef-ac0f-1caaf421baf8)
