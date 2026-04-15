# Build the manager binary
FROM docker.io/golang:1.24 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY cmd/main.go cmd/main.go
COPY api/ api/
COPY internal/ internal/
COPY pkg/ pkg/

# Build
# the GOARCH has not a default value to allow the binary be built according to the host where the command
# was called. For example, if we call make docker-build in a local env which has the Apple Silicon M1 SO
# the docker BUILDPLATFORM arg will be linux/arm64 when for Apple x86 it will be linux/amd64. Therefore,
# by leaving it empty we can ensure that the container and binary shipped on it will have the same platform.
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -a -o manager cmd/main.go

# Generate self-signed cert
RUN mkdir -p /certs && \
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /certs/tls.key -out /certs/tls.crt \
    -subj "/CN=local.svc"

# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM gcr.io/distroless/static:nonroot
WORKDIR /

COPY --from=builder /workspace/manager .
COPY config/configs/instance.yaml instance.yaml
COPY config/configs/applications.yaml applications.yaml
COPY config/configs/features/ features/
COPY LICENSE LICENSE-2.0.txt
COPY --from=builder /certs/tls.crt /certs/tls.crt
COPY --from=builder /certs/tls.key /certs/tls.key

# USER 65532:65532
# GID 0 required for Red Hat / OpenShift SCC compatibility on k0s nodes
USER 1001:0
ENV INSTANCE_FILE=/instance.yaml
ENV APPLICATION_FILE=/applications.yaml
ENTRYPOINT ["/manager"]
