.PHONY: dev build clean

dev:
	docker compose up

build:
	hugo --minify

clean:
	docker compose down -v
