# -*- coding: utf-8 -*-
"""把 `data/repository.json` 迁移到 SQLite。

背景
----
`JsonRepository` 每次 `save()` 全量重写整个 JSON 文件，实测后果：
* 文件随账号数线性膨胀（反复联调后被撑到 324 KB，干净基线只要 38 KB）
* 单次 save 约 30ms
* 双进程并发写有 5–19% 失败率（进程内 `RLock` 跨不了进程）

切到 SQLite 后每次只写一行，并发由数据库保证。两者共用 `Repository` 抽象，
业务代码无需改动，只由 `ZHIXUE_DB` 环境变量选择。

用法::

    python tools/migrate_repository.py                    # 默认 JSON -> SQLite
    python tools/migrate_repository.py --dry-run          # 只报告
    python tools/migrate_repository.py --verify           # 迁完逐条比对
    python tools/migrate_repository.py --to-json          # 反向：SQLite -> JSON

迁移是**只读源文件**的：JSON 不会被删除或改写，随时可以切回来。
"""

import argparse
import json
import pathlib
import sqlite3
import sys

HERE = pathlib.Path(__file__).resolve().parent
SERVER = HERE.parent / "server" / "zhixue-agent-server"
DEFAULT_JSON = SERVER / "data" / "repository.json"
DEFAULT_SQLITE = SERVER / "data" / "repository.sqlite"


def load_json(path: pathlib.Path) -> dict:
    if not path.exists():
        print(f"找不到 {path}")
        sys.exit(1)
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        print(f"{path} 顶层不是对象，无法迁移")
        sys.exit(1)
    return data


def migrate(json_path: pathlib.Path, sqlite_path: pathlib.Path, dry_run: bool) -> dict:
    data = load_json(json_path)
    counts = {}
    total = 0
    for collection, table in data.items():
        if not isinstance(table, dict):
            continue
        counts[collection] = len(table)
        total += len(table)

    print("=" * 74)
    print("JSON -> SQLite 迁移")
    print("=" * 74)
    print(f"  源  : {json_path}  ({json_path.stat().st_size:,} B)")
    print(f"  目标: {sqlite_path}")
    print(f"  集合: {len(counts)} 个，记录 {total} 条")
    for name, n in sorted(counts.items()):
        print(f"    {name:24s} {n}")

    if dry_run:
        print("\n  --dry-run：未写入。")
        return counts

    sqlite_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(sqlite_path)
    try:
        connection.execute("""
            CREATE TABLE IF NOT EXISTS records (
                collection TEXT NOT NULL,
                item_id TEXT NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (collection, item_id)
            )
        """)
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_records_collection ON records(collection)")

        written = 0
        for collection, table in data.items():
            if not isinstance(table, dict):
                continue
            for item_id, value in table.items():
                connection.execute("""
                    INSERT INTO records(collection, item_id, value) VALUES (?, ?, ?)
                    ON CONFLICT(collection, item_id) DO UPDATE SET value = excluded.value
                """, (collection, str(item_id), json.dumps(value, ensure_ascii=False)))
                written += 1
        connection.commit()
    finally:
        connection.close()

    print(f"\n  已写入 {written} 条 -> {sqlite_path}")
    print(f"  文件大小 {sqlite_path.stat().st_size:,} B")
    print("\n  启动方式：")
    print('    $env:ZHIXUE_DB="sqlite"; python run.py')
    print("  （JSON 源文件未被修改，随时可切回默认的 json 后端）")
    return counts


def verify(json_path: pathlib.Path, sqlite_path: pathlib.Path) -> bool:
    """逐条比对 JSON 与 SQLite 内容是否一致。"""
    data = load_json(json_path)
    connection = sqlite3.connect(sqlite_path)
    ok = True
    checked = 0
    try:
        for collection, table in data.items():
            if not isinstance(table, dict):
                continue
            for item_id, value in table.items():
                row = connection.execute(
                    "SELECT value FROM records WHERE collection = ? AND item_id = ?",
                    (collection, str(item_id))).fetchone()
                if row is None:
                    print(f"  [缺失] {collection}/{item_id}")
                    ok = False
                    continue
                if json.loads(row[0]) != value:
                    print(f"  [不一致] {collection}/{item_id}")
                    ok = False
                checked += 1
        orphan = connection.execute("""
            SELECT COUNT(*) FROM records
        """).fetchone()[0]
        if orphan != checked:
            print(f"  [数量不符] SQLite {orphan} 条 vs JSON {checked} 条")
            ok = False
    finally:
        connection.close()
    print(f"\n  比对完成：{checked} 条，{'全部一致' if ok else '存在差异'}")
    return ok


def main() -> int:
    parser = argparse.ArgumentParser(description="JSON <-> SQLite 仓储迁移")
    parser.add_argument("--json", default=str(DEFAULT_JSON))
    parser.add_argument("--sqlite", default=str(DEFAULT_SQLITE))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verify", action="store_true", help="迁移后逐条比对")
    parser.add_argument("--to-json", action="store_true", help="反向：SQLite -> JSON")
    args = parser.parse_args()

    json_path = pathlib.Path(args.json)
    sqlite_path = pathlib.Path(args.sqlite)

    if args.to_json:
        print("反向迁移（SQLite -> JSON）")
        connection = sqlite3.connect(sqlite_path)
        try:
            rows = connection.execute(
                "SELECT collection, item_id, value FROM records").fetchall()
        finally:
            connection.close()
        out: dict[str, dict] = {}
        for collection, item_id, value in rows:
            out.setdefault(collection, {})[item_id] = json.loads(value)
        if args.dry_run:
            print(f"  将写出 {len(rows)} 条到 {json_path}（--dry-run 未写入）")
            return 0
        json_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"  已写出 {len(rows)} 条 -> {json_path}")
        return 0

    migrate(json_path, sqlite_path, args.dry_run)
    if args.verify and not args.dry_run:
        return 0 if verify(json_path, sqlite_path) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
