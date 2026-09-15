# -*- coding: utf-8 -*-

import unittest

from app import app


HEADERS = {"X-API-Contract-Version": "api-contract-v0.2"}


class LearningV1RoutesTest(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()
        self.client.post("/api/v1/demo/reset", headers=HEADERS)

    def test_rejects_missing_contract_version(self):
        response = self.client.get("/api/v1/profile/demo-user")
        self.assertEqual(409, response.status_code)
        self.assertEqual("CONTRACT_VERSION_MISMATCH", response.get_json()["code"])

    def test_chat_requires_contract_version(self):
        response = self.client.post("/api/agent/chat", json={"message": "今天学什么"})
        self.assertEqual(409, response.status_code)
        self.assertEqual("CONTRACT_VERSION_MISMATCH", response.get_json()["code"])

    def test_core_chain_advances_from_v1_to_v2(self):
        profile_before = self.client.get("/api/v1/profile/demo-user", headers=HEADERS).get_json()
        plan_before = self.client.get("/api/v1/plans/current", headers=HEADERS).get_json()
        self.assertEqual(42, profile_before["mastery"][0]["masteryScore"])
        self.assertEqual(1, plan_before["version"])

        created = self.client.post(
            "/api/v1/workflows",
            headers=HEADERS,
            json={"goal": "诊断二叉树后序遍历"},
        )
        self.assertEqual(201, created.status_code)

        submission = {
            "idempotencyKey": "test-submit-001",
            "answers": [
                {"exerciseId": "exercise-preorder-001", "answer": "A"},
                {"exerciseId": "exercise-inorder-001", "answer": "B"},
                {"exerciseId": "exercise-postorder-001", "answer": "B"},
            ],
        }
        result = self.client.post(
            "/api/v1/exercises/set-demo-binary-tree-001/submit",
            headers=HEADERS,
            json=submission,
        )
        self.assertEqual(200, result.status_code)
        self.assertEqual(58, result.get_json()["masteryUpdate"]["newScore"])

        profile_after = self.client.get("/api/v1/profile/demo-user", headers=HEADERS).get_json()
        plan_after = self.client.get("/api/v1/plans/current", headers=HEADERS).get_json()
        workflow_after = self.client.get("/api/v1/workflows/session-demo-001", headers=HEADERS).get_json()
        trace_after = self.client.get("/api/v1/traces/trace-demo-001", headers=HEADERS).get_json()
        self.assertEqual(58, profile_after["mastery"][0]["masteryScore"])
        self.assertEqual(2, plan_after["version"])
        self.assertEqual("completed", workflow_after["status"])
        self.assertEqual(5, trace_after["events"][-1]["stateVersion"])

    def test_submission_is_idempotent(self):
        payload = {"idempotencyKey": "same-key", "answers": []}
        first = self.client.post(
            "/api/v1/exercises/set-demo-binary-tree-001/submit", headers=HEADERS, json=payload
        )
        second = self.client.post(
            "/api/v1/exercises/set-demo-binary-tree-001/submit", headers=HEADERS, json=payload
        )
        self.assertEqual(first.get_json(), second.get_json())

    def test_rejects_malformed_answers(self):
        response = self.client.post(
            "/api/v1/exercises/set-demo-binary-tree-001/submit",
            headers=HEADERS,
            json={"idempotencyKey": "invalid-answer", "answers": [{"exerciseId": 123}]},
        )
        self.assertEqual(400, response.status_code)
        self.assertEqual("INVALID_REQUEST", response.get_json()["code"])


if __name__ == "__main__":
    unittest.main()
