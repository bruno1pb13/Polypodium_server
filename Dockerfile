FROM dart:stable AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock* ./
RUN dart pub get

COPY . .
RUN dart compile exe bin/server.dart -o /server

# Minimal runtime image
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /server /server

RUN mkdir -p /photos

VOLUME ["/photos"]

ENV PHOTOS_DIR=/photos
ENV PORT=8080

EXPOSE 8080
ENTRYPOINT ["/server"]
