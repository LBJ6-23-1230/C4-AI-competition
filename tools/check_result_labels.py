"""Reject raw internal slugs in result UI; includes a controlled negative case."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def violations(source):
    return re.findall(r"Text\(\s*['\"]([a-z]+(?:-[a-z]+)+)['\"]\s*\)", source)


def main():
    pages = ROOT / 'app/entry/src/main/ets/pages'
    errors = [(p.name, violations(p.read_text(encoding='utf-8'))) for p in
              [pages / 'ExercisePractice.ets', pages / 'WrongQuestion.ets']]
    assert violations("Text('traversal-order')") == ['traversal-order'], 'negative control failed'
    assert not violations("Text('哈希表·答错')")
    assert not any(found for _, found in errors), errors
    practice = (pages / 'ExercisePractice.ets').read_text(encoding='utf-8')
    assert 'Text(this.errorTypeText(value))' in practice
    assert 'perKnowledgeAccuracy[item.knowledgePointId] < 1' in practice
    print('PASS result labels and controlled slug regression')


if __name__ == '__main__':
    main()
