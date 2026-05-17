.PHONY: dev build clean

dev:
	docker compose up

build:
	docker build -t blog:local .

clean:
	docker compose down -v
