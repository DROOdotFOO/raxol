#!/usr/bin/env bash
# Fake native CLI emitting the stream-json NDJSON protocol for harness tests.
# The first argument selects a scenario.
set -u
mode="${1:-happy}"

case "$mode" in
  happy)
    printf '%s\n' '{"type":"system","subtype":"init","model":"fake"}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello "}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"world"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","result":"Hello world","usage":{"input_tokens":3,"output_tokens":2}}'
    ;;
  tool)
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"do_it","id":"t1","input":{"x":1}}]}}'
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","result":"done","usage":{}}'
    ;;
  error)
    printf '%s\n' '{"type":"result","subtype":"error_max_turns","result":"too long"}'
    ;;
  exit_nonzero)
    printf '%s\n' '{"type":"system","subtype":"init"}'
    exit 3
    ;;
  no_done)
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}'
    ;;
  *)
    printf '%s\n' '{"type":"result","subtype":"success","result":"","usage":{}}'
    ;;
esac
