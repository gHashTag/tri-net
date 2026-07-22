FROM rust:1.88-bookworm AS builder

WORKDIR /workspace
COPY . .
RUN cargo build --release --locked --manifest-path services/call-api/Cargo.toml

FROM debian:bookworm-slim

RUN useradd --create-home --uid 10001 trinet \
    && mkdir -p /data \
    && chown trinet:trinet /data
COPY --from=builder /workspace/services/call-api/target/release/trinet-call-api /usr/local/bin/trinet-call-api

USER trinet
WORKDIR /data
ENV TRINET_BIND=0.0.0.0:8080
ENV TRINET_DB_PATH=/data/trinet-call.sqlite
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/trinet-call-api"]
