# ZMK Config

This repository contains the configuration files for a ZMK-powered keyboard.

I usually compile the keyboard firware locally, that's way faster.

Run on the host, `rake setup`, `update`, `build` and `clean` run in the
devcontainer (or, if it isn't running, in a throwaway container built from
`.devcontainer/Dockerfile`). `rake flash` runs on the host.

rake clean

rake build

rake flash
