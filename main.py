import asyncio
from src.main import main as app_main, logger

def main():
    try:
        asyncio.run(app_main())
    except KeyboardInterrupt:
        logger.info("shutting down")


if __name__ == "__main__":
    main()
