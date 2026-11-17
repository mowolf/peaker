#!/bin/bash
# Xcode Cloud: runs right after the repository is cloned, before Xcode Cloud looks for the project.
# Peaker.xcodeproj isn't committed (it's generated from project.yml), so generate it here.
# Must live next to the project (ios/ci_scripts/) and be executable. Setup: docs/ci-setup.md.
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
