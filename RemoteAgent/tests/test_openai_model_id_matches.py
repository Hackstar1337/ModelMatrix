"""openai_model_id_matches accepts basename vs full-path /v1/models ids."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parents[1]
if str(AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(AGENT_DIR))

from agent_core import openai_model_ids_from_entries  # noqa: E402
from modelmatrix_agent import ANY_MODEL_ID, openai_model_id_matches  # noqa: E402


class OpenAIModelIdMatchesTests(unittest.TestCase):
    def test_basename_expected_matches_full_path_id(self) -> None:
        ids = [
            "/data/models/example-org/Example-27B-Q8/Example-27B-Q8_0.gguf"
        ]
        self.assertTrue(
            openai_model_id_matches("Example-27B-Q8_0.gguf", ids)
        )

    def test_full_path_expected_matches_full_path_id(self) -> None:
        full = "/data/models/x/model.gguf"
        self.assertTrue(openai_model_id_matches(full, [full]))

    def test_request_model_alias_matches(self) -> None:
        ids = ["/weights/model.gguf"]
        self.assertTrue(
            openai_model_id_matches(
                "model.gguf",
                ids,
                "/weights/model.gguf",
            )
        )

    def test_no_expected_id_never_matches(self) -> None:
        # L23: None means "no expected id" - identity must be verifiable.
        # The old "None matches anything" encoding is gone; use ANY_MODEL_ID
        # for an explicit accept-any.
        self.assertFalse(openai_model_id_matches(None, ["a"]))
        self.assertFalse(openai_model_id_matches("", ["a"]))
        self.assertFalse(openai_model_id_matches("", []))
        self.assertTrue(openai_model_id_matches(ANY_MODEL_ID, ["a"]))
        self.assertFalse(openai_model_id_matches(ANY_MODEL_ID, []))

    def test_full_path_expected_matches_basename_id(self) -> None:
        # Explicit basename rule, other direction: expected full path vs
        # basename id from the server.
        self.assertTrue(
            openai_model_id_matches("/data/models/x/model.gguf", ["model.gguf"])
        )

    def test_mismatch(self) -> None:
        self.assertFalse(
            openai_model_id_matches("other.gguf", ["/data/models/x/model.gguf"])
        )

    def test_null_model_list_is_empty(self) -> None:
        # Ollama with no pulled models answers {"object":"list","data":null};
        # discovery must treat that as "no models", never a 500.
        self.assertEqual(openai_model_ids_from_entries(None), [])
        self.assertEqual(openai_model_ids_from_entries({"id": "x"}), [])
        self.assertEqual(openai_model_ids_from_entries([{"id": "a"}, {}]), ["a"])


if __name__ == "__main__":
    unittest.main()
