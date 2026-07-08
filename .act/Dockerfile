# Custom act runner image: Ubuntu 24.04 + OpenSSL 1.1 compat.
# act's built-in ImageOS mapping downloads OTP binaries built for Ubuntu 20.04
# (linked against libcrypto.so.1.1) even when using a 24.04 container image.
# This adds the OpenSSL 1.1 compat library so OTP 28 loads correctly.
#
# checkov:skip=CKV_DOCKER_2: act runner image, not a production container — no healthcheck needed
# checkov:skip=CKV_DOCKER_3: act runner requires root to simulate GitHub Actions runner
FROM catthehacker/ubuntu:act-24.04
# hadolint ignore=DL3008,DL3059
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl1.1 2>/dev/null || \
    ( ARCH=$(dpkg --print-architecture) && \
      if [ "$ARCH" = "arm64" ]; then \
        echo "deb http://ports.ubuntu.com/ubuntu-ports focal-security main" >> /etc/apt/sources.list; \
      else \
        echo "deb http://security.ubuntu.com/ubuntu focal-security main" >> /etc/apt/sources.list; \
      fi && \
      apt-get update && \
      apt-get install -y --no-install-recommends libssl1.1 ) && \
    rm -rf /var/lib/apt/lists/*
