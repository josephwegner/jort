#!/usr/bin/env python3
"""Create a noninteractive image only inside an explicit run-owned stage."""
import argparse
from pathlib import Path

from release import Runner, build_image
from release_manifest import ROOT, load, require

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', required=True, type=Path)
parser.add_argument('--manifest', required=True, type=Path)
parser.add_argument('--stage', required=True, type=Path)
args = parser.parse_args()
stage = args.stage.absolute()
require(stage.resolve() == stage and stage.parent == ROOT / 'dist' and stage.name.startswith('.release-'), 'expected run-owned release stage')
manifest = load(args.manifest)
require(manifest['production'], 'production manifest required')
output = stage / f'Jort-{manifest["version"]}-{manifest["build"]}-macos.dmg'
build_image(args.app, manifest, output, Runner(), stage)
print('Created unpublished candidate image: ' + str(output))
