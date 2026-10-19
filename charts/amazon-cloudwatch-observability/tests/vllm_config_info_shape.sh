#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins the shape of the vLLM engine config Info metric
# (otelContainerInsights.solutions.vllm.configInfo) and of the shared agent state
# storage (otelContainerInsights.stateStorage).
#
# The agent's signal_to_info_metric connector turns the vLLM engine startup log line
# into vllm_engine_config_info. What this script guards:
#
#   1. Off by default, and inert while off: an agent image without the connector
#      fails to start on an unknown component, so the default render must not change.
#      Opt-in: with BASE_REF set (for example BASE_REF=origin/main), the renders are
#      also compared byte for byte, generated certificates redacted, with the chart
#      at that ref.
#   2. No new pipeline: the connector is a second exporter of logs/cw_k8s_ci_v0_app
#      and a second receiver of metrics/cw_k8s_ci_v0_vllm.
#   3. Logs-off mode (configInfo on, logs.enabled off): the app-log pipeline runs only
#      to feed the connector, ships nothing, and has no processors. Its receiver reads
#      the kubelet's /var/log/pods files (the same containers as /var/log/containers
#      with logs on), parses the names and the pod UID from that path in one regex, and
#      polls every 10s (or every emit interval, when that is shorter). In every mode,
#      every defined component is used and every used component is defined.
#   4. Identity: the connector keys on the namespace, pod and container that the
#      app-log receiver parses from the log file name, and also stores the k8s.pod.uid
#      of the record. Before k8sattributes, that stored UID is set aside. Right after
#      it, the Info metric is dropped when the live pod has no UID (it is gone) or a
#      UID other than the stored one (a pod replaced under the same name), then the
#      stored UID is removed. No scraped vllm:* or http_* series is ever dropped.
#   5. Storage: one file_storage extension, a writable hostPath on the node agent
#      DaemonSet only, and maxSurge 0. configInfo does not change log shipping: with
#      logs on, the app-log receiver checkpoints only with stateStorage.enabled. In
#      logs-off mode it always checkpoints.
#   6. The connector's OTTL survives the three escaping layers (Helm text, YAML,
#      OTTL strings): each pattern is unescaped as OTTL would and run against sample
#      vLLM startup lines.
#
# Assertions run on the parsed otelConfig (PyYAML), not on rendered text.
# This is a template-level test -- it renders locally and never touches a cluster.
#
# Run from anywhere:
#     bash charts/amazon-cloudwatch-observability/tests/vllm_config_info_shape.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
BASE_REF="${BASE_REF:-}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

COMMON=(--set region=us-west-2 --set clusterName=test-cluster)
OTEL=(--set otelContainerInsights.enabled=true)
INFO=(--set otelContainerInsights.solutions.vllm.configInfo.enabled=true)
LOGS_OFF=(--set otelContainerInsights.logs.enabled=false)
STORAGE_ON=(--set otelContainerInsights.stateStorage.enabled=true)
# Every new setting changed while both new flags stay off: must change nothing.
OFF_TUNED=(--set otelContainerInsights.stateStorage.hostPath=/var/lib/elsewhere
           --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=15s
           --set otelContainerInsights.solutions.vllm.configInfo.maxEntities=7
           --set otelContainerInsights.solutions.vllm.configInfo.maxStateBytes=70000
           --set otelContainerInsights.solutions.vllm.configInfo.maxValueLength=9)
MAX_SURGE_1=(--set agent.updateStrategy.rollingUpdate.maxUnavailable=0
             --set agent.updateStrategy.rollingUpdate.maxSurge=1)

# render <chart> <name> [helm args...]: writes <name>.yaml, <name>.err and <name>.rc.
render() {
    local chart="$1" name="$2"
    shift 2
    local rc=0
    "$HELM" template cw "$chart" --namespace amazon-cloudwatch "${COMMON[@]}" "$@" \
        > "${TMP_DIR}/${name}.yaml" 2> "${TMP_DIR}/${name}.err" || rc=$?
    echo "$rc" > "${TMP_DIR}/${name}.rc"
}

render "$CHART_DIR" default
render "$CHART_DIR" logs_on "${OTEL[@]}"
render "$CHART_DIR" logs_off "${OTEL[@]}" "${LOGS_OFF[@]}"
render "$CHART_DIR" logs_on_tuned "${OTEL[@]}" "${OFF_TUNED[@]}"
render "$CHART_DIR" logs_on_surge "${OTEL[@]}" "${MAX_SURGE_1[@]}"
render "$CHART_DIR" info_logs_on "${OTEL[@]}" "${INFO[@]}"
render "$CHART_DIR" info_logs_off "${OTEL[@]}" "${INFO[@]}" "${LOGS_OFF[@]}"
render "$CHART_DIR" info_storage_logs_on "${OTEL[@]}" "${INFO[@]}" "${STORAGE_ON[@]}"
render "$CHART_DIR" info_storage_logs_off "${OTEL[@]}" "${INFO[@]}" "${LOGS_OFF[@]}" "${STORAGE_ON[@]}"
render "$CHART_DIR" vllm_off "${OTEL[@]}" --set otelContainerInsights.solutions.vllm.enabled=false
render "$CHART_DIR" info_vllm_off "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.enabled=false
render "$CHART_DIR" info_otel_off "${INFO[@]}"
render "$CHART_DIR" storage_only "${OTEL[@]}" "${STORAGE_ON[@]}"
render "$CHART_DIR" storage_only_logs_off "${OTEL[@]}" "${LOGS_OFF[@]}" "${STORAGE_ON[@]}"
render "$CHART_DIR" emit_metric_resolution "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.metricResolution=20s
render "$CHART_DIR" emit_15s "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=15s
render "$CHART_DIR" emit_1h "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=1h
# The logs-off poll interval: min(10s, effective emit interval).
render "$CHART_DIR" poll_emit_5s "${OTEL[@]}" "${INFO[@]}" "${LOGS_OFF[@]}" --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=5s
render "$CHART_DIR" poll_emit_2m "${OTEL[@]}" "${INFO[@]}" "${LOGS_OFF[@]}" --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=2m
render "$CHART_DIR" poll_resolution_8s "${OTEL[@]}" "${INFO[@]}" "${LOGS_OFF[@]}" --set otelContainerInsights.metricResolution=8s
render "$CHART_DIR" poll_emit_5s_logs_on "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=5s
for bad in 15 0s 25h 1m30s abc; do
    render "$CHART_DIR" "emit_bad_${bad}" "${OTEL[@]}" "${INFO[@]}" --set "otelContainerInsights.solutions.vllm.configInfo.emitInterval=${bad}"
done
render "$CHART_DIR" bad_max_state_bytes "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.maxStateBytes=1000
render "$CHART_DIR" bad_max_value_length "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.maxValueLength=2000
render "$CHART_DIR" bad_max_entities "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.maxEntities=0
render "$CHART_DIR" bad_host_path "${OTEL[@]}" "${STORAGE_ON[@]}" --set otelContainerInsights.stateStorage.hostPath=relative/dir
render "$CHART_DIR" surge_info "${OTEL[@]}" "${INFO[@]}" "${MAX_SURGE_1[@]}"
render "$CHART_DIR" surge_info_logs_off "${OTEL[@]}" "${INFO[@]}" "${LOGS_OFF[@]}" "${MAX_SURGE_1[@]}"
render "$CHART_DIR" surge_storage "${OTEL[@]}" "${STORAGE_ON[@]}" "${MAX_SURGE_1[@]}"
render "$CHART_DIR" surge_agents_entry "${OTEL[@]}" "${INFO[@]}" \
    --set 'agents[0].name=cloudwatch-agent' \
    --set 'agents[0].updateStrategy.type=RollingUpdate' \
    --set 'agents[0].updateStrategy.rollingUpdate.maxUnavailable=0' \
    --set 'agents[0].updateStrategy.rollingUpdate.maxSurge=10%' \
    --set 'agents[1].name=cloudwatch-agent-cluster-scraper' \
    --set 'agents[1].mode=deployment' \
    --set 'agents[1].config=default'
render "$CHART_DIR" surge_on_delete "${OTEL[@]}" "${INFO[@]}" --set agent.updateStrategy.type=OnDelete

# The chart at BASE_REF, for the byte-identity check.
BASE_STATUS="skipped: set BASE_REF (for example BASE_REF=origin/main) to compare"
if [[ -n "$BASE_REF" ]]; then
    BASE_STATUS="unresolved"
    if PREFIX="$(git -C "$CHART_DIR" rev-parse --show-prefix 2>/dev/null)" &&
            TOP="$(git -C "$CHART_DIR" rev-parse --show-toplevel 2>/dev/null)" &&
            git -C "$TOP" rev-parse --verify --quiet "${BASE_REF}^{commit}" > /dev/null; then
        mkdir -p "${TMP_DIR}/base"
        # From the top level: run in a subdirectory, git archive keeps only that subdirectory.
        git -C "$TOP" archive --format=tar "${BASE_REF}:${PREFIX%/}" | tar -x -C "${TMP_DIR}/base"
        render "${TMP_DIR}/base" base_default
        render "${TMP_DIR}/base" base_logs_on "${OTEL[@]}"
        render "${TMP_DIR}/base" base_logs_off "${OTEL[@]}" "${LOGS_OFF[@]}"
        render "${TMP_DIR}/base" base_logs_on_tuned "${OTEL[@]}" "${OFF_TUNED[@]}"
        BASE_STATUS="ok"
    fi
fi

python3 - "${TMP_DIR}" "${BASE_REF}" "${BASE_STATUS}" <<'PY'
import json
import os
import re
import sys

import yaml

TMP, BASE_REF, BASE_STATUS = sys.argv[1], sys.argv[2], sys.argv[3]

AGENT = "cloudwatch-agent"
SCRAPER = "cloudwatch-agent-cluster-scraper"
CONNECTOR = "signal_to_info_metric/cw_k8s_ci_v0_vllm"
STORAGE = "file_storage/cw_k8s_ci_v0_state"
HOST_PATH = "/var/lib/amazon-cloudwatch-agent/otel-state"
APP_RECEIVER = "filelog/cw_k8s_ci_v0_app"
APP_PIPELINE = "logs/cw_k8s_ci_v0_app"
APP_EXPORTER = "otlphttp/cw_k8s_ci_v0_app_logs_dest"
VLLM_PIPELINE = "metrics/cw_k8s_ci_v0_vllm"
VLLM_RECEIVER = "prometheus/cw_k8s_ci_v0_vllm"
KEEP = "filter/cw_k8s_ci_v0_vllm_keep"
POD = "k8sattributes/cw_k8s_ci_v0_pod"
UID_SET_ASIDE = "transform/cw_k8s_ci_v0_vllm_info_uid"
LIVE = "filter/cw_k8s_ci_v0_vllm_info_live"
CLEANUP = "transform/cw_k8s_ci_v0_vllm_info_cleanup"
PREFILTER = "filter/cw_k8s_ci_v0_vllm_info_prefilter"
INFO_PROCESSORS = (UID_SET_ASIDE, LIVE, CLEANUP)
INFO_METRIC = "vllm_engine_config_info"
# The private resource attribute that holds the stored UID between the transforms.
STORED_UID = "cwagent.info.pod.uid"
# The connector matches the startup line by plain substrings, no regex.
BODY_CONTAINS = ["Initializing an LLM engine (v", "Initializing a V0 LLM engine (v",
                 "Initializing a V1 LLM engine (v"]
# The connector's identity: what the app-log receiver parses from the log file name.
IDENTITY = ["k8s.namespace.name", "k8s.pod.name", "k8s.container.name"]
# Copied to the emitted resource: the identity and the UID of the pod that logged the line.
INCLUDED = IDENTITY + ["k8s.pod.uid"]
# Logs-off mode: the receiver reads /var/log/pods/<namespace>_<pod>_<uid>/<container>/<n>.log.
PODS_INCLUDE = ["/var/log/pods/*/*/*.log"]
PODS_EXCLUDE = [f"/var/log/pods/*_{p}*/*/*.log" for p in ("cloudwatch-agent", "fluent-bit", "aws-node", "kube-proxy")]
PODS_REGEX = (r"^/var/log/pods/(?P<namespace>[^_/]+)_(?P<pod>[^_/]+)_(?:(?P<uid>[0-9a-f]{8}-[0-9a-f]{4}"
              r"-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})|[^/]+)/(?P<container>[^/]+)/[0-9]+\.log$")
PODS_PARSER = {"type": "regex_parser", "id": "extract_metadata_from_filepath", "regex": PODS_REGEX,
               "parse_from": 'attributes["log.file.path"]', "parse_to": "resource"}
UID_MOVE = {"type": "move", "from": "resource.uid", "to": 'resource["k8s.pod.uid"]', "on_error": "send_quiet"}
# Every mode the checks below look at, for the component cross-checks.
MODES = ("default", "logs_on", "logs_off", "logs_on_tuned", "info_logs_on", "info_logs_off",
         "info_storage_logs_on", "info_storage_logs_off", "storage_only", "storage_only_logs_off",
         "vllm_off", "info_vllm_off", "info_otel_off", "emit_metric_resolution", "emit_15s",
         "emit_1h", "poll_emit_5s", "poll_emit_2m", "poll_resolution_8s", "poll_emit_5s_logs_on",
         "surge_on_delete")

GREEN, RED, YELLOW, RESET = "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0m"
passed = failed = 0


def check(desc, ok):
    global passed, failed
    if ok:
        print(f"  {GREEN}PASS{RESET}: {desc}")
        passed += 1
    else:
        print(f"  {RED}FAIL{RESET}: {desc}")
        failed += 1
    return ok


def path(name):
    return os.path.join(TMP, name)


def rc(name):
    with open(path(name + ".rc")) as f:
        return int(f.read().strip())


def err(name):
    with open(path(name + ".err")) as f:
        return f.read()


def docs(name):
    with open(path(name + ".yaml")) as f:
        return [d for d in yaml.safe_load_all(f) if d]


def agent_crs(name):
    return {d["metadata"]["name"]: d for d in docs(name) if d.get("kind") == "AmazonCloudWatchAgent"}


def otel_config(name, agent=AGENT):
    cr = agent_crs(name).get(agent)
    return (yaml.safe_load(cr["spec"].get("otelConfig") or "{}") or {}) if cr else {}


def pipelines(cfg):
    return (cfg.get("service") or {}).get("pipelines") or {}


def pipeline(cfg, name):
    return pipelines(cfg).get(name) or {}


def section(cfg, kind):
    return cfg.get(kind) or {}


def redacted(name):
    """Rendered text with the randomly generated certificate material blanked."""
    with open(path(name + ".yaml")) as f:
        return re.sub(r"(?m)^(\s*(?:caBundle|ca\.crt|tls\.crt|tls\.key):).*$", r"\1 <redacted>", f.read())


def mounts(cr, name):
    return [m for m in cr["spec"].get("volumeMounts") or [] if m.get("name") == name]


def volumes(cr, name):
    return [v for v in cr["spec"].get("volumes") or [] if v.get("name") == name]


def undefined_components(cfg):
    """Components named in service but not defined in their section."""
    missing = []
    service = cfg.get("service") or {}
    for ext in service.get("extensions") or []:
        if ext not in section(cfg, "extensions"):
            missing.append(ext)
    for p in pipelines(cfg).values():
        for r in p.get("receivers") or []:
            if r not in section(cfg, "receivers") and r not in section(cfg, "connectors"):
                missing.append(r)
        for x in p.get("processors") or []:
            if x not in section(cfg, "processors"):
                missing.append(x)
        for e in p.get("exporters") or []:
            if e not in section(cfg, "exporters") and e not in section(cfg, "connectors"):
                missing.append(e)
    return missing


def unused_components(cfg):
    """Components defined but used by no pipeline (extensions: not in service.extensions;
    connectors: not used both as an exporter and as a receiver)."""
    used = {k: set() for k in ("receivers", "processors", "exporters")}
    for p in pipelines(cfg).values():
        for k in used:
            used[k] |= set(p.get(k) or [])
    unused = [c for k in used for c in section(cfg, k) if c not in used[k]]
    unused += [c for c in section(cfg, "connectors")
               if c not in used["exporters"] or c not in used["receivers"]]
    started = set((cfg.get("service") or {}).get("extensions") or [])
    return unused + [e for e in section(cfg, "extensions") if e not in started]


def file_name_attributes(cfg, file_path):
    """The resource attributes APP_RECEIVER sets from file_path: its regex_parser on
    log.file.path into the resource, then a move of each capture group to a resource key."""
    rec = section(cfg, "receivers").get(APP_RECEIVER) or {}
    ops = rec.get("operators") or []
    parsers = [o for o in ops if o.get("type") == "regex_parser" and
               o.get("parse_from") == 'attributes["log.file.path"]' and o.get("parse_to") == "resource"]
    if rec.get("include_file_path") is not True or len(parsers) != 1:
        return {}
    m = re.match(parsers[0].get("regex") or "", file_path)
    if not m:
        return {}
    out = {}
    for o in ops:
        if o.get("type") != "move":
            continue
        src = re.fullmatch(r"resource\.(\w+)", o.get("from") or "")
        dst = re.fullmatch(r'resource\["([^"]+)"\]', o.get("to") or "")
        if src and dst and src.group(1) in m.groupdict():
            # Go gives "" for a group that took no part in the match, Python gives None.
            out[dst.group(1)] = m.group(src.group(1)) or ""
    return out


def glob_match(pattern, path):
    """doublestar.PathMatch, as the file matcher applies include and exclude, for the globs
    used here: * matches any run of characters other than /."""
    return re.fullmatch("".join("[^/]*" if c == "*" else re.escape(c) for c in pattern), path) is not None


def selects(receiver, path):
    """True if the receiver's include and exclude globs select path."""
    return (any(glob_match(g, path) for g in receiver.get("include") or []) and
            not any(glob_match(g, path) for g in receiver.get("exclude") or []))


def mentions(cfg, component):
    """True if component is defined anywhere or used by any pipeline or service list."""
    if any(component in section(cfg, k) for k in ("receivers", "processors", "exporters", "connectors", "extensions")):
        return True
    if component in ((cfg.get("service") or {}).get("extensions") or []):
        return True
    return any(component in (p.get(k) or []) for p in pipelines(cfg).values()
               for k in ("receivers", "processors", "exporters"))


def connector_users(cfg):
    as_exporter = [n for n, p in pipelines(cfg).items() if CONNECTOR in (p.get("exporters") or [])]
    as_receiver = [n for n, p in pipelines(cfg).items() if CONNECTOR in (p.get("receivers") or [])]
    return as_exporter, as_receiver


# --- OTTL, as far as the connector rule uses it ------------------------------------
OTTL_STRING = r'"((?:[^"\\]|\\.)*)"'
EXTRACT = re.compile(r'ExtractPatterns\(log\.body, ' + OTTL_STRING + r'\)\["v"\]')
SHAPE = re.compile(r'^ExtractPatterns\(log\.body, ' + OTTL_STRING + r'\)\["v"\]$')


def ottl_unescape(s):
    """An OTTL string literal's value. Only \\\\ and \\" may appear: any other escape means
    a regex backslash was not doubled."""
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\":
            if i + 1 >= len(s) or s[i + 1] not in '\\"':
                raise ValueError(f"undoubled backslash at {i} in {s!r}")
            out.append(s[i + 1])
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def evaluate(attr, body):
    """An attribute's value for a log body, as the connector computes it: ExtractPatterns(log.body,
    "<re>")["v"]; no match (an evaluation error) gives default_value, or None."""
    m = SHAPE.match(attr.get("value") or "")
    if not m:
        raise ValueError(f"unexpected expression shape: {attr.get('value')}")
    hit = re.search(ottl_unescape(m.group(1)), body)
    if hit and hit.groupdict().get("v"):
        return hit.group("v")
    return attr.get("default_value")


# Sample engine startup lines: V1 (vLLM >= 0.10), V0 (0.8.x), and the line before the
# V0/V1 split (0.6.x), plus a speculative-decoding config.
V1_LINE = (
    "(EngineCore pid=211) INFO 10-15 12:41:46 [core.py:134] Initializing a V1 LLM engine "
    "(v0.31.1) with config: model='meta-llama/Llama-3.1-70B-Instruct', speculative_config=None, "
    "tokenizer='meta-llama/Llama-3.1-70B-Instruct', skip_tokenizer_init=False, tokenizer_mode=auto, "
    "revision=None, tokenizer_revision=None, trust_remote_code=False, dtype=torch.bfloat16, "
    "max_seq_len=131072, download_dir=None, load_format=auto, tensor_parallel_size=4, "
    "pipeline_parallel_size=2, data_parallel_size=1, decode_context_parallel_size=1, "
    "disable_custom_all_reduce=False, quantization=fp8, "
    "quantization_config={'activation_scheme': 'dynamic', 'quant_method': 'fp8'}, enforce_eager=False, "
    "kv_cache_dtype=fp8_e4m3, device_config=cuda, seed=0, "
    "served_model_name=llama-70b, enable_prefix_caching=True, enable_chunked_prefill=True, "
    "pooler_config=None, compilation_config={'mode': 3}, kernel_config=KernelConfig()"
)
V0_LINE = (
    "INFO 05-02 09:10:11 [llm_engine.py:241] Initializing a V0 LLM engine (v0.8.5) with config: "
    "model='Qwen/Qwen2.5-7B-Instruct', speculative_config=SpeculativeConfig(method='eagle', "
    "model='yuhuili/EAGLE-Qwen2-7B-Instruct', num_spec_tokens=3), tokenizer='Qwen/Qwen2.5-7B-Instruct', "
    "dtype=torch.float16, max_seq_len=32768, tensor_parallel_size=1, pipeline_parallel_size=1, "
    "quantization=awq, enforce_eager=True, kv_cache_dtype=auto, served_model_name=qwen-7b, "
    "enable_prefix_caching=False, use_async_output_proc=False, "
)
LEGACY_LINE = (
    "INFO 10-01 08:00:00 llm_engine.py:237] Initializing an LLM engine (v0.6.3) with config: "
    "model='mistralai/Mistral-7B-Instruct-v0.3', speculative_config=None, "
    "tokenizer='mistralai/Mistral-7B-Instruct-v0.3', dtype=torch.bfloat16, max_seq_len=32768, "
    "tensor_parallel_size=2, pipeline_parallel_size=1, quantization=None, enforce_eager=False, "
    "kv_cache_dtype=auto, served_model_name=mistralai/Mistral-7B-Instruct-v0.3, "
    "enable_prefix_caching=None, "
)
UNRELATED_LINE = "INFO 10-15 12:41:50 [api_server.py:1] Starting vLLM API server on http://0.0.0.0:8000"
EXPECTED = {
    "V1": (V1_LINE, {
        "vllm_version": "0.31.1", "model": "meta-llama/Llama-3.1-70B-Instruct", "vllm_engine": "V1",
        "served_model_name": "llama-70b", "dtype": "bfloat16", "max_seq_len": "131072",
        "tensor_parallel_size": "4", "pipeline_parallel_size": "2", "data_parallel_size": "1",
        "quantization": "fp8", "enforce_eager": "False", "kv_cache_dtype": "fp8_e4m3",
        "enable_prefix_caching": "True", "speculative_method": "None"}),
    "V0": (V0_LINE, {
        "vllm_version": "0.8.5", "model": "Qwen/Qwen2.5-7B-Instruct", "vllm_engine": "V0",
        "served_model_name": "qwen-7b", "dtype": "float16", "max_seq_len": "32768",
        "tensor_parallel_size": "1", "pipeline_parallel_size": "1", "data_parallel_size": None,
        "quantization": "awq", "enforce_eager": "True", "kv_cache_dtype": "auto",
        "enable_prefix_caching": "False", "speculative_method": "eagle"}),
    "pre-V0/V1": (LEGACY_LINE, {
        "vllm_version": "0.6.3", "model": "mistralai/Mistral-7B-Instruct-v0.3", "vllm_engine": "V0",
        "served_model_name": "mistralai/Mistral-7B-Instruct-v0.3", "dtype": "bfloat16",
        "max_seq_len": "32768", "tensor_parallel_size": "2", "pipeline_parallel_size": "1",
        "data_parallel_size": None, "quantization": "None", "enforce_eager": "False",
        "kv_cache_dtype": "auto", "enable_prefix_caching": "None", "speculative_method": "None"}),
}
REQUIRED = ["vllm_version", "model"]
DEFAULTED = {"vllm_engine": "V0"}
OPTIONAL = ["served_model_name", "dtype", "max_seq_len", "tensor_parallel_size",
            "pipeline_parallel_size", "data_parallel_size", "quantization", "enforce_eager",
            "kv_cache_dtype", "enable_prefix_caching", "speculative_method"]


# Guards: without these, the assertions below could pass on empty input.
print(f"\n{YELLOW}[renders]{RESET}")
for name in MODES + ("logs_on_surge", "vllm_off"):
    if not check(f"{name} renders", rc(name) == 0):
        print("    " + err(name).strip().replace("\n", "\n    "))
check("the node agent CR renders an otelConfig with configInfo on", bool(otel_config("info_logs_on")))
check(f"{VLLM_PIPELINE} renders with configInfo on", bool(pipeline(otel_config("info_logs_on"), VLLM_PIPELINE)))

# --- 1. Off by default, and inert while off ---------------------------------------
print(f"\n{YELLOW}[defaults: everything off]{RESET}")
if BASE_STATUS == "ok":
    for new, base in (("default", "base_default"), ("logs_on", "base_logs_on"),
                      ("logs_off", "base_logs_off"), ("logs_on_tuned", "base_logs_on_tuned")):
        check(f"{new} is byte-identical to {BASE_REF} (certificates redacted)",
              rc(base) == 0 and redacted(new) == redacted(base))
elif BASE_REF:
    check(f"BASE_REF {BASE_REF} resolves in this checkout", False)
else:
    print(f"  {YELLOW}SKIP{RESET}: byte identity with a base ref ({BASE_STATUS})")
check("changing only the new settings, with both flags off, changes nothing",
      redacted("logs_on_tuned") == redacted("logs_on"))
check("maxSurge 1 renders while the storage is off", rc("logs_on_surge") == 0)
for name in ("default", "logs_on", "logs_off", "info_vllm_off", "info_otel_off"):
    everything = [otel_config(name, a) for a in agent_crs(name)]
    check(f"{name}: no connector, storage extension or Info metric processors",
          not any(mentions(c, x) for c in everything for x in (CONNECTOR, STORAGE, PREFILTER) + INFO_PROCESSORS))
    check(f"{name}: no state volume on any agent",
          not any(volumes(cr, "otelstate") or mounts(cr, "otelstate") for cr in agent_crs(name).values()))
check("configInfo without the vLLM solution renders as if it were off",
      redacted("info_vllm_off") == redacted("vllm_off"))
check("configInfo without OTEL Container Insights renders as the defaults",
      redacted("info_otel_off") == redacted("default"))

# --- 2. configInfo on + logs on ----------------------------------------------------
print(f"\n{YELLOW}[configInfo on, logs on]{RESET}")
on = otel_config("info_logs_on")
off = otel_config("logs_on")
check("no new pipeline: same service.pipelines keys as the logs-on render",
      set(pipelines(on)) == set(pipelines(off)))
as_exporter, as_receiver = connector_users(on)
check(f"the connector is an exporter of {APP_PIPELINE} only", as_exporter == [APP_PIPELINE])
check(f"the connector is a receiver of {VLLM_PIPELINE} only", as_receiver == [VLLM_PIPELINE])
check(f"{APP_PIPELINE} still ships logs, then feeds the connector",
      pipeline(on, APP_PIPELINE).get("exporters") == [APP_EXPORTER, CONNECTOR])
check(f"{VLLM_PIPELINE} keeps its scrape receiver first",
      pipeline(on, VLLM_PIPELINE).get("receivers") == [VLLM_RECEIVER, CONNECTOR])
check(f"{APP_PIPELINE} processors are unchanged",
      pipeline(on, APP_PIPELINE).get("processors") == pipeline(off, APP_PIPELINE).get("processors"))
check(f"{APP_PIPELINE} runs {POD} before the connector, which adds the k8s.pod.uid the connector stores",
      POD in (pipeline(on, APP_PIPELINE).get("processors") or []))
check(f"no {PREFILTER}", not mentions(on, PREFILTER))

connector = section(on, "connectors").get(CONNECTOR) or {}
rules = connector.get("rules") or [{}]
rule = rules[0]
check("the connector keeps its state in the storage extension", connector.get("storage") == STORAGE)
check("emit_interval defaults to metricResolution (30s)", connector.get("emit_interval") == "30s")
check("max_state_bytes and max_value_length come from values",
      connector.get("max_state_bytes") == 1048576 and connector.get("max_value_length") == 256)
check(f"one rule, {INFO_METRIC}, with max_entities 500",
      len(rules) == 1 and rule.get("name") == INFO_METRIC and rule.get("max_entities") == 500)
check(f"the rule is keyed on {IDENTITY} and copies those three and k8s.pod.uid to the resource",
      rule.get("identity") == IDENTITY and rule.get("include_resource_attributes") == INCLUDED)
check("no identity_output_prefix (the identity keys are plain resource attributes)",
      "identity_output_prefix" not in connector)
check("the startup line is matched by the three body_contains substrings, with no OTTL condition",
      rule.get("body_contains") == BODY_CONTAINS and "conditions" not in rule)
attrs = rule.get("attributes") or []
by_key = {a.get("key"): a for a in attrs}
check("the 14 facts, required first", [a.get("key") for a in attrs] == REQUIRED + list(DEFAULTED) + OPTIONAL)
check("vllm_version and model are required (no optional, no default_value)",
      all(not by_key[k].get("optional") and "default_value" not in by_key[k] for k in REQUIRED))
check("vllm_engine defaults to V0 and is not also optional (the connector rejects both)",
      all(by_key[k].get("default_value") == v and "optional" not in by_key[k] for k, v in DEFAULTED.items()))
check("every other fact is optional, with no default_value",
      all(by_key[k].get("optional") is True and "default_value" not in by_key[k] for k in OPTIONAL))

# 6. Escaping: run every pattern the way the collector would see it.
all_ottl = [a.get("value") or "" for a in attrs]
check("no OTTL string contains a $ (the collector's confmap would expand it)",
      all("$" not in s for s in all_ottl))
try:
    for s in all_ottl:
        for lit in re.findall(OTTL_STRING, s):
            re.compile(ottl_unescape(lit))
    escaping_ok = True
except (ValueError, re.error) as e:
    print(f"    {e}")
    escaping_ok = False
check("every regex backslash is doubled for OTTL and every string compiles as a regex", escaping_ok)
check('every attribute value is one ExtractPatterns(log.body, "...")["v"] (no Coalesce)',
      all(SHAPE.match(a.get("value") or "") for a in attrs))
for label, (line, expected) in EXPECTED.items():
    try:
        got = {a["key"]: evaluate(a, line) for a in attrs}
    except (ValueError, re.error) as e:
        print(f"    {e}")
        got = {}
    check(f"{label} startup line: contains exactly one body_contains substring",
          sum(b in line for b in BODY_CONTAINS) == 1)
    if not check(f"{label} startup line: all 14 facts extract as expected", got == expected):
        for k in expected:
            if got.get(k) != expected[k]:
                print(f"    {k}: got {got.get(k)!r}, want {expected[k]!r}")
check("an unrelated vLLM log line contains no body_contains substring",
      not any(b in UNRELATED_LINE for b in BODY_CONTAINS))

# Storage.
storage = section(on, "extensions").get(STORAGE) or {}
compaction = storage.get("compaction") or {}
check(f"{STORAGE} is in service.extensions", STORAGE in ((on.get("service") or {}).get("extensions") or []))
check(f"{STORAGE} writes to {HOST_PATH} and creates it",
      storage.get("directory") == HOST_PATH and storage.get("create_directory") is True)
check(f"{STORAGE} compacts on start and on rebound, in the same directory",
      compaction.get("on_start") is True and compaction.get("on_rebound") is True and
      compaction.get("directory") == HOST_PATH)
check(f"{STORAGE} recreates a file it cannot open", storage.get("recreate") is True)
check(f"configInfo does not change log shipping: {APP_RECEIVER} (no checkpoints, start_at end) "
      f"and {APP_EXPORTER} are as in the logs-on render",
      section(on, "receivers").get(APP_RECEIVER) == section(off, "receivers").get(APP_RECEIVER) and
      "storage" not in (section(on, "receivers").get(APP_RECEIVER) or {"storage": 1}) and
      section(on, "exporters").get(APP_EXPORTER) == section(off, "exporters").get(APP_EXPORTER))
on_receiver = section(on, "receivers").get(APP_RECEIVER) or {}
check(f"logs on: {APP_RECEIVER} reads /var/log/containers, with no poll_interval and no k8s.pod.uid move",
      on_receiver.get("include") == ["/var/log/containers/*.log"] and "poll_interval" not in on_receiver and
      "include_file_path_resolved" not in on_receiver and
      not any(o.get("from") == "resource.uid" for o in on_receiver.get("operators") or []))

# 4. Identity and liveness.
SAMPLE_UID = "5f2c8a1e-3b4d-4e6f-9a0b-1c2d3e4f5a6b"
SAMPLE_PATHS = {"info_logs_on": "/var/log/containers/vllm-0_ml-serving_vllm-server-" + "0123456789abcdef" * 4 + ".log",
                "info_logs_off": f"/var/log/pods/ml-serving_vllm-0_{SAMPLE_UID}/vllm-server/0.log"}
SAMPLE_IDENTITY = {"k8s.pod.name": "vllm-0", "k8s.namespace.name": "ml-serving",
                   "k8s.container.name": "vllm-server"}
for name, sample_path in SAMPLE_PATHS.items():
    got = file_name_attributes(otel_config(name), sample_path)
    if not check(f"{name}: {APP_RECEIVER} sets every identity key from the log file name",
                 {k: got.get(k) for k in IDENTITY} == SAMPLE_IDENTITY):
        print(f"    got {got}")
chain = pipeline(on, VLLM_PIPELINE).get("processors") or []
pod_at = chain.index(POD) if POD in chain else -1
check(f"{UID_SET_ASIDE} runs right before {POD}, and {LIVE} then {CLEANUP} right after it",
      pod_at >= 1 and chain[pod_at - 1:pod_at + 3] == [UID_SET_ASIDE, POD, LIVE, CLEANUP])
check(f"{UID_SET_ASIDE} runs after {KEEP}", KEEP in chain and chain.index(KEEP) < pod_at - 1)
check(f"apart from {', '.join(INFO_PROCESSORS)}, {VLLM_PIPELINE} processors are unchanged",
      [p for p in chain if p not in INFO_PROCESSORS] == pipeline(off, VLLM_PIPELINE).get("processors"))
before_uid = chain[:max(pod_at - 1, 0)]
check(f"no processor before {UID_SET_ASIDE} names k8s.pod.uid, so none sets or changes it on the Info metric",
      bool(before_uid) and all(p in section(on, "processors") for p in before_uid) and
      not any("k8s.pod.uid" in json.dumps(section(on, "processors").get(p)) for p in before_uid))
uid_proc = section(on, "processors").get(UID_SET_ASIDE) or {}
check(f"{UID_SET_ASIDE} copies k8s.pod.uid to {STORED_UID} and deletes it, for {INFO_METRIC} only",
      uid_proc == {"error_mode": "ignore", "metric_statements": [{"context": "metric", "statements": [
          f'set(resource.attributes["{STORED_UID}"], resource.attributes["k8s.pod.uid"]) '
          f'where metric.name == "{INFO_METRIC}" and resource.attributes["k8s.pod.uid"] != nil',
          f'delete_key(resource.attributes, "k8s.pod.uid") where metric.name == "{INFO_METRIC}"']}]})
cleanup = section(on, "processors").get(CLEANUP) or {}
check(f"{CLEANUP} deletes {STORED_UID}, for {INFO_METRIC} only",
      cleanup == {"error_mode": "ignore", "metric_statements": [{"context": "metric", "statements": [
          f'delete_key(resource.attributes, "{STORED_UID}") where metric.name == "{INFO_METRIC}"']}]})
pod_proc = section(on, "processors").get(POD) or {}
associations = [[(s.get("from"), s.get("name")) for s in a.get("sources") or []]
                for a in pod_proc.get("pod_association") or []]
check(f"{POD} adds k8s.pod.uid, looked up by the k8s.pod.name and k8s.namespace.name that the "
      "Info metric carries (so the PromQL join on @resource.k8s.pod.uid holds)",
      "k8s.pod.uid" in ((pod_proc.get("extract") or {}).get("metadata") or []) and
      [("resource_attribute", "k8s.pod.name"), ("resource_attribute", "k8s.namespace.name")] in associations and
      {"k8s.pod.name", "k8s.namespace.name"} <= set(rule.get("include_resource_attributes") or []))
live = section(on, "processors").get(LIVE) or {}
live_conditions = ((live.get("metrics") or {}).get("datapoint")) or []
check(f"{LIVE} drops a {INFO_METRIC} data point with no live k8s.pod.uid, or with a stored "
      f"{STORED_UID} that is not the live k8s.pod.uid",
      live.get("error_mode") == "ignore" and set(live) == {"error_mode", "metrics"} and
      set(live.get("metrics") or {}) == {"datapoint"} and live_conditions == [
          f'metric.name == "{INFO_METRIC}" and resource.attributes["k8s.pod.uid"] == nil',
          f'metric.name == "{INFO_METRIC}" and resource.attributes["{STORED_UID}"] != nil and '
          f'resource.attributes["{STORED_UID}"] != resource.attributes["k8s.pod.uid"]'])
check(f"{LIVE} never drops a scraped series: each condition is an 'and' that names {INFO_METRIC}, "
      "which is not a vllm:* or http_* name",
      bool(live_conditions) and not re.match(r"^(vllm:|http_)", INFO_METRIC) and
      all(" or " not in c and f'metric.name == "{INFO_METRIC}"' in c.split(" and ") for c in live_conditions))
info_ottl = (live_conditions + [s for p in (uid_proc, cleanup) for g in p.get("metric_statements") or []
                                for s in g.get("statements") or []])
check("no OTTL of the Info metric processors contains a $ (the collector's confmap would expand it)",
      len(info_ottl) == 5 and all("$" not in s for s in info_ottl))

keep_on = ((section(on, "processors").get(KEEP) or {}).get("metrics") or {}).get("metric") or []
keep_off = ((section(off, "processors").get(KEEP) or {}).get("metrics") or {}).get("metric") or []
check(f"{KEEP} also passes {INFO_METRIC}, and otherwise drops what it drops today",
      bool(keep_off) and len(keep_on) == len(keep_off) and keep_on[1:] == keep_off[1:] and
      keep_on[0] == f'{keep_off[0]} and name != "{INFO_METRIC}"')

# 5. The state volume: writable, node agent DaemonSet only.
crs = agent_crs("info_logs_on")
node_cr = crs.get(AGENT) or {"spec": {}}
state_mounts, state_volumes = mounts(node_cr, "otelstate"), volumes(node_cr, "otelstate")
check(f"the {AGENT} DaemonSet mounts {HOST_PATH} writable",
      node_cr["spec"].get("mode") == "daemonset" and len(state_mounts) == 1 and
      state_mounts[0].get("mountPath") == HOST_PATH and not state_mounts[0].get("readOnly"))
check(f"the {AGENT} DaemonSet has a DirectoryOrCreate hostPath volume at {HOST_PATH}",
      len(state_volumes) == 1 and
      state_volumes[0].get("hostPath") == {"path": HOST_PATH, "type": "DirectoryOrCreate"})
check("no other agent CR (cluster-scraper, Windows) gets the state volume",
      len(crs) >= 3 and not any(mounts(cr, "otelstate") or volumes(cr, "otelstate")
                                for name, cr in crs.items() if name != AGENT))
check("the cluster-scraper has no connector or storage",
      not mentions(otel_config("info_logs_on", SCRAPER), CONNECTOR) and
      not mentions(otel_config("info_logs_on", SCRAPER), STORAGE))

# --- 3. configInfo on + logs off ---------------------------------------------------
print(f"\n{YELLOW}[configInfo on, logs off]{RESET}")
lo = otel_config("info_logs_off")
lo_base = otel_config("logs_off")
check(f"the only pipeline added to the logs-off render is {APP_PIPELINE}",
      set(pipelines(lo)) == set(pipelines(lo_base)) | {APP_PIPELINE} and APP_PIPELINE not in pipelines(lo_base))
check(f"{APP_PIPELINE} is {APP_RECEIVER} straight to the connector, with no processors",
      pipeline(lo, APP_PIPELINE) == {"receivers": [APP_RECEIVER], "exporters": [CONNECTOR]})
check(f"no {PREFILTER} defined", not mentions(lo, PREFILTER))
check("the log-shipping processors are not defined",
      not any(x.startswith(("transform/cw_k8s_ci_v0_logs_", "batch/cw_k8s_ci_v0_logs_"))
              for x in section(lo, "processors")))
check(f"{VLLM_PIPELINE} and {', '.join(INFO_PROCESSORS)} are as with logs on",
      pipeline(lo, VLLM_PIPELINE) == pipeline(on, VLLM_PIPELINE) and
      all(x in section(lo, "processors") and section(lo, "processors").get(x) == section(on, "processors").get(x)
          for x in INFO_PROCESSORS))
check("the connector is the same as with logs on", section(lo, "connectors") == section(on, "connectors"))
lo_receiver = section(lo, "receivers").get(APP_RECEIVER) or {}
check(f"{APP_RECEIVER} starts at the beginning (nothing is shipped)", lo_receiver.get("start_at") == "beginning")
check(f"{APP_RECEIVER} polls every 10s (emitInterval 30s, the default)", lo_receiver.get("poll_interval") == "10s")
check(f"{APP_RECEIVER} reads /var/log/pods with the logs-on excludes in that layout, and no "
      "include_file_path_resolved",
      lo_receiver.get("include") == PODS_INCLUDE and lo_receiver.get("exclude") == PODS_EXCLUDE and
      "include_file_path_resolved" not in lo_receiver and
      all(lo_receiver.get(k) == on_receiver.get(k) for k in
          ("include_file_path", "include_file_name", "max_concurrent_files")))
on_ops, lo_ops = on_receiver.get("operators") or [], lo_receiver.get("operators") or []
check(f"{APP_RECEIVER} operators: one /var/log/pods regex_parser, the three logs-on moves, the uid move, "
      "then container_log_parser, with no if guard",
      len(on_ops) == 5 and on_ops[-1].get("type") == "container_log_parser" and
      lo_ops == [PODS_PARSER] + on_ops[1:4] + [UID_MOVE] + on_ops[4:] and not any("if" in o for o in lo_ops))
# The same containers in both layouts: (namespace, pod, container) -> selected by the excludes?
CONTAINER_ID = "0123456789abcdef" * 4
SAMPLE_PODS = (
    ("amazon-cloudwatch", "cloudwatch-agent-x7k2p", "otc-container", False),
    ("amazon-cloudwatch", "cloudwatch-agent-cluster-scraper-5d9f-abcde", "otc-container", False),
    ("amazon-cloudwatch", "fluent-bit-9qz8w", "fluent-bit", False),
    ("kube-system", "aws-node-4xk2l", "aws-node", False),
    ("kube-system", "aws-node-4xk2l", "aws-eks-nodeagent", False),
    ("kube-system", "kube-proxy-p8s7d", "kube-proxy", False),
    ("ml-serving", "vllm-0", "vllm-server", True),
    ("cloudwatch-agent-test", "foo", "app", True),
    ("ml-serving", "my-cloudwatch-agent-1", "app", True),
    ("ml-serving", "app-0", "cloudwatch-agent", True),
    ("amazon-cloudwatch", "amazon-cloudwatch-observability-controller-manager-1", "manager", True))
for ns, pod, container, want in SAMPLE_PODS:
    pods_path = f"/var/log/pods/{ns}_{pod}_{SAMPLE_UID}/{container}/0.log"
    containers_path = f"/var/log/containers/{pod}_{ns}_{container}-{CONTAINER_ID}.log"
    check(f"{ns}/{pod}/{container}: {'read' if want else 'excluded'} in both layouts",
          selects(lo_receiver, pods_path) == want and selects(on_receiver, containers_path) == want)
check("rotated and compressed files are not read",
      not selects(lo_receiver, f"/var/log/pods/ml-serving_vllm-0_{SAMPLE_UID}/vllm-server/0.log.20261019-120000") and
      not selects(lo_receiver, f"/var/log/pods/ml-serving_vllm-0_{SAMPLE_UID}/vllm-server/0.log.20261018-1.gz"))
for desc, pods_path, want in (
        ("kubelet pod log", f"/var/log/pods/ml-serving_vllm-0_{SAMPLE_UID}/vllm-server/0.log",
         {"k8s.namespace.name": "ml-serving", "k8s.pod.name": "vllm-0", "k8s.container.name": "vllm-server",
          "k8s.pod.uid": SAMPLE_UID}),
        ("kubelet pod log after 12 container restarts",
         f"/var/log/pods/ml-serving_vllm-0_{SAMPLE_UID}/vllm-server/12.log",
         {"k8s.namespace.name": "ml-serving", "k8s.pod.name": "vllm-0", "k8s.container.name": "vllm-server",
          "k8s.pod.uid": SAMPLE_UID}),
        ("static pod, kubelet config hash: names, empty UID (no UID check)",
         "/var/log/pods/kube-system_vllm-static-node1_0123456789abcdef0123456789abcdef/vllm/0.log",
         {"k8s.namespace.name": "kube-system", "k8s.pod.name": "vllm-static-node1", "k8s.container.name": "vllm",
          "k8s.pod.uid": ""}),
        ("rotated file name: no match, as today's regex on a non-matching name",
         f"/var/log/pods/ml-serving_vllm-0_{SAMPLE_UID}/vllm-server/0.log.20261019-120000", {}),
        ("a /var/log/containers name: no match", SAMPLE_PATHS["info_logs_on"], {})):
    got = file_name_attributes(lo, pods_path)
    if not check(f"pods path, {desc}", got == want):
        print(f"    got {got!r}")
check("the pods regex has no $ other than its end anchor (the collector's confmap expands ${...})",
      PODS_REGEX.count("$") == 1 and PODS_REGEX.endswith("$"))
check(f"no {APP_EXPORTER}, host-log pipeline, or logs auth extensions",
      APP_EXPORTER not in section(lo, "exporters") and "logs/cw_k8s_ci_v0_node" not in pipelines(lo) and
      "filelog/cw_k8s_ci_v0_node" not in section(lo, "receivers") and
      not any(e in section(lo, "extensions") for e in
              ("sigv4auth/cw_k8s_ci_v0_logs_dest", "awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs")))
check("no exporter other than the metrics destination", list(section(lo, "exporters")) == ["otlphttp/cw_k8s_ci_v0_metrics_dest"])
lo_crs = agent_crs("info_logs_off")
lo_node = lo_crs.get(AGENT) or {"spec": {}}
var_log_paths = sorted(set(re.findall(r"/var/log[^\s'\"]*", json.dumps(lo))))
check("every path under /var/log in the otelConfig is under /var/log/pods",
      bool(var_log_paths) and all(p == "/var/log/pods" or p.startswith("/var/log/pods/") for p in var_log_paths))
check("/var/log/pods is mounted read-only on the node agent",
      [(m.get("mountPath"), m.get("readOnly")) for m in mounts(lo_node, "criologs")] == [("/var/log/pods", True)] and
      volumes(lo_node, "criologs") == [{"hostPath": {"path": "/var/log/pods"}, "name": "criologs"}])
check("/var/log is not mounted on any agent (only /var/log/pods is read)",
      not any(mounts(cr, "varlog") or volumes(cr, "varlog") for cr in lo_crs.values()))
check("the state volume is mounted on the node agent", len(mounts(lo_node, "otelstate")) == 1)


def without_state(spec):
    """The CR spec without the otelConfig and the otelstate volume and mount."""
    out = {k: v for k, v in spec.items() if k != "otelConfig"}
    for k in ("volumes", "volumeMounts"):
        out[k] = [x for x in spec.get(k) or [] if x.get("name") != "otelstate"]
    return out


lo_base_node = agent_crs("logs_off").get(AGENT) or {"spec": {}}
check("the node agent CR differs from the logs-off render with both flags off (byte-identical to "
      "origin/main) only by the otelConfig and the otelstate volume and mount",
      without_state(lo_node["spec"]) == without_state(lo_base_node["spec"]) and
      lo_node["spec"].get("otelConfig") != lo_base_node["spec"].get("otelConfig") and
      len(volumes(lo_node, "otelstate")) == 1 and not volumes(lo_base_node, "otelstate"))
check("the other agent CRs are as in the logs-off render with both flags off",
      {n: cr for n, cr in lo_crs.items() if n != AGENT} ==
      {n: cr for n, cr in agent_crs("logs_off").items() if n != AGENT})
check(f"{STORAGE} is in service.extensions", STORAGE in ((lo.get("service") or {}).get("extensions") or []))
as_exporter, as_receiver = connector_users(lo)
check("the connector links the two pipelines", as_exporter == [APP_PIPELINE] and as_receiver == [VLLM_PIPELINE])

# --- stateStorage on, configInfo off -----------------------------------------------
print(f"\n{YELLOW}[stateStorage on, configInfo off]{RESET}")
so = otel_config("storage_only")
check(f"{STORAGE} is defined and in service.extensions",
      STORAGE in section(so, "extensions") and STORAGE in ((so.get("service") or {}).get("extensions") or []))
check("no connector anywhere", not any(mentions(otel_config("storage_only", a), CONNECTOR) for a in agent_crs("storage_only")))
check("no Info metric processors, and the vLLM pipeline and keep filter are unchanged",
      not any(mentions(so, x) for x in (LIVE, CLEANUP, PREFILTER)) and
      pipeline(so, VLLM_PIPELINE) == pipeline(off, VLLM_PIPELINE) and
      section(so, "processors").get(KEEP) == section(off, "processors").get(KEEP))
check("same pipelines as the logs-on render", set(pipelines(so)) == set(pipelines(off)))
so_crs = agent_crs("storage_only")
check("the state volume is on the node agent only",
      len(mounts(so_crs.get(AGENT) or {"spec": {}}, "otelstate")) == 1 and
      not any(mounts(cr, "otelstate") for name, cr in so_crs.items() if name != AGENT))
sol = otel_config("storage_only_logs_off")
check("with logs off, the storage alone does not turn on the app-log pipeline",
      APP_PIPELINE not in pipelines(sol) and APP_RECEIVER not in section(sol, "receivers") and
      set(pipelines(sol)) == set(pipelines(lo_base)))

# --- app-log checkpoints --------------------------------------------------------------
print(f"\n{YELLOW}[app-log checkpoints]{RESET}")
for name, want_storage, want_start, desc in (
        ("logs_on", None, "end", "logs on, both flags off"),
        ("info_logs_on", None, "end", "configInfo on, logs on, stateStorage off"),
        ("info_storage_logs_on", STORAGE, "end", "configInfo on, logs on, stateStorage on"),
        ("info_logs_off", STORAGE, "beginning", "configInfo on, logs off, stateStorage off"),
        ("info_storage_logs_off", STORAGE, "beginning", "configInfo on, logs off, stateStorage on"),
        ("storage_only", STORAGE, "end", "stateStorage only, logs on")):
    cfg = otel_config(name)
    rec = section(cfg, "receivers").get(APP_RECEIVER)
    got_storage = (rec or {}).get("storage")
    check(f"{desc}: {APP_RECEIVER} storage {want_storage or 'absent'}, start_at {want_start}",
          rec is not None and got_storage == want_storage and rec.get("start_at") == want_start and
          (want_storage is None or STORAGE in section(cfg, "extensions")))
check("stateStorage only, logs off: no app-log receiver to checkpoint",
      APP_RECEIVER not in section(otel_config("storage_only_logs_off"), "receivers"))
check("configInfo on, stateStorage on, logs on: the receiver is the one of stateStorage only",
      section(otel_config("info_storage_logs_on"), "receivers").get(APP_RECEIVER) ==
      section(so, "receivers").get(APP_RECEIVER))
check("configInfo on, logs off: stateStorage changes nothing in the otelConfig",
      otel_config("info_storage_logs_off") == lo)
for name in ("info_logs_on", "info_storage_logs_on", "info_logs_off", "info_storage_logs_off"):
    check(f"{name}: the connector keeps its state in {STORAGE}",
          (section(otel_config(name), "connectors").get(CONNECTOR) or {}).get("storage") == STORAGE)

# --- every mode: every defined component is used, every used one is defined ---------
print(f"\n{YELLOW}[components defined and used]{RESET}")
for name in MODES:
    for agent in agent_crs(name):
        cfg = otel_config(name, agent)
        if cfg:
            missing = undefined_components(cfg)
            if not check(f"{name} / {agent}: every used component is defined", not missing):
                print(f"    undefined: {missing}")
            leftover = unused_components(cfg)
            if not check(f"{name} / {agent}: every defined component is used", not leftover):
                print(f"    unused: {leftover}")

# --- emitInterval and the other settings -------------------------------------------
print(f"\n{YELLOW}[emitInterval and limits]{RESET}")


def emit(name):
    return (section(otel_config(name), "connectors").get(CONNECTOR) or {}).get("emit_interval")


check("emitInterval empty follows metricResolution (20s)", emit("emit_metric_resolution") == "20s")
check('emitInterval "15s" is used as is', emit("emit_15s") == "15s")
check('emitInterval "1h" is used as is', emit("emit_1h") == "1h")


def poll(name):
    return (section(otel_config(name), "receivers").get(APP_RECEIVER) or {}).get("poll_interval")


# The logs-off poll interval is 10s, or the effective emit interval when that is shorter.
for name, want, desc in (("poll_emit_5s", "5s", "emitInterval 5s"),
                         ("info_logs_off", "10s", "emitInterval 30s (the default, from metricResolution)"),
                         ("poll_emit_2m", "10s", "emitInterval 2m"),
                         ("poll_resolution_8s", "8s", "emitInterval empty, metricResolution 8s")):
    check(f"logs off, {desc}: {APP_RECEIVER} poll_interval {want}", poll(name) == want)
check(f"logs on, emitInterval 5s: {APP_RECEIVER} keeps the receiver default (no poll_interval)",
      rc("poll_emit_5s_logs_on") == 0 and poll("poll_emit_5s_logs_on") is None and
      APP_RECEIVER in section(otel_config("poll_emit_5s_logs_on"), "receivers"))
for bad in ("15", "0s", "25h", "1m30s", "abc"):
    check(f'emitInterval "{bad}" fails the render with a message naming the setting',
          rc(f"emit_bad_{bad}") != 0 and "configInfo.emitInterval" in err(f"emit_bad_{bad}"))
for name, setting in (("bad_max_state_bytes", "maxStateBytes"), ("bad_max_value_length", "maxValueLength"),
                      ("bad_max_entities", "maxEntities")):
    check(f"{setting} out of the connector's bounds fails the render",
          rc(name) != 0 and f"configInfo.{setting}" in err(name))
check("a relative stateStorage.hostPath fails the render",
      rc("bad_host_path") != 0 and "stateStorage.hostPath" in err("bad_host_path"))

# --- maxSurge guard ------------------------------------------------------------------
print(f"\n{YELLOW}[maxSurge guard]{RESET}")
for name, desc in (("surge_info", "configInfo on, agent maxSurge 1"),
                   ("surge_info_logs_off", "configInfo on, logs off, agent maxSurge 1"),
                   ("surge_storage", "stateStorage on, agent maxSurge 1"),
                   ("surge_agents_entry", "configInfo on, agents[] entry maxSurge 10%")):
    check(f"{desc}: fails the render with a maxSurge message",
          rc(name) != 0 and "maxSurge 0" in err(name))
check("OnDelete has no surge and renders", rc("surge_on_delete") == 0)
check("the cluster-scraper Deployment's 25% maxSurge does not trip the guard", rc("info_logs_on") == 0)

total = passed + failed
print("\n=== Summary ===")
if failed:
    print(f"{RED}{failed} of {total} checks failed.{RESET}")
    sys.exit(1)
print(f"{GREEN}All {total} checks passed.{RESET}")
PY
