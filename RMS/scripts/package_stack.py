"""Build an allowlisted Resource Manager ZIP, excluding state and credentials."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    "versions.tf", "variables.tf", "main.tf", "outputs.tf", "schema.yaml",
    ".terraform.lock.hcl", "README.md", "terraform.tfvars.example",
    "scripts/bootstrap.ps1.tftpl", "scripts/join-domain.ps1", "scripts/read_secret.py",
]


def package(destination=None):
    destination = destination or ROOT / "dist" / "oci-windows-ad-stack.zip"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
        for name in FILES:
            archive.write(ROOT / name, name)
    with ZipFile(destination) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == set(FILES)
    return destination


if __name__ == "__main__":
    print(package())
