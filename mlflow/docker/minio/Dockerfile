FROM golang:1.24.8-alpine3.22 AS build

ARG MINIO_VERSION=RELEASE.2025-10-15T17-29-55Z

RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch "${MINIO_VERSION}" \
      https://github.com/minio/minio.git .
RUN CGO_ENABLED=0 go build \
      -tags kqueue \
      -trimpath \
      --ldflags "$(go run buildscripts/gen-ldflags.go)" \
      -o /out/minio .

FROM alpine:3.22

RUN apk add --no-cache ca-certificates curl tzdata \
    && addgroup -g 1000 minio-runtime \
    && adduser -D -H -u 1000 -G minio-runtime minio-runtime \
    && mkdir -p /data \
    && chown minio-runtime:minio-runtime /data

COPY --from=build /out/minio /usr/local/bin/minio

USER minio-runtime:minio-runtime
EXPOSE 9000 9001
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/minio"]
CMD ["server", "/data", "--address", ":9000", "--console-address", ":9001"]
