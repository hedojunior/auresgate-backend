# Build
FROM swift:5.10-jammy AS build

WORKDIR /build

# Resolve dependencies first so a source change does not re-download them.
COPY Package.swift ./
RUN swift package resolve

COPY . .
RUN swift build -c release --static-swift-stdlib

RUN mkdir -p /staging && \
    cp "$(swift build -c release --show-bin-path)/App" /staging/

# Run
FROM ubuntu:jammy

RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true && \
    apt-get -q update && \
    apt-get -q install -y ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --home-dir /app vapor
WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app

USER vapor:vapor
EXPOSE 8080

# No --hostname/--port here on purpose: those flags override whatever
# configure.swift read from the environment, and cloud hosts inject PORT and
# route to it. Leaving them out lets the env win.
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production"]
