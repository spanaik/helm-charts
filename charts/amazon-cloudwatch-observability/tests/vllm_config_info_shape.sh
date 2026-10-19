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
#      to feed the connector, ships nothing, and runs only the processors the
#      connector needs. No mode defines a component that no pipeline uses.
#   4. Stale facts are dropped right after k8sattributes adds the live pod UID.
#   5. Storage: one file_storage extension, a writable hostPath on the node agent
#      DaemonSet only, and maxSurge 0.
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
render "$CHART_DIR" vllm_off "${OTEL[@]}" --set otelContainerInsights.solutions.vllm.enabled=false
render "$CHART_DIR" info_vllm_off "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.enabled=false
render "$CHART_DIR" info_otel_off "${INFO[@]}"
render "$CHART_DIR" storage_only "${OTEL[@]}" --set otelContainerInsights.stateStorage.enabled=true
render "$CHART_DIR" storage_only_logs_off "${OTEL[@]}" "${LOGS_OFF[@]}" --set otelContainerInsights.stateStorage.enabled=true
render "$CHART_DIR" emit_metric_resolution "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.metricResolution=20s
render "$CHART_DIR" emit_15s "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=15s
render "$CHART_DIR" emit_1h "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.emitInterval=1h
for bad in 15 0s 25h 1m30s abc; do
    render "$CHART_DIR" "emit_bad_${bad}" "${OTEL[@]}" "${INFO[@]}" --set "otelContainerInsights.solutions.vllm.configInfo.emitInterval=${bad}"
done
render "$CHART_DIR" bad_max_state_bytes "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.maxStateBytes=1000
render "$CHART_DIR" bad_max_value_length "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.maxValueLength=2000
render "$CHART_DIR" bad_max_entities "${OTEL[@]}" "${INFO[@]}" --set otelContainerInsights.solutions.vllm.configInfo.maxEntities=0
render "$CHART_DIR" bad_host_path "${OTEL[@]}" --set otelContainerInsights.stateStorage.enabled=true --set otelContainerInsights.stateStorage.hostPath=relative/dir
render "$CHART_DIR" surge_info "${OTEL[@]}" "${INFO[@]}" "${MAX_SURGE_1[@]}"
render "$CHART_DIR" surge_storage "${OTEL[@]}" --set otelContainerInsights.stateStorage.enabled=true "${MAX_SURGE_1[@]}"
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
LIVE = "filter/cw_k8s_ci_v0_vllm_info_live"
CLEANUP = "transform/cw_k8s_ci_v0_vllm_info_cleanup"
PREFILTER = "filter/cw_k8s_ci_v0_vllm_info_prefilter"
INFO_METRIC = "vllm_engine_config_info"
# The connector matches the startup line by plain substrings, no regex; the logs-off
# prefilter keeps every record containing PREFILTER_SUBSTRING, so it must be a
# substring of each of them.
BODY_CONTAINS = ["Initializing an LLM engine (v", "Initializing a V0 LLM engine (v",
                 "Initializing a V1 LLM engine (v"]
PREFILTER_SUBSTRING = "LLM engine (v"

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
    """Components defined but used by no pipeline (extensions: not in service.extensions)."""
    used = set()
    for p in pipelines(cfg).values():
        for k in ("receivers", "processors", "exporters"):
            used |= set(p.get(k) or [])
    unused = [c for k in ("receivers", "processors", "exporters", "connectors")
              for c in section(cfg, k) if c not in used]
    started = set((cfg.get("service") or {}).get("extensions") or [])
    return unused + [e for e in section(cfg, "extensions") if e not in started]


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
for name in ("default", "logs_on", "logs_off", "logs_on_tuned", "logs_on_surge", "info_logs_on",
             "info_logs_off", "info_vllm_off", "info_otel_off", "storage_only", "storage_only_logs_off",
             "emit_metric_resolution", "emit_15s", "emit_1h", "surge_on_delete"):
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
          not any(mentions(c, x) for c in everything for x in (CONNECTOR, STORAGE, LIVE, CLEANUP, PREFILTER)))
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
check("every component named in service is defined", not undefined_components(on))
as_exporter, as_receiver = connector_users(on)
check(f"the connector is an exporter of {APP_PIPELINE} only", as_exporter == [APP_PIPELINE])
check(f"the connector is a receiver of {VLLM_PIPELINE} only", as_receiver == [VLLM_PIPELINE])
check(f"{APP_PIPELINE} still ships logs, then feeds the connector",
      pipeline(on, APP_PIPELINE).get("exporters") == [APP_EXPORTER, CONNECTOR])
check(f"{VLLM_PIPELINE} keeps its scrape receiver first",
      pipeline(on, VLLM_PIPELINE).get("receivers") == [VLLM_RECEIVER, CONNECTOR])
check(f"{APP_PIPELINE} processors are unchanged (no prefilter while logs are shipped)",
      pipeline(on, APP_PIPELINE).get("processors") == pipeline(off, APP_PIPELINE).get("processors"))

connector = section(on, "connectors").get(CONNECTOR) or {}
rules = connector.get("rules") or [{}]
rule = rules[0]
check("the connector keeps its state in the storage extension", connector.get("storage") == STORAGE)
check("emit_interval defaults to metricResolution (30s)", connector.get("emit_interval") == "30s")
check("max_state_bytes and max_value_length come from values",
      connector.get("max_state_bytes") == 1048576 and connector.get("max_value_length") == 256)
check(f"one rule, {INFO_METRIC}, with max_entities 500",
      len(rules) == 1 and rule.get("name") == INFO_METRIC and rule.get("max_entities") == 500)
check("the rule is keyed on the pod UID and copies pod name, namespace and container",
      rule.get("identity") == ["k8s.pod.uid"] and
      rule.get("include_resource_attributes") == ["k8s.pod.name", "k8s.namespace.name", "k8s.container.name"])
check("the startup line is matched by the three body_contains substrings, with no OTTL condition",
      rule.get("body_contains") == BODY_CONTAINS and "conditions" not in rule)
check(f"each body_contains substring contains the prefilter's {PREFILTER_SUBSTRING!r}",
      all(PREFILTER_SUBSTRING in b for b in BODY_CONTAINS))
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
app_receiver = section(on, "receivers").get(APP_RECEIVER) or {}
check(f"{APP_RECEIVER} checkpoints in {STORAGE}", app_receiver.get("storage") == STORAGE)
check(f"{APP_RECEIVER} still starts at the end while logs are shipped", app_receiver.get("start_at") == "end")

# 4. Stale facts.
chain = pipeline(on, VLLM_PIPELINE).get("processors") or []
pod_at = chain.index(POD) if POD in chain else -1
check(f"{LIVE} and {CLEANUP} follow {POD} directly",
      pod_at >= 0 and chain[pod_at + 1:pod_at + 3] == [LIVE, CLEANUP])
check(f"apart from those two, {VLLM_PIPELINE} processors are unchanged",
      [p for p in chain if p not in (LIVE, CLEANUP)] == pipeline(off, VLLM_PIPELINE).get("processors"))
identity_key = (connector.get("identity_output_prefix") or "") + "k8s.pod.uid"
live = (section(on, "processors").get(LIVE) or {})
live_conditions = ((live.get("metrics") or {}).get("datapoint")) or []
check(f"{LIVE} drops a data point whose {identity_key} is not the live k8s.pod.uid",
      live.get("error_mode") == "ignore" and live_conditions == [
          f'resource.attributes["{identity_key}"] != nil and '
          f'resource.attributes["{identity_key}"] != resource.attributes["k8s.pod.uid"]'])
cleanup = section(on, "processors").get(CLEANUP) or {}
cleanup_statements = [(g.get("context"), st) for g in cleanup.get("metric_statements") or []
                      for st in g.get("statements") or []]
check(f"{CLEANUP} deletes {identity_key} from the resource",
      len(cleanup_statements) == 1 and cleanup_statements[0][0] == "resource" and
      cleanup_statements[0][1].startswith(f'delete_key(attributes, "{identity_key}")'))

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
check("every component named in service is defined", not undefined_components(lo))
check(f"the only pipeline added to the logs-off render is {APP_PIPELINE}",
      set(pipelines(lo)) == set(pipelines(lo_base)) | {APP_PIPELINE} and APP_PIPELINE not in pipelines(lo_base))
check(f"{APP_PIPELINE} exports only to the connector",
      pipeline(lo, APP_PIPELINE).get("exporters") == [CONNECTOR])
lo_chain = pipeline(lo, APP_PIPELINE).get("processors") or []
check(f"{APP_PIPELINE} runs only {PREFILTER}, then {POD} (which adds k8s.pod.uid)",
      lo_chain == [PREFILTER, POD])
check("the log-shipping processors are not defined",
      not any(x.startswith(("transform/cw_k8s_ci_v0_logs_", "batch/cw_k8s_ci_v0_logs_"))
              for x in section(lo, "processors")))
prefilter = section(lo, "processors").get(PREFILTER) or {}
pre_conditions = ((prefilter.get("logs") or {}).get("log_record")) or []
check(f"{PREFILTER} drops records whose body lacks {PREFILTER_SUBSTRING!r}, by substring (Index), no regex",
      prefilter.get("error_mode") == "ignore" and pre_conditions == [f'Index(body, "{PREFILTER_SUBSTRING}") == -1'])
pre_re = re.fullmatch(r'Index\(body, ' + OTTL_STRING + r'\) == -1', pre_conditions[0] if pre_conditions else "")
check(f"{PREFILTER} keeps every sample startup line and drops an unrelated line",
      bool(pre_re) and all(ottl_unescape(pre_re.group(1)) in line for line, _ in EXPECTED.values()) and
      ottl_unescape(pre_re.group(1)) not in UNRELATED_LINE)
lo_receiver = section(lo, "receivers").get(APP_RECEIVER) or {}
check(f"{APP_RECEIVER} starts at the beginning (nothing is shipped)", lo_receiver.get("start_at") == "beginning")
check(f"{APP_RECEIVER} checkpoints in {STORAGE}", lo_receiver.get("storage") == STORAGE)
check(f"no {APP_EXPORTER}, host-log pipeline, or logs auth extensions",
      APP_EXPORTER not in section(lo, "exporters") and "logs/cw_k8s_ci_v0_node" not in pipelines(lo) and
      "filelog/cw_k8s_ci_v0_node" not in section(lo, "receivers") and
      not any(e in section(lo, "extensions") for e in
              ("sigv4auth/cw_k8s_ci_v0_logs_dest", "awscloudwatchlogsprovisioner/cw_k8s_ci_v0_logs")))
check("no exporter other than the metrics destination", list(section(lo, "exporters")) == ["otlphttp/cw_k8s_ci_v0_metrics_dest"])
lo_crs = agent_crs("info_logs_off")
lo_node = lo_crs.get(AGENT) or {"spec": {}}
check("/var/log is mounted read-only on the node agent",
      [(m.get("mountPath"), m.get("readOnly")) for m in mounts(lo_node, "varlog")] == [("/var/log", True)] and
      volumes(lo_node, "varlog") == [{"hostPath": {"path": "/var/log"}, "name": "varlog"}])
check("/var/log is not mounted on any other agent",
      not any(mounts(cr, "varlog") for name, cr in lo_crs.items() if name != AGENT))
check("the state volume is mounted on the node agent", len(mounts(lo_node, "otelstate")) == 1)
check(f"{STORAGE} is in service.extensions", STORAGE in ((lo.get("service") or {}).get("extensions") or []))
as_exporter, as_receiver = connector_users(lo)
check("the connector links the two pipelines", as_exporter == [APP_PIPELINE] and as_receiver == [VLLM_PIPELINE])

# --- stateStorage on, configInfo off -----------------------------------------------
print(f"\n{YELLOW}[stateStorage on, configInfo off]{RESET}")
so = otel_config("storage_only")
check("every component named in service is defined", not undefined_components(so))
check(f"{STORAGE} is defined and in service.extensions",
      STORAGE in section(so, "extensions") and STORAGE in ((so.get("service") or {}).get("extensions") or []))
check(f"{APP_RECEIVER} checkpoints in {STORAGE} and starts at the end",
      (section(so, "receivers").get(APP_RECEIVER) or {}).get("storage") == STORAGE and
      (section(so, "receivers").get(APP_RECEIVER) or {}).get("start_at") == "end")
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

# --- every mode: nothing defined that no pipeline uses ------------------------------
print(f"\n{YELLOW}[no unused components]{RESET}")
for name in ("default", "logs_on", "logs_off", "info_logs_on", "info_logs_off", "storage_only",
             "storage_only_logs_off", "info_vllm_off"):
    for agent in agent_crs(name):
        cfg = otel_config(name, agent)
        if cfg:
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
