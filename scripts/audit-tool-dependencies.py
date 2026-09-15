#!/usr/bin/env python3
"""Audit compiler module edges, with negative fixtures usable before extraction."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ALLOWED = {
    'JortToolContracts': {'Foundation'},
    'JortToolRuntime': {'Foundation', 'CryptoKit', 'Security', 'Darwin', 'JortToolContracts', 'JortJavaScript'},
    'JortSettings': {'Foundation', 'CryptoKit', 'Security', 'Darwin', 'SQLite3', 'JortToolContracts'},
    'JortDocument': {'Foundation', 'CryptoKit', 'JortToolContracts'},
    'JortAppKit': {'Foundation', 'AppKit', 'QuartzCore', 'CoreText', 'UniformTypeIdentifiers', 'JortDocument', 'JortPersistence', 'JortSettings', 'JortToolContracts'},
}

def violations(module, source):
    imports = re.findall(r'^\s*(?:@\w+\s+)?import\s+(\w+)', source, re.M)
    errors = [f'{module} imports {edge}' for edge in imports if edge not in ALLOWED[module]]
    if module == 'JortToolContracts':
        errors += [f'{module} references {symbol}' for symbol in ['URLSession', 'URLRequest', 'FileManager', 'SQLite3', 'jort_js_'] if re.search(r'\b' + symbol, source)]
    if module == 'JortAppKit':
        errors += [f'{module} references {symbol}' for symbol in ['ToolRuntime', 'OpenRouterProvider', 'BoundedOpenRouterTransport', 'URLSession', 'jort_js_'] if re.search(r'\b' + symbol, source)]
    if re.search(r'\bstatic\s+var\s+(?:shared|services|serviceLocator)\b', source) or re.search(r'\bstatic\s+var\s+\w+[^\n]*(?:ToolExecuting|ToolInvocationCoordinating|ModelProvider|SettingsStore)', source):
        errors.append(f'{module} declares mutable global service lookup')
    return errors

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        fixtures = json.loads((ROOT / 'Tests/Architecture/forbidden-tool-edges.json').read_text())
        for fixture in fixtures:
            assert violations(fixture['module'], fixture['source']), fixture
        for module in ALLOWED:
            assert not violations(module, 'import Foundation\n')
        print(f'{len(fixtures)} forbidden dependency fixtures rejected.')
        return
    errors = []
    for module in ALLOWED:
        for path in (ROOT / 'Sources' / module).rglob('*.swift'):
            errors += [f'{path.relative_to(ROOT)}: {e}' for e in violations(module, path.read_text())]
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'Jort.xcodeproj/project.pbxproj')]))['objects']
    for value in project.values():
        module = value.get('name')
        if value.get('isa') != 'PBXNativeTarget' or module not in ALLOWED:
            continue
        for dep in value.get('dependencies', []):
            target = project.get(project[dep].get('target'), {}).get('name')
            if target and target not in ALLOWED[module]:
                errors.append(f'{module} target depends on {target}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Tool module dependencies comply.')

if __name__ == '__main__':
    main()
