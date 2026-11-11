# OCI Windows AD Join

Launch a Windows Server VM on Oracle Cloud Infrastructure and automatically join it to an existing Active Directory domain using an OCI Resource Manager stack.

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/RichardORCL/OCI-Windows-AD-Join/raw/refs/heads/main/RMS/dist/oci-windows-ad-stack.zip)

The button opens OCI Resource Manager with the packaged Terraform configuration and its setup form preloaded. You choose the deployment settings before creating resources.

## What it provides

- Windows Server 2019, 2022 or 2025 version dropdown and an OCI shape selector for x86 Standard Flex VMs.
- Instance naming, OCPUs, RAM, boot volume, availability domain, existing network, subnet and optional network security groups.
- AD domain, DNS resolvers, optional computer OU and an OCI Vault credential-secret selector.
- Cloudbase-Init bootstrap with a scheduled domain join, reboot and guest-side verification.
- Instance-specific IAM access to the selected secret, or an option to use existing IAM configuration.

The instance is private by default. Default sizing is 2 OCPUs, 16 GiB RAM and a 100 GiB boot volume. Image availability and capacity depend on the selected region and shape. OCI Compute, storage and Windows licensing charges apply.

## Before deploying

1. Prepare an existing IPv4 subnet with connectivity to your AD domain controllers and DNS servers. Allow the required AD traffic and outbound access to OCI authentication/Secrets APIs and PyPI for SDK installation.
2. Create an OCI Vault secret in the deployment region. Choose **Plain-Text** and enter JSON containing a delegated domain-join account:

   ```json
   {"username":"join-service@corp.example.com","password":"REPLACE_WITH_REAL_PASSWORD"}
   ```

3. Have permission to deploy Compute resources and use the chosen network. The default IAM setup also requires permission to manage tenancy dynamic groups and policies.
4. Click **Deploy to Oracle Cloud**, complete the form, review the plan and apply the stack. Use a unique Windows computer name.

Only the Vault secret OCID enters Terraform. The guest retrieves the username and password directly through instance-principal authentication, keeping credential values out of Terraform state, outputs and user data. See the [credential handling and prerequisites](RMS/README.md#credentials-select-a-secret-not-a-password-input) for details.

## Check the result

Terraform Apply completion confirms infrastructure provisioning. Check the domain join inside Windows:

```powershell
Get-Content C:\ProgramData\OCI-ADJoin\status.json
Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain
Test-ComputerSecureChannel
```

Expected final status is `complete`. See the [deployment and troubleshooting guide](RMS/README.md) for IAM, firewall requirements, retry behavior, recovery and cleanup.

## Repository layout

| Path | Contents |
| --- | --- |
| [`RMS/`](RMS/) | Terraform stack and Resource Manager YAML form |
| [`RMS/scripts/`](RMS/scripts/) | Windows bootstrap, Vault helper and ZIP packaging script |
| [`RMS/tests/`](RMS/tests/) | Offline Terraform plans and Python tests |
| [`RMS/dist/oci-windows-ad-stack.zip`](RMS/dist/oci-windows-ad-stack.zip) | Upload-ready package used by the deployment button |

To rebuild the deployment ZIP after editing the stack:

```sh
python3 RMS/scripts/package_stack.py
```

Commit the updated ZIP together with the source changes. The deployment button uses the packaged configuration on `main`.

## Validation

Terraform configuration validation, the form's validation against Oracle's published schema, five mocked Terraform plan tests and five Python tests passed during development. A live Windows boot and AD join must still be verified in your tenancy.

```sh
cd RMS
terraform init
terraform validate
terraform fmt -check -recursive
terraform test
python3 -m unittest discover -s tests -p 'test_*.py'
```

Deployment requires Terraform 1.2 or newer; the mocked Terraform tests require 1.7 or newer. No OCI resources are deployed by the tests.

Maintainer: [RichardORCL](https://github.com/RichardORCL).
