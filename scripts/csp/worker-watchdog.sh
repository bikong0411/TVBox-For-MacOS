#!/system/bin/sh

start_worker() {
    result="$(am start --user 0 -n local.tvbox.csp/.WorkerActivity --es token "$(getprop ro.boot.tvbox_csp_token)" 2>&1)"
    case "$result" in *Error*|*Exception*) return 1 ;; esac
}

# Start before the launcher is ready, then recover a stopped worker inside the same VM.
for attempt in $(seq 1 360); do
    if service check activity 2>/dev/null | grep -q 'Service activity: found' && start_worker; then
        while true; do
            sleep 1
            pidof local.tvbox.csp >/dev/null 2>&1 || start_worker
        done
    fi
    sleep 2
done
exit 1
