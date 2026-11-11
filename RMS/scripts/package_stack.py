"""Build an allowlisted Resource Manager ZIP, excluding state and credentials."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    "versions.tf", "variables.tf", "main.tf", "outputs.tf", "schema.yaml",
    ".terraform.lock.hcl", "README.md", "terraform.tfvars.example",
    "scripts/bootstrap.ps1.tftpl", "scripts/join-domain.ps1", "scripts/read_secret.py", "scripts/cleanup_access.py", "scripts/stage_logging.ps1",
]


def build(source, files, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
        for name in files:
            archive.write(source / name, name)
    with ZipFile(destination) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == set(files)
    return destination


IAM_FILES = ["versions.tf", "variables.tf", "main.tf", "outputs.tf", "schema.yaml",
             ".terraform.lock.hcl", "README.md", "terraform.tfvars.example"]


def package(destination=None):
    return build(ROOT, FILES, destination or ROOT / "dist" / "oci-windows-ad-stack.zip")


def package_iam(destination=None):
    return build(ROOT / "iam", IAM_FILES, destination or ROOT / "dist" / "oci-windows-ad-iam-stack.zip")


if __name__ == "__main__":
    print(package_iam())
    print(package())
