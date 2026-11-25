#!/bin/bash
# =============================================================================
# probe-before-ready.sh: test helper, only in the "probe" variant of the test image
# =============================================================================
#
# PURPOSE
#   Proves two properties of the ready marker /run/impact-ready:
#     1. it does not exist while an earlier start-up script still runs;
#     2. a marker of an earlier start of the same container is gone by then.
#
# WHEN IT RUNS
#   At every container start, as the start-up script directly before the marker script
#   (its name in /etc/cont-init.d is zy-test-probe).
#
# WHAT IT CHANGES
#   It writes two small files in /run and waits three seconds. The wait gives
#   run-tests.sh time to look for the marker while this script is still running.
#
#   /run/impact-test-probe        "absent" or "present": the marker at the start of this script
#   /run/impact-test-probe-end    the time this script ended, in seconds with decimals
#
# WHAT IT NEVER TOUCHES
#   Everything else: the marker itself, the home folder and every mount. It exists only in
#   the "probe" variant of the test image and never in a model image.
# =============================================================================
# "rm -f" removes a file and is silent when it does not exist. "[ -e FILE ]" is true when
# FILE exists. "echo TEXT > FILE" writes TEXT into FILE. "date +%s.%N" prints the time in
# seconds since 1970, with nine decimals.
rm -f /run/impact-test-probe-end
if [ -e /run/impact-ready ]; then
    echo present > /run/impact-test-probe
else
    echo absent > /run/impact-test-probe
fi
sleep 3
date +%s.%N > /run/impact-test-probe-end
