import datetime as dt
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import announced_chart as selector


NOW = dt.datetime(2026, 10, 29, 12, tzinfo=dt.timezone.utc)


def chart(chart_version, app_version, name="gitlab/gitlab"):
    return dict(version=chart_version, app_version=app_version, name=name)


class AnnouncedChartTests(unittest.TestCase):
    def test_published_chart_without_announcement_is_skipped(self):
        rows = [chart("10.5.3", "v19.5.3"), chart("10.5.1", "v19.5.1")]
        with patch.object(selector, "gitlab_announced", side_effect=lambda v, _: v == (19, 5, 1)):
            self.assertEqual(selector.select_chart(rows, "gitlab", NOW)["version"], "10.5.1")

    def test_prefers_newest_announced_app_then_chart(self):
        rows = [chart("10.6.0", "19.4.0"), chart("10.5.1", "19.5.1"), chart("10.5.2", "19.5.1")]
        with patch.object(selector, "gitlab_announced", return_value=True):
            self.assertEqual(selector.select_chart(rows, "gitlab", NOW)["version"], "10.5.2")

    def test_prereleases_and_other_charts_are_excluded(self):
        rows = [chart("10.6.0-rc1", "19.6.0"), chart("10.6.0", "19.6.0-rc1"),
                chart("10.7.0", "19.7.0", "gitlab/other"), chart("10.5.1", "19.5.1")]
        with patch.object(selector, "gitlab_announced", return_value=True) as announced:
            self.assertEqual(selector.select_chart(rows, "gitlab", NOW)["version"], "10.5.1")
            announced.assert_called_once()

    def test_announcement_requires_date_title_and_no_draft(self):
        text = '---\ntitle: "GitLab Critical Patch Release: 19.5.1, 19.4.3"\ndate: 2026-10-21\n---\n'
        self.assertTrue(selector.published_announcement(text, (19, 5, 1), NOW.date()))
        self.assertFalse(selector.published_announcement(text, (19, 5, 3), NOW.date()))
        self.assertFalse(selector.published_announcement(text.replace("2026-10-21", "2026-10-30"), (19, 5, 1), NOW.date()))
        self.assertFalse(selector.published_announcement(text.replace("date:", "draft: true\ndate:"), (19, 5, 1), NOW.date()))
        self.assertFalse(selector.published_announcement(text.replace("19.5.1", "19.5.1-rc1"), (19, 5, 1), NOW.date()))

    def test_monthly_announcement_confirms_zero_patch(self):
        text = '---\ntitle: "GitLab 19.5 release notes"\ndate: 2026-10-15\n---\n'
        self.assertTrue(selector.published_announcement(text, (19, 5, 0), NOW.date()))

    def test_runner_future_and_upcoming_releases_are_not_approved(self):
        import json
        data = dict(tag_name="v19.5.2", released_at="2026-10-28T22:56:52Z", upcoming_release=False)
        with patch.object(selector, "fetch", return_value=json.dumps(data)):
            self.assertTrue(selector.runner_announced((19, 5, 2), NOW))
        for changes in [dict(upcoming_release=True), dict(released_at="2026-10-30T00:00:00Z"), dict(tag_name="v19.5.2-rc1")]:
            with patch.object(selector, "fetch", return_value=json.dumps(data | changes)):
                self.assertFalse(selector.runner_announced((19, 5, 2), NOW))

    def test_network_failure_does_not_fall_back_to_chart_index(self):
        with patch.object(selector, "gitlab_announced", side_effect=HTTPError("url", 403, "Forbidden", {}, None)):
            with self.assertRaises(HTTPError):
                selector.select_chart([chart("10.5.3", "19.5.3")], "gitlab", NOW)

    def test_no_announced_version_is_an_error(self):
        with patch.object(selector, "gitlab_announced", return_value=False):
            with self.assertRaises(ValueError):
                selector.select_chart([chart("10.5.3", "19.5.3")], "gitlab", NOW)


class DowngradeGuardTests(unittest.TestCase):
    def guard(self, pinned, installed, target):
        # Load function definitions only; never execute the audit/apply entrypoint.
        script = Path(__file__).with_name("check_latest_stable.sh").read_text()
        definitions = script.split("\nrequire_command curl\n", 1)[0]
        command = definitions + '''
chart_app_version() { if [[ "$2" == current ]]; then printf '%s' "$PINNED"; else printf '%s' "$TARGET"; fi; }
helm() { printf '%s' "$HELM_ROWS"; }
refuse_chart_downgrade gitlab/gitlab current target gitlab
'''
        import os
        import json
        env = os.environ | dict(PINNED=pinned, TARGET=target,
                                HELM_ROWS=json.dumps([dict(app_version=installed)] if installed else []))
        return subprocess.run(["bash", "-c", command], env=env, capture_output=True, text=True)

    def test_refuses_deployed_downgrade_even_when_pin_matches_target(self):
        result = self.guard("19.5.1", "19.5.3", "19.5.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Automatic downgrade refused", result.stderr)

    def test_refuses_pin_downgrade_without_installed_release(self):
        self.assertNotEqual(self.guard("19.5.3", "", "19.5.1").returncode, 0)

    def test_allows_same_version_and_upgrade(self):
        self.assertEqual(self.guard("19.5.1", "19.4.1", "19.5.1").returncode, 0)
        self.assertEqual(self.guard("19.5.1", "19.5.1", "19.5.1").returncode, 0)


if __name__ == "__main__":
    unittest.main()
