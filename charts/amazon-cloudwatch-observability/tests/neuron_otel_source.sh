#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Asserts which collector serves Neuron on the OTEL Container Insights path over
# all 8 combinations of otelContainerInsights / neuronMonitor / neuronObserver.
# At most one of the two OTEL Neuron pipelines may be configured, and no pipeline
# may reference a component its gate did not render.
#
# Run from the repo root:
#     bash charts/amazon-cloudwatch-observability/tests/neuron_otel_source.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
N='\033[0m'

pass_count=0
fail_count=0

# Presence assertions run without python3; the dangling-reference check needs it.
check_refs=1
if ! command -v python3 >/dev/null 2>&1; then
    check_refs=0
    echo -e "${Y}python3 not found — skipping the undefined-component-reference check.${N}"
fi

OBSERVER_PIPELINE="metrics/cw_k8s_ci_v0_neuron_observer:"
MONITOR_PIPELINE="metrics/cw_k8s_ci_v0_neuron:"
OBSERVER_DAEMONSET="k8s-app: neuron-observer"
MONITOR_DAEMONSET="kind: NeuronMonitor"

run_case() {
    local num="$1" otel="$2" monitor="$3" observer="$4" want="$5" want_ds="$6"

    printf "\n${Y}[Case #%s]${N} otel=%s monitor=%s observer=%s  —  expect OTEL source: %s\n" \
        "$num" "$otel" "$monitor" "$observer" "$want"

    local -a args=(
        --set region=us-west-2
        --set clusterName=test-cluster
        --set "otelContainerInsights.enabled=$otel"
        --set "neuronMonitor.enabled=$monitor"
    )
    [[ "$observer" != "unset" ]] && args+=(--set "neuronObserver.enabled=$observer")

    local output
    if ! output=$(helm template "$CHART_DIR" "${args[@]}" 2>&1); then
        echo -e "  ${R}FAIL${N}: helm template failed"
        echo "$output" | tail -5 | sed 's/^/    /'
        fail_count=$((fail_count + 1))
        return
    fi

    local local_fail=0
    local got_observer=no got_monitor=no
    grep -q "$OBSERVER_PIPELINE" <<< "$output" && got_observer=yes
    grep -q "$MONITOR_PIPELINE" <<< "$output" && got_monitor=yes

    local want_observer=no want_monitor=no
    case "$want" in
        observer) want_observer=yes ;;
        monitor) want_monitor=yes ;;
    esac

    if [[ "$got_observer" != "$want_observer" ]]; then
        echo -e "  ${R}FAIL${N}: observer OTEL pipeline present=$got_observer, want $want_observer"
        local_fail=1
    fi
    if [[ "$got_monitor" != "$want_monitor" ]]; then
        echo -e "  ${R}FAIL${N}: monitor OTEL pipeline present=$got_monitor, want $want_monitor"
        local_fail=1
    fi

    # Must track its own pipeline exactly: a pipeline with no target reports up=0.
    local got_obs_ds=no
    grep -q "$OBSERVER_DAEMONSET" <<< "$output" && got_obs_ds=yes
    if [[ "$got_obs_ds" != "$want_observer" ]]; then
        echo -e "  ${R}FAIL${N}: observer DaemonSet present=$got_obs_ds, want $want_observer"
        local_fail=1
    fi

    # Gated on neuronMonitor.enabled alone — EMF needs it either way.
    local got_mon_ds=no
    grep -q "$MONITOR_DAEMONSET" <<< "$output" && got_mon_ds=yes
    if [[ "$got_mon_ds" != "$want_ds" ]]; then
        echo -e "  ${R}FAIL${N}: neuron-monitor DaemonSet present=$got_mon_ds, want $want_ds"
        local_fail=1
    fi

    # A pipeline naming an unrendered component makes the collector refuse to start.
    if [[ $check_refs -eq 1 ]]; then
        local undefined
        undefined=$(python3 "$SCRIPT_DIR/undefined_refs.py" <<< "$output") || true
        if [[ "$undefined" != "none" ]]; then
            echo -e "  ${R}FAIL${N}: pipelines reference undefined components: $undefined"
            local_fail=1
        fi
    fi

    if [[ $local_fail -eq 0 ]]; then
        echo -e "  ${G}PASS${N}"
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
}

#          #  otel   monitor observer  OTEL source  monitor DaemonSet
run_case  1  false  false   unset     none         no
run_case  2  false  true    unset     none         yes
run_case  3  true   false   unset     observer     no
run_case  4  true   true    unset     monitor      yes
run_case  5  true   true    true      observer     yes
run_case  6  true   false   true      observer     no
run_case  7  true   true    false     monitor      yes
run_case  8  true   false   false     none         no

total=$((pass_count + fail_count))
echo ""
echo "=== Summary ==="
if [[ $fail_count -eq 0 ]]; then
    echo -e "${G}All $total cases passed.${N}"
    exit 0
else
    echo -e "${R}$fail_count of $total cases failed.${N}"
    exit 1
fi
