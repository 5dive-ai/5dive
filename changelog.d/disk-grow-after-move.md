## Unreleased — fix(disk): a box moved to a bigger server grows into the new disk by itself

When a nearly full box is moved to a bigger server, the server gets a bigger disk, but on boxes whose startup resize is switched off the box kept using only the old size. The hourly disk check now grows the main partition and its filesystem into the extra space, online and with no restart. It only acts on boxes 5dive built, only when the main partition is the last one on the disk, and does nothing when there is nothing to grow. `5dive disk grow --dry-run` shows what it would do.
