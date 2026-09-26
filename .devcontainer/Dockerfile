FROM docker.io/zmkfirmware/zmk-dev-arm:stable

# Ruby + rake drive the setup/update/build tasks (see Rakefile).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ruby rake \
    && rm -rf /var/lib/apt/lists/*
