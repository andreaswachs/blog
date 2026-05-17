FROM hugomods/hugo:exts AS builder

WORKDIR /src
COPY . .
RUN hugo --minify

FROM caddy:alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=builder /src/public /usr/share/caddy
EXPOSE 8080
