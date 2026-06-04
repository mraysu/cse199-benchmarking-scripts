#!/bin/bash

DEST_ROOT="${1:-logs}"
LOGS_DIR="$DEST_ROOT/combined"
mkdir -p "$LOGS_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
SESSION_FILE="$LOGS_DIR/combined_stress_${TIMESTAMP}.log"
TEMP_FILE="$DEST_ROOT/temp/temp_${TIMESTAMP}.csv"
POWER_FILE="$DEST_ROOT/power/power_${TIMESTAMP}.csv"
METRICS_FILE="$DEST_ROOT/cpu/cpu_metrics_${TIMESTAMP}.csv"
STAGE_FILE="/tmp/current_stage_${TIMESTAMP}.txt"
JOURNAL_FILE="$LOGS_DIR/journal_${TIMESTAMP}.log"
WATCHDOG_FILE="$LOGS_DIR/watchdog_${TIMESTAMP}.csv"
THERMAL_FILE="$LOGS_DIR/thermal_${TIMESTAMP}.csv"

mkdir -p "$DEST_ROOT/temp" "$DEST_ROOT/power" "$DEST_ROOT/cpu"

echo "combined_cpu_gpu" > "$STAGE_FILE"
sync

# Start background loggers
./temp_benchmark.sh "$TEMP_FILE" "$STAGE_FILE" &
TEMP_PID=$!

./power_benchmark.sh "$POWER_FILE" "$STAGE_FILE" &
POWER_PID=$!

./cpu_metrics.sh "$METRICS_FILE" "$STAGE_FILE" &
METRICS_PID=$!

# Continuous journal logger
(
    journalctl -f --no-pager 2>/dev/null | while IFS= read -r line; do
        echo "$line" >> "$JOURNAL_FILE"
        sync "$JOURNAL_FILE"
    done
) &
JOURNAL_PID=$!

# Watchdog at 0.1s with immediate sync
(
    IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0
    echo "time,vph_pwr_mv,gpu_busy_pct,cpu0_freq_mhz,cpu4_freq_mhz,note" > "$WATCHDOG_FILE"
    sync "$WATCHDOG_FILE"

    while true; do
        vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
        vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
        gpu_busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print $1}')
        cpu0_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
        cpu4_freq=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
        cpu0_mhz=$(awk "BEGIN {printf \"%.0f\", $cpu0_freq/1000}")
        cpu4_mhz=$(awk "BEGIN {printf \"%.0f\", $cpu4_freq/1000}")

        note=""
        if awk "BEGIN {exit !($vph_mv < 3800)}"; then
            note="LOW_VOLTAGE_WARNING"
        fi
        if awk "BEGIN {exit !($vph_mv < 3500)}"; then
            note="CRITICAL_VOLTAGE"
        fi

        echo "$(date +%T),$vph_mv,$gpu_busy,$cpu0_mhz,$cpu4_mhz,$note" >> "$WATCHDOG_FILE"
        sync "$WATCHDOG_FILE"
        sleep 0.1
    done
) &
WATCHDOG_PID=$!

# Thermal trip monitor - logs when trip points are crossed
(
    echo "time,zone,type,temp_c,trip_point,event" > "$THERMAL_FILE"
    sync "$THERMAL_FILE"

    TRIP_POINTS=(65000 80000 90000 110000 118000 125000)
    declare -A PREV_TRIPS

    while true; do
        for zone in /sys/class/thermal/thermal_zone*; do
            if [ -f "$zone/temp" ]; then
                temp=$(cat "$zone/temp" 2>/dev/null || echo 0)
                type=$(cat "$zone/type" 2>/dev/null || echo "unknown")
                zone_id=$(basename "$zone")

                for trip in "${TRIP_POINTS[@]}"; do
                    key="${zone_id}_${trip}"
                    temp_c=$(awk "BEGIN {printf \"%.1f\", $temp/1000}")
                    trip_c=$(awk "BEGIN {printf \"%.1f\", $trip/1000}")

                    if [ "$temp" -ge "$trip" ] && [ "${PREV_TRIPS[$key]}" != "triggered" ]; then
                        echo "$(date +%T),$zone_id,$type,$temp_c,$trip_c,TRIP_CROSSED" >> "$THERMAL_FILE"
                        sync "$THERMAL_FILE"
                        PREV_TRIPS[$key]="triggered"
                    elif [ "$temp" -lt "$trip" ] && [ "${PREV_TRIPS[$key]}" = "triggered" ]; then
                        echo "$(date +%T),$zone_id,$type,$temp_c,$trip_c,TRIP_CLEARED" >> "$THERMAL_FILE"
                        sync "$THERMAL_FILE"
                        PREV_TRIPS[$key]=""
                    fi
                done
            fi
        done
        sleep 1
    done
) &
THERMAL_PID=$!

# Live temperature display in terminal (runs in foreground alongside stress)
live_temp_display() {
    while true; do
        clear
        echo "============================================"
        echo "  Rubik Pi 3 - Combined Stress Monitor"
        echo "  $(date +%H:%M:%S) | Logging: $TIMESTAMP"
        echo "============================================"

        # Thermal zones
        echo ""
        echo "--- TEMPERATURES ---"
        for zone in /sys/class/thermal/thermal_zone*; do
            if [ -f "$zone/temp" ]; then
                type=$(cat "$zone/type" 2>/dev/null)
                temp=$(cat "$zone/temp" 2>/dev/null || echo 0)
                temp_c=$(awk "BEGIN {printf \"%.1f\", $temp/1000}")

                # Color coding based on temperature
                if [ "$temp" -ge 90000 ]; then
                    status="!!! CRITICAL !!!"
                elif [ "$temp" -ge 80000 ]; then
                    status="** HOT **"
                elif [ "$temp" -ge 65000 ]; then
                    status="* WARM *"
                else
                    status="OK"
                fi

                printf "%-35s %6s°C  %s\n" "$type" "$temp_c" "$status"
            fi
        done

        # Voltage and GPU
        echo ""
        echo "--- POWER & GPU ---"
        IIO0=/sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-08/c440000.spmi:pmic@8:adc@3100/iio:device0
        vph=$(cat "$IIO0/in_voltage_vph_pwr_input" 2>/dev/null || echo 0)
        vph_mv=$(awk "BEGIN {printf \"%.2f\", $vph/1000}")
        gpu_busy=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | awk '{print $1}')
        gpu_clk=$(cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null || echo 0)

        if awk "BEGIN {exit !($vph_mv < 3800)}"; then
            volt_status="!!! LOW VOLTAGE !!!"
        else
            volt_status="OK"
        fi

        printf "%-35s %6s mV  %s\n" "System Rail (vph_pwr)" "$vph_mv" "$volt_status"
        printf "%-35s %6s %%\n" "GPU Busy" "$gpu_busy"
        printf "%-35s %6s MHz\n" "GPU Clock" "$gpu_clk"

        # CPU frequencies
        echo ""
        echo "--- CPU FREQUENCIES ---"
        for i in 0 1 2 3 4 5 6 7; do
            freq=$(cat /sys/devices/system/cpu/cpu${i}/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
            mhz=$(awk "BEGIN {printf \"%.0f\", $freq/1000}")
            if [ "$i" -lt 4 ]; then
                cluster="efficiency"
            else
                cluster="performance"
            fi
            printf "CPU%d (%s): %s MHz\n" "$i" "$cluster" "$mhz"
        done

        echo ""
        echo "--- TRIP POINTS (cpu0-thermal) ---"
        temps=(65 80 90 110 118 125)
        current_temp=$(cat /sys/class/thermal/thermal_zone10/temp 2>/dev/null || echo 0)
        current_c=$(awk "BEGIN {printf \"%.1f\", $current_temp/1000}")
        echo "Current: ${current_c}°C"
        for t in "${temps[@]}"; do
            if [ "$current_temp" -ge "$((t * 1000))" ]; then
                printf "  %3d°C trip: CROSSED\n" "$t"
            else
                printf "  %3d°C trip: ok\n" "$t"
            fi
        done

        sleep 1
    done
}

echo "Combined CPU+GPU Stress | Logging to: $SESSION_FILE"
echo "Started: $(date)" | tee "$SESSION_FILE"
sync "$SESSION_FILE"

# Start GPU stress locally in background
echo "Starting local GPU stress (dlprim_flops)..." | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

(
    # qcom-adreno-vars.sh may not exist in all runtime images.
    if [ -f /usr/lib/qcom-adreno/qcom-adreno-vars.sh ]; then
        # shellcheck disable=SC1091
        source /usr/lib/qcom-adreno/qcom-adreno-vars.sh
    fi

    while true; do
        dlprim_flops 0:0
    done
) 2>&1 | while IFS= read -r line; do
    echo "[dlprim_flops] $line" >> "$SESSION_FILE"
    sync "$SESSION_FILE"
done &
GPU_PID=$!

echo "Waiting for local GPU stress to initialize..." | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"
sleep 5

# Start live display in background
live_temp_display &
DISPLAY_PID=$!

# Start CPU stress
echo "Starting CPU stress..." | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

stress-ng --cpu 8 --timeout 120s --metrics 2>&1 | while IFS= read -r line; do
    echo "$line" >> "$SESSION_FILE"
    sync "$SESSION_FILE"
done

echo "CPU stress completed: $(date)" | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

# Stop everything
kill $GPU_PID 2>/dev/null

echo "Completed: $(date)" | tee -a "$SESSION_FILE"
sync "$SESSION_FILE"

kill $TEMP_PID $POWER_PID $METRICS_PID $JOURNAL_PID $WATCHDOG_PID $THERMAL_PID $DISPLAY_PID 2>/dev/null
rm "$STAGE_FILE"

echo "Done. Files:"
echo "  Stress log:  $SESSION_FILE"
echo "  Temperature: $TEMP_FILE"
echo "  Power:       $POWER_FILE"
echo "  Metrics:     $METRICS_FILE"
echo "  Watchdog:    $WATCHDOG_FILE"
echo "  Thermal:     $THERMAL_FILE"
echo "  Journal:     $JOURNAL_FILE"
