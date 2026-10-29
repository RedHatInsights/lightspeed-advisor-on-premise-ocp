"""Leak investigation monkeypatches loaded via PYTHONPATH/sitecustomize.

This keeps mock archive processing out of the production service code while still
allowing the leak script to exercise upload, worker, and database-save paths.
"""

import json
import logging
import os
import sys

# During interpreter startup, sitecustomize can run before Python has put the
# current working directory on sys.path for `python -m app.main`. Add it
# explicitly so this hook can import the application package.
sys.path.insert(0, os.getcwd())

logger = logging.getLogger(__name__)


def _install_mock_processor() -> None:
    from app.services.processor_service import ProcessorService

    results_json = json.dumps(
        {
            "reports": [
                {
                    "component": "ccx_rules_ocp.external.rules.mock_rule.report",
                    "key": "MOCK_RULE_HIT",
                    "type": "rule",
                    "details": {"reason": "leak investigation monkeypatch"},
                }
            ]
        }
    )

    def process_with_insights_core(self, archive_path: str) -> tuple[str, str]:
        logger.warning(
            "Leak investigation monkeypatch: skipping insights-core analysis for %s",
            archive_path,
        )
        return (
            os.environ.get("LEAK_MOCK_ARCHIVE_CLUSTER_ID", "mock-cluster"),
            results_json,
        )

    ProcessorService.process_with_insights_core = process_with_insights_core
    logger.warning("Installed leak investigation ProcessorService monkeypatch")


if os.environ.get("LEAK_MOCK_ARCHIVE_PROCESSING", "").lower() in {"true", "1", "yes"}:
    _install_mock_processor()
