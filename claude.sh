#!/usr/bin/env bash

export CLAUDE_WORKSPACE="${PWD}"

# Run Claude in a secure rootless sandbox.
# see https://gitlab.com/sylnsr/claude-ai-sbx
~/git/rrf/claude-cli-sbx/run.sh --aggressive "$@"
