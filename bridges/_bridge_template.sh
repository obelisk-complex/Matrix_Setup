#!/usr/bin/env bash
# Bridge Plugin Interface Documentation
# ======================================
# Each bridge plugin must implement the following functions:
#
#   bridge_name            -> echo human-readable name
#   bridge_description     -> echo one-line description
#   bridge_image           -> echo container image reference
#   bridge_requires_synapse -> echo "true" (all current bridges require Synapse)
#
#   bridge_prompt_credentials
#     Interactive prompts for bridge-specific credentials.
#     Store results in CONFIG[bridges.<name>.<key>].
#
#   bridge_validate_credentials
#     Validate stored credentials. Return 0 if valid, 1 if not.
#
#   bridge_generate_registration <output_file> <as_token> <hs_token> <domain>
#     Write appservice registration YAML to <output_file>.
#
#   bridge_compose_fragment
#     Echo a compose service fragment (YAML) to stdout.
#
# Plugins are discovered by scanning bridges/*.sh (skipping _prefixed files).
# The filename (without .sh) is the bridge identifier.
set -euo pipefail
