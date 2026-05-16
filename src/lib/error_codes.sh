
# -------- exit codes & output helpers --------

# Distinct classes so the frontend can switch without grepping stderr. Keep
# err_class_for() in sync if you add a code.
readonly E_OK=0
readonly E_GENERIC=1         # catch-all / internal
readonly E_USAGE=2           # unknown flag, missing arg, bad subcommand
readonly E_VALIDATION=3      # format check failed (name, workdir, token, lines)
readonly E_NOT_FOUND=4       # agent/type doesn't exist
readonly E_CONFLICT=5        # already exists
readonly E_AUTH_REQUIRED=6   # type not authenticated, bot token missing
readonly E_NOT_INSTALLED=7   # CLI binary missing, no installer recipe
readonly E_NOT_RUNNING=8     # tmux session / systemd unit not active
readonly E_PAIRING=9         # pair code not pending, invalid code
readonly E_PERMISSION=10     # must run as root
readonly E_TIMEOUT=11        # plugin didn't materialize within waitloop
