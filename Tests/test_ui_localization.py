"""Source/catalog contract; no app launch or user preferences.
Also validates a packaged .app when MEETING_NOTES_LOCALIZATION_APP is set.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

def string_end(source, index):
    quote = '"""' if source.startswith('"""', index) else '"'
    cursor = index + len(quote)
    while cursor < len(source):
        if source.startswith('\\(', cursor):
            cursor = expression_end(source, cursor + 2)
        elif source[cursor] == '\\':
            cursor += 2
        elif source.startswith(quote, cursor):
            return cursor + len(quote)
        else:
            cursor += 1
    raise ValueError('unterminated literal')

def expression_end(source, cursor):
    depth = 1
    while depth:
        if source[cursor] == '"':
            cursor = string_end(source, cursor)
            continue
        if source[cursor] == '(':
            depth += 1
        if source[cursor] == ')':
            depth -= 1
        cursor += 1
    return cursor

def literal_key(raw):
    count = 3 if raw.startswith('"""') else 1
    source = raw[count:-count]
    if count == 3:
        lines = source.splitlines()
        indent = len(lines[-1]) - len(lines[-1].lstrip())
        source = '\n'.join(line[indent:] for line in lines[1:-1]).replace('\\\n', '')
    result, cursor = '', 0
    while cursor < len(source):
        if source.startswith('\\(', cursor):
            result += '%@'
            cursor = expression_end(source, cursor + 2)
        elif source[cursor] == '\\':
            result += {'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(source[cursor + 1], source[cursor + 1])
            cursor += 2
        else:
            result += source[cursor]
            cursor += 1
    return result

def catalog(folder):
    result = {}
    for match in re.finditer(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', (folder / 'Localizable.strings').read_text(), re.M):
        key, value = map(json.loads, match.groups())
        if key in result:
            raise ValueError('duplicate key: ' + key)
        result[key] = value
    return result

# Brands, syntax-only scaffolding and user-editable raw command/header examples
# are intentionally unchanged. This is a finite ledger, not a catch-all.
EXEMPT = {
    'Meeting Notes', 'ChatGPT', 'Codex', 'Tana', 'OpenAI', 'OPENAI', 'URL',
    'username@example.com', '~/MeetingNotes', 'https://example.com/meetings',
    'Authorization: Bearer your-token\nX-Source: Meeting Notes', 'sk-...', '[%@] [%@] %@',
}

def source_keys():
    result = set()
    for path in (ROOT / 'Sources/MeetingNotes').glob('*.swift'):
        source = path.read_text()
        for match in re.finditer(r'UIStrings\.(?:text|string|format)\(\s*(?=")', source):
            begin = match.end()
            result.add(literal_key(source[begin:string_end(source, begin)]))
        for match in re.finditer(r'UIStrings\.resolve\(', source):
            end = expression_end(source, match.end())
            index = match.end()
            while index < end:
                if source[index] == '"':
                    last = string_end(source, index)
                    result.add(literal_key(source[index:last]))
                    index = last
                else:
                    index += 1
    return result

class LocalizationTests(unittest.TestCase):
    def test_bad_then_good_owned_keys_and_formats(self):
        en = catalog(ROOT / 'Resources/en.lproj')
        zh = catalog(ROOT / 'Resources/zh-Hans.lproj')
        required = source_keys() - EXEMPT
        bad = dict(zh)
        del bad['Start recording']
        self.assertIn('Start recording', required - bad.keys())
        self.assertEqual(required - zh.keys(), set())
        self.assertEqual(set(en), set(zh))
        for key in en:
            self.assertEqual(re.findall(r'%(?:@|d)', en[key]), re.findall(r'%(?:@|d)', zh[key]), key)

    def test_owned_literal_presentation_uses_explicit_lookup(self):
        # SwiftUI literal overloads otherwise follow the process language in
        # menus/AppKit hosts and can miss the user's manual language choice.
        raw = []
        pattern = r'\b(?:Text|Button|Label|Toggle|Picker|Section|GroupBox|Menu|TextField|SecureField|ContentUnavailableView|help|accessibilityLabel|navigationTitle)\(\s*"'
        for path in (ROOT / 'Sources/MeetingNotes').glob('*.swift'):
            for match in re.finditer(pattern, path.read_text()):
                raw.append(f'{path.name}:{path.read_text()[:match.start()].count(chr(10)) + 1}')
        self.assertEqual(raw, [])

    def test_optional_packaged_app_actual_bundle_lookup(self):
        app = os.environ.get('MEETING_NOTES_LOCALIZATION_APP')
        if not app:
            self.skipTest('packaged app is supplied only after isolated build')
        # This is Foundation Bundle lookup in a separate Swift interpreter,
        # not merely checking resource paths and never executing the app.
        script = r'''import Foundation
let bundle = Bundle(path: CommandLine.arguments[1])!
for (lang, expected) in [("en", "Start recording"), ("zh-Hans", "开始记录")] {
  let path = bundle.path(forResource: lang, ofType: "lproj")!
  let localized = Bundle(path: path)!
  precondition(localized.localizedString(forKey: "Start recording", value: nil, table: "Localizable") == expected)
  precondition(localized.localizedString(forKey: "__bad_sample__", value: "missing", table: "Localizable") == "missing")
}
print("PACKAGED_BUNDLE_LOOKUP_OK")
'''
        subprocess.run(['swift', '-e', script, app], check=True, timeout=60)

if __name__ == '__main__':
    unittest.main()
