#!/usr/bin/env python3
"""Validate all shipped translations and interpolation arguments, without network access."""
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / 'Sources/CodexRelay/Resources/Translations.json').read_text())
assert len(catalog) == 20
keys = set(catalog['en'])
for language, entries in catalog.items():
    assert set(entries) == keys, f'{language}: missing keys'
    for key, text in entries.items():
        assert text.strip(), (language, key)
        assert sorted(re.findall(r'\{\d+\}', key)) == sorted(re.findall(r'\{\d+\}', text)), (language, key)
print(f'{len(keys)} strings × {len(catalog)} languages: keys and placeholders valid')
