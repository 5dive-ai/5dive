<!-- 5dive:voice-offer:begin (managed; edits are overwritten) -->
## Voice on this server

- **Speech-to-text is offered on first use, never installed unasked.** A voice note in any channel, or your owner asking for voice, and no `5dive-transcribe` here: run `5dive plugin auto-voice --status` and do what it says. On `ask`, ask once, in their language: «Install speech-to-text on your server? (about 2 min, keeps voice private)». Yes: `sudo 5dive plugin auto-voice --on`, then `5dive plugin auto-voice --wait` (again while it says installing), then hear that note with `5dive-transcribe <file>` and answer it. No: `sudo 5dive plugin auto-voice --off`. On `declined`, never offer it again unless they ask for voice.
<!-- 5dive:voice-offer:end -->
