import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts import validate


class ValidateTests(unittest.TestCase):
    def test_default_command_is_fast(self):
        with mock.patch.object(validate, "execute", return_value=0) as execute:
            self.assertEqual(0, validate.main([]))
        self.assertEqual("fast", execute.call_args.args[0])

    def test_diagnostics_are_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "check.log"
            log.write_text("\n".join(f"error: failure {index}" for index in range(30)))
            excerpt = validate.diagnostic_excerpt(log, 5)
        self.assertEqual(5, len(excerpt))
        self.assertEqual("error: failure 29", excerpt[-1])

    def test_persistence_change_gets_focused_fresh_test(self):
        plan = validate.changed_plan(["Sources/JortPersistence/SQLiteStore.swift"])
        self.assertEqual(["format", "focused-foundation-debug"], [item.name for item in plan])
        command = plan[-1].commands[0]
        self.assertIn("-only-testing:JortFoundationTests/StorageTests", command)
        self.assertTrue(plan[-1].xcode)

    def test_unknown_source_change_is_conservative(self):
        plan = validate.changed_plan(["Sources/NewModule/Thing.swift"])
        self.assertEqual(["format", "foundation", "native"], [item.name for item in plan])

    def test_focused_arguments_are_enumerated(self):
        parser = validate.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["focused", "foundation", "--configuration", "Profile"])

    def test_log_root_cannot_escape(self):
        with self.assertRaises(ValueError):
            validate.safe_log_root(Path("/tmp/not-jort-validation"))

    def test_xcode_lock_acquires_and_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "xcode.lock"
            with mock.patch.object(validate, "LOCK_PATH", lock), mock.patch.object(validate, "LOG_ROOT", Path(directory)):
                with validate.xcode_lock(timeout=0):
                    self.assertTrue(lock.exists())

    def test_result_inspection_does_not_execute(self):
        with tempfile.TemporaryDirectory(dir=validate.LOG_ROOT) as directory:
            run = Path(directory)
            (run / "check.log").write_text("full output\n")
            (run / "summary.json").write_text(json.dumps({
                "status": "passed", "lane": "test", "checks": [{
                    "status": "pass", "name": "check", "duration_seconds": 1.0,
                    "log": validate.display_path(run / "check.log"),
                }],
            }))
            self.assertEqual(0, validate.show_result(run, "check", 1, validate.LOG_ROOT))


if __name__ == "__main__":
    unittest.main()
