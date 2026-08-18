#!/usr/bin/env bash
set -e

# Help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --headless   Run using xvfb-run (software LLVMpipe, useful for headless CI/CD)"
    echo "  -h, --help   Show this help message"
}

HEADLESS=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --headless) HEADLESS=true ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
    shift
done

echo "=== AUTOMATED PROFILING RUN ==="
if [ "$HEADLESS" = true ]; then
    echo "Mode: Headless (xvfb-run + LLVMpipe software rendering)"
else
    echo "Mode: Physical GPU hardware-accelerated (DISPLAY=$DISPLAY)"
fi

# Clean old trace if exists
rm -f /tmp/trace.tracy /tmp/trace.csv /tmp/trace_unwrapped.csv

# Start Tracy capture in the background (sends capture trigger)
echo "Starting tracy-capture..."
./deps/tracy/capture/build/tracy-capture -o /tmp/trace.tracy -s 14 &
CAPTURE_PID=$!

# Ensure profile build exists
if [ ! -f "./build/profile/suckless-odin" ]; then
    echo "ERROR: Profile build not found at ./build/profile/suckless-odin"
    echo "Please run 'just build-profile' first."
    kill $CAPTURE_PID 2>/dev/null || true
    exit 1
fi

if [ "$HEADLESS" = true ]; then
    # Headless: run under xvfb-run
    echo "Starting application under xvfb-run on DISPLAY :99..."
    xvfb-run -n 99 -s "-screen 0 1024x768x24" ./scripts/interactive_runner.sh ./build/profile/suckless-odin
else
    # Physical GPU: run directly on the active display
    echo "Starting application natively..."
    ./scripts/interactive_runner.sh ./build/profile/suckless-odin
fi


echo "Application stopped."

# Wait for tracy-capture to finish writing
wait $CAPTURE_PID || true
echo "Trace file size: $(du -sh /tmp/trace.tracy 2>/dev/null || echo '0')"

# Analyze the trace
if [ -f /tmp/trace.tracy ]; then
    echo "Exporting Tracy trace to CSV..."
    ./deps/tracy/csvexport/build/tracy-csvexport /tmp/trace.tracy > /tmp/trace.csv
    ./deps/tracy/csvexport/build/tracy-csvexport -u /tmp/trace.tracy > /tmp/trace_unwrapped.csv
    echo "Profile analysis completed successfully!"
    echo ""
    python3 scripts/analyze_profile.py /tmp/trace.csv /tmp/trace_unwrapped.csv
else
    echo "ERROR: Trace file was not generated."
    exit 1
fi

