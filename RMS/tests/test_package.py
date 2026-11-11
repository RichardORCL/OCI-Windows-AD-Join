import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("package_stack", ROOT / "scripts/package_stack.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageTest(unittest.TestCase):
    def test_archive_excludes_local_state_and_variables(self):
        with tempfile.TemporaryDirectory() as directory:
            path = packager.package(Path(directory) / "stack.zip")
            with ZipFile(path) as archive:
                names = archive.namelist()
                self.assertIn("schema.yaml", names)
                self.assertIn("main.tf", names)
                self.assertIn("scripts/read_secret.py", names)
                self.assertIn("scripts/cleanup_access.py", names)
                self.assertIn("scripts/stage_logging.ps1", names)
                self.assertIn("scripts/configuration.ps1", names)
                self.assertNotIn('resource "oci_identity_dynamic_group"', archive.read("main.tf").decode())
                self.assertNotIn('resource "oci_identity_policy"', archive.read("main.tf").decode())
                self.assertFalse(any(name.startswith("iam/") for name in names))
                self.assertFalse(any(name.endswith((".tfstate", ".tfvars", ".tfplan")) for name in names))
                self.assertFalse(any(name.startswith(".terraform/") for name in names))
                self.assertIsNone(archive.testzip())

    def test_iam_archive_is_a_separate_root_without_compute_or_guest_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = packager.package_iam(Path(directory) / "iam.zip")
            with ZipFile(path) as archive:
                self.assertIn("schema.yaml", archive.namelist())
                main = archive.read("main.tf").decode()
                self.assertIn('resource "oci_identity_dynamic_group"', main)
                self.assertNotIn('resource "oci_core_instance"', main)
                self.assertFalse(any(n.startswith("scripts/") for n in archive.namelist()))
                self.assertIsNone(archive.testzip())


if __name__ == "__main__":
    unittest.main()
