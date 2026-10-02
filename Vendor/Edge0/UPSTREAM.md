Source: https://github.com/Edge0-AI/Edge0
Revision: feafe31beadf662b18f7c02d5e4689d2203e8072
License: Apache-2.0; see LICENSE and NOTICE.
Local changes: Conduit full-conversation prompt bridge and raw output callback;
current MLX memory API; smaller phone prefill batches; cumulative UTF-8 decoding;
omit upstream test targets whose fixtures are not vendored. Conduit tests its
checkpoint conversion and protocol bridge separately in scripts/edge0-tests.swift.
