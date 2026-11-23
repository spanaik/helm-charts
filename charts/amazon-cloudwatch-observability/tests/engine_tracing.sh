#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pins manager.engineTracing: it reaches the operator as the operator.engine.tracing feature gate plus
# --engine-traces-endpoint, with the node agent's OTLP gRPC address (from the otlp values and the release
# namespace); the sampler arguments follow only when a sampler is set; its keys are enabled, endpoint, sampler
# and samplerArg; and nothing else in the release changes, including every agent config. Template-level.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM="${HELM:-helm}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
P=manager.engineTracing

render() {
    "$HELM" template "$CHART_DIR" -n "$1" --set region=us-west-2 --set clusterName=test-cluster "${@:2}"
}

render amazon-cloudwatch > "${TMP_DIR}/off.yaml"
render amazon-cloudwatch --set "$P.enabled=true" > "${TMP_DIR}/on.yaml"
render amazon-cloudwatch --set "$P.enabled=false" > "${TMP_DIR}/false.yaml"
# The endpoint follows the otlp values, the release namespace and the agent name.
render amazon-cloudwatch --set otlp.grpc.port=14317 --set "$P.enabled=true" > "${TMP_DIR}/port.yaml"
render observability --set "$P.enabled=true" > "${TMP_DIR}/namespace.yaml"
render amazon-cloudwatch --set agent.name=node-agent --set-json 'agents=[{"name":"node-agent"}]' \
    --set "$P.enabled=true" > "${TMP_DIR}/renamed.yaml"
# An endpoint of your own replaces the node agent's.
render amazon-cloudwatch --set "$P.enabled=true" --set-string "$P.endpoint=my-collector.tracing:4317" > "${TMP_DIR}/custom.yaml"
# OTLP/HTTP off does not matter: the engines send over gRPC.
render amazon-cloudwatch --set otlp.http.enabled=false --set "$P.enabled=true" > "${TMP_DIR}/grpc-only.yaml"
# The sampler arguments.
render amazon-cloudwatch --set "$P.enabled=true" --set-string "$P.sampler=parentbased_traceidratio" \
    --set-string "$P.samplerArg=0.1" > "${TMP_DIR}/sampler.yaml"
render amazon-cloudwatch --set "$P.enabled=true" --set-string "$P.sampler=always_on" > "${TMP_DIR}/sampler-only.yaml"
# Keeping Application Signals on the engine.
render amazon-cloudwatch --set "$P.enabled=true" --set "$P.keepApplicationSignals=true" > "${TMP_DIR}/keep-appsig.yaml"
# While the feature is off, the OTLP endpoint may be off too.
render amazon-cloudwatch --set otlp.enabled=false > "${TMP_DIR}/otlp-off.yaml"
render amazon-cloudwatch --set otlp.enabled=false --set "$P.enabled=false" > "${TMP_DIR}/otlp-off-false.yaml"
render amazon-cloudwatch --set agent.enabled=false --set "$P.enabled=false" > "${TMP_DIR}/agent-off-false.yaml"
# Each pair differs only in engineTracing: the agent configs must be identical.
render amazon-cloudwatch --set otelContainerInsights.enabled=true > "${TMP_DIR}/ci-off.yaml"
render amazon-cloudwatch --set otelContainerInsights.enabled=true --set "$P.enabled=true" > "${TMP_DIR}/ci-on.yaml"

fails=0
expect_fail() {
    if render "$1" "${@:3}" > /dev/null 2> "${TMP_DIR}/err" || ! grep -q "$2" "${TMP_DIR}/err"; then
        echo "  FAIL: expected '$2' for ${*:3}"; fails=$((fails + 1))
    else echo "  PASS: rejects ${*:3} (-n $1)"; fi
}

# Enabled with no endpoint to pass.
expect_fail amazon-cloudwatch "requires the node agent's OTLP gRPC endpoint" --set "$P.enabled=true" --set otlp.enabled=false
expect_fail amazon-cloudwatch "requires the node agent's OTLP gRPC endpoint" --set "$P.enabled=true" --set otlp.grpc.enabled=false
expect_fail amazon-cloudwatch "requires the node agent's OTLP gRPC endpoint" --set "$P.enabled=true" --set agent.enabled=false
expect_fail amazon-cloudwatch "requires the node agent's OTLP gRPC endpoint" --set "$P.enabled=true" \
    --set agent.name=node-agent
# An endpoint of your own needs none of the above.
render amazon-cloudwatch --set otlp.enabled=false --set "$P.enabled=true" \
    --set-string "$P.endpoint=my-collector.tracing:4317" > "${TMP_DIR}/custom-otlp-off.yaml"
# The schema.
expect_fail amazon-cloudwatch "unknown key" --set "$P.enabled=true" --set-string "$P.port=4317"
expect_fail amazon-cloudwatch "unknown key" --set "$P.enabled=false" --set-string "$P.Enabled=true"
expect_fail amazon-cloudwatch "enabled must be a boolean" --set-string "$P.enabled=true"
expect_fail amazon-cloudwatch "endpoint must be a string" --set "$P.enabled=true" --set "$P.endpoint=4317"
expect_fail amazon-cloudwatch "samplerArg is set without" --set "$P.enabled=true" --set-string "$P.samplerArg=0.1"
expect_fail amazon-cloudwatch "keepApplicationSignals must be a boolean" --set "$P.enabled=true" --set-string "$P.keepApplicationSignals=true"

python3 - "${TMP_DIR}" "$fails" <<'PY'
import json
import sys
import yaml

tmp, failed = sys.argv[1], int(sys.argv[2])


def check(desc, ok):
    global failed
    print(f"  {'PASS' if ok else 'FAIL'}: {desc}")
    failed += 0 if ok else 1


def docs(name):
    return [d for d in yaml.safe_load_all(open(f"{tmp}/{name}.yaml")) if d]


def operator_args(name):
    for d in docs(name):
        if d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("controller-manager"):
            return d["spec"]["template"]["spec"]["containers"][0]["args"]
    raise AssertionError(f"no operator Deployment in {name}")


def arg(name, prefix):
    values = [a.split("=", 1)[1] for a in operator_args(name) if a.startswith(prefix + "=")]
    return values[0] if values else None


def gate_on(name):
    gates = arg(name, "--feature-gates")
    return "operator.engine.tracing" in gates.split(",")


CERT_KINDS = {"Secret", "MutatingWebhookConfiguration", "ValidatingWebhookConfiguration"}


def rest(name):
    """Every rendered document, minus generated cert material, with the operator's engine arguments
    removed and its feature gates blanked, so that the two renders are comparable."""
    out = []
    for d in docs(name):
        if d.get("kind") in CERT_KINDS:
            continue
        if d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("controller-manager"):
            c = d["spec"]["template"]["spec"]["containers"][0]
            kept = [a for a in c["args"] if not a.startswith("--engine-traces")]
            c["args"] = ["<arg>" if a.startswith("--feature-gates=") else a for a in kept]
            (d["spec"]["template"]["metadata"].get("annotations") or {}).pop("checksum/config", None)
        out.append(json.dumps(d, sort_keys=True))
    return sorted(out)


ENGINE_ARGS = ("--engine-traces-endpoint", "--engine-traces-sampler", "--engine-traces-sampler-arg")

# Off by default, and off is off.
for name in ("off", "false", "otlp-off", "otlp-off-false", "agent-off-false"):
    check(f"{name}: no feature gate", not gate_on(name))
    check(f"{name}: no engine arguments", not [a for a in operator_args(name) if a.startswith("--engine-traces-")])

# On: the gate and the node agent's gRPC address.
check("on: feature gate", gate_on("on"))
check("on: endpoint", arg("on", "--engine-traces-endpoint") == "cloudwatch-agent.amazon-cloudwatch:4317")
check("on: no sampler", arg("on", "--engine-traces-sampler") is None)
check("port: endpoint follows otlp.grpc.port", arg("port", "--engine-traces-endpoint") == "cloudwatch-agent.amazon-cloudwatch:14317")
check("namespace: endpoint follows the release namespace", arg("namespace", "--engine-traces-endpoint") == "cloudwatch-agent.observability:4317")
check("renamed: endpoint follows the agent name", arg("renamed", "--engine-traces-endpoint") == "node-agent.amazon-cloudwatch:4317")
check("custom: endpoint is taken as written", arg("custom", "--engine-traces-endpoint") == "my-collector.tracing:4317")
check("grpc-only: endpoint", arg("grpc-only", "--engine-traces-endpoint") == "cloudwatch-agent.amazon-cloudwatch:4317")
check("custom-otlp-off: an endpoint of your own needs no receiver", arg("custom-otlp-off", "--engine-traces-endpoint") == "my-collector.tracing:4317")

# The sampler follows only with a sampler, and the argument only with both.
check("sampler: sampler", arg("sampler", "--engine-traces-sampler") == "parentbased_traceidratio")
check("sampler: sampler argument", arg("sampler", "--engine-traces-sampler-arg") == "0.1")
check("sampler-only: sampler", arg("sampler-only", "--engine-traces-sampler") == "always_on")
check("sampler-only: no sampler argument", arg("sampler-only", "--engine-traces-sampler-arg") is None)

# Application Signals on the engine is opt in, and off by default.
KEEP = "--engine-traces-keep-application-signals"
check("on: Application Signals not kept", KEEP not in operator_args("on"))
check("keep-appsig: Application Signals kept", KEEP in operator_args("keep-appsig"))

# Nothing else in the release changes.
check("on changes only the operator arguments", rest("off") == rest("on"))
check("otelContainerInsights: on changes only the operator arguments", rest("ci-off") == rest("ci-on"))

print("FAIL" if failed else "PASS")
sys.exit(1 if failed else 0)
PY
