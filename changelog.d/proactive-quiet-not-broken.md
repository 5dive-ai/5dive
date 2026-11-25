## Unreleased — fix(loops): a quiet Proactive check-in no longer tells the owner "it may be broken"

A Proactive check-in is built to send nothing on a quiet day. Since the self-healing loops, two quiet check-ins in a row sent the owner `"Check in with you" found nothing twice in a row. It may be broken.`, though nothing was wrong.

Quiet runs of a Proactive check-in now build no "found nothing" streak: no owner line, no seat notice, and no "Found nothing" badge in the app. The retry after a failed run and the weekly self-improving turn still run. Every other scheduled job that messages its owner keeps the line.
