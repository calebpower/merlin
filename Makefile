.PHONY: format lint check build all

format:
	uv run black . --target-version py311

lint:
	uv run ruff check .

check:
	uv run mypy merlin/

build: format lint check
	uv build
