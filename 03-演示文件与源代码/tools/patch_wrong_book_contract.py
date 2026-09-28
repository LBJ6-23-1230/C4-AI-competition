"""Add the wrong-book and exercise review declarations to both OpenAPI copies."""
from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FILES = (ROOT / "contracts/openapi.json", ROOT / "app/contracts/openapi.json")


def response(ref: str, description: str) -> dict:
    return {"description": description, "content": {"application/json": {
        "schema": {"$ref": f"#/components/schemas/{ref}"}}}}


for path in FILES:
    document = json.loads(path.read_text(encoding="utf-8"))
    paths = document["paths"]
    schemas = document["components"]["schemas"]
    common_parameter = {"$ref": "#/components/parameters/ContractVersionHeader"}
    item_parameter = {"name": "exerciseId", "in": "path", "required": True,
                      "schema": {"type": "string"}}
    paths["/api/v1/wrong-book"] = {"get": {
        "summary": "按课程读取当前身份的错题本", "operationId": "listWrongBook",
        "parameters": [common_parameter],
        "responses": {"200": response("WrongBookResponse", "错题本")}}}
    paths["/api/v1/wrong-book/{exerciseId}"] = {"post": {
        "summary": "手动加入或移出错题本", "operationId": "toggleWrongBook",
        "parameters": [item_parameter, common_parameter],
        "requestBody": {"required": True, "content": {"application/json": {
            "schema": {"$ref": "#/components/schemas/WrongBookToggleRequest"}}}},
        "responses": {"200": response("WrongBookToggleResponse", "操作结果"),
                      "404": {"$ref": "#/components/responses/NotFound"}}}}
    paths["/api/v1/wrong-book/{exerciseId}/attempt"] = {"post": {
        "summary": "在错题本中作答；累计答对三次自动移出", "operationId": "attemptWrongBook",
        "parameters": [item_parameter, common_parameter],
        "requestBody": {"required": True, "content": {"application/json": {
            "schema": {"$ref": "#/components/schemas/WrongBookAttemptRequest"}}}},
        "responses": {"200": response("WrongBookAttemptResponse", "判题与移出状态"),
                      "404": {"$ref": "#/components/responses/NotFound"}}}}

    schemas["ExerciseReview"] = {"type": "object", "required": [
        "exerciseId", "selectedAnswer", "correctAnswer", "correct", "explanation", "inWrongBook"],
        "properties": {
            "exerciseId": {"type": "string"}, "selectedAnswer": {"type": "string"},
            "correctAnswer": {"type": "string"}, "correct": {"type": "boolean"},
            "explanation": {"type": "string"}, "inWrongBook": {"type": "boolean"}}}
    submit = schemas.get("ExerciseSubmitResponse", {})
    submit.setdefault("properties", {})["review"] = {
        "type": "array", "items": {"$ref": "#/components/schemas/ExerciseReview"}}
    required = submit.setdefault("required", [])
    if "review" not in required:
        required.append("review")
    schemas["WrongBookItem"] = {"allOf": [
        {"$ref": "#/components/schemas/Exercise"}, {"type": "object", "required": [
            "courseName", "explanation", "correctCount", "wrongCount", "addedAutomatically", "addedAt"],
         "properties": {"courseName": {"type": "string"}, "explanation": {"type": "string"},
             "correctCount": {"type": "integer"}, "wrongCount": {"type": "integer"},
             "addedAutomatically": {"type": "boolean"}, "addedAt": {"type": "string"},
             "lastPracticedAt": {"type": "string", "nullable": True}}}]}
    schemas["WrongBookCourse"] = {"type": "object", "required": ["courseName", "items"],
        "properties": {"courseName": {"type": "string"}, "items": {"type": "array",
            "items": {"$ref": "#/components/schemas/WrongBookItem"}}}}
    schemas["WrongBookResponse"] = {"type": "object", "required": ["userId", "total", "courses"],
        "properties": {"userId": {"type": "string"}, "total": {"type": "integer"},
            "courses": {"type": "array", "items": {"$ref": "#/components/schemas/WrongBookCourse"}}}}
    schemas["WrongBookToggleRequest"] = {"type": "object", "required": ["added"],
        "properties": {"added": {"type": "boolean"}}}
    schemas["WrongBookToggleResponse"] = {"type": "object", "required": ["exerciseId", "added", "removed"],
        "properties": {"exerciseId": {"type": "string"}, "added": {"type": "boolean"},
            "removed": {"type": "boolean"}, "item": {"$ref": "#/components/schemas/WrongBookItem"}}}
    schemas["WrongBookAttemptRequest"] = {"type": "object", "required": ["answer"],
        "properties": {"answer": {"type": "string"}}}
    schemas["WrongBookAttemptResponse"] = {"type": "object", "required": [
        "exerciseId", "correct", "correctAnswer", "explanation", "correctCount", "removed"],
        "properties": {"exerciseId": {"type": "string"}, "correct": {"type": "boolean"},
            "correctAnswer": {"type": "string"}, "explanation": {"type": "string"},
            "correctCount": {"type": "integer"}, "removed": {"type": "boolean"}}}
    path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
