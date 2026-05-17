FROM hugomods/hugo:exts AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod tidy
COPY . .
RUN hugo --minify

FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /src/public /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
