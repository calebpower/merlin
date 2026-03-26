import sys
try:
    import _sqlite3
except ImportError:
    import pysqlite3
    sys.modules["sqlite3"] = pysqlite3

import argparse
import asyncio
import tomllib
import importlib
import logging
import uuid
import aiomqtt
import aiosqlite
from merlin.api import start_api
from merlin.state import GlobalState

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

async def async_main(config_path):
    # load configuration
    with open(config_path, "rb") as f:
        config = tomllib.load(f)

    state = GlobalState()
    hooks = []

    db_path = config.get("api", {}).get("db_path", "merlin.db")
    async with aiosqlite.connect(db_path) as db:
        await db.execute("CREATE TABLE IF NOT EXISTS API_Key (topic TEXT, key TEXT)")
        await db.commit()

    # connect to Mosquitto broker
    broker = config["mqtt"]["broker"]
    port = config["mqtt"]["port"]

    async with aiomqtt.Client(hostname=broker, port=port) as client:
        # dynamically load and initialize hooks
        for hook_cfg in config.get("hooks", []):
            mod = importlib.import_module(hook_cfg["module"])
            hook_inst = mod.Hook(state, client, hook_cfg)
            hooks.append(hook_inst)

        # dynamically load and start runners
        for runner_cfg in config.get("runners", []):
            mod = importlib.import_module(runner_cfg["module"])
            runner_inst = mod.Runner(state, client, runner_cfg)
            asyncio.create_task(runner_inst.start())

        # wire up state change listeners
        for h in hooks:
            state.register_callback(h.on_state_change)

        api_host = config.get("api", {}).get("host", "0.0.0.0")
        api_port = config.get("api", {}).get("port", 8080)
        await start_api(hooks, api_host, api_port, db_path)

        logger.info(f"connected to %s:%s; listening to all topics...", broker, port)

        # subscribe to all topics
        await client.subscribe("#")

        # listen indefinitely
        async for message in client.messages:
            topic = str(message.topic)
            try:
                payload = message.payload.decode() if message.payload else ""
            except UnicodeDecodeError:
                payload = "<binary>"

            # dispatch message to all hooks concurrently
            for h in hooks:
                asyncio.create_task(h.on_message(topic, payload))

async def manage_keys(args, db_path):
    async with aiosqlite.connect(db_path) as db:
        await db.execute("CREATE TABLE IF NOT EXISTS API_Key (topic TEXT, key TEXT)")
        if args.add_key:
            if not args.topic:
                print("Error: --topic is required when adding a key.")
                return
            new_key = str(uuid.uuid4())
            await db.execute("INSERT INTO API_Key (topic, key) VALUES (?, ?)", (args.topic, new_key))
            await db.commit()
            print(f"Added key '{new_key}' for topic '{args.topic}'.")
        elif args.rm_key:
            await db.execute("DELETE FROM API_Key WHERE key = ?", (args.rm_key,))
            await db.commit()
            print(f"Removed key '{args.rm_key}'.")
        elif args.list_keys:
            async with db.execute("SELECT key, topic FROM API_Key") as cursor:
                for row in await cursor.fetchall():
                    print(f"Key: {row[0]} | Topic: {row[1]}")

def main():
    parser = argparse.ArgumentParser(description="Merlin Home Automation")
    parser.add_argument("--config", default="config.toml", help="Path to config file")
    parser.add_argument("--add-key", action="store_true", help="Add an API key")
    parser.add_argument("--topic", metavar="TOPIC", help="Topic for the added API key")
    parser.add_argument("--rm-key", metavar="KEY", help="Remove an API key")
    parser.add_argument("--list-keys", action="store_true", help="List all API keys")
    args = parser.parse_args()

    try:
        import tomllib
        with open(args.config, "rb") as f:
            config = tomllib.load(f)
    except Exception:
        config = {}

    db_path = config.get("api", {}).get("db_path", "merlin.db")

    if args.add_key or args.rm_key or args.list_keys:
        asyncio.run(manage_keys(args, db_path))
        return
    
    try:
        asyncio.run(async_main(args.config))
    except KeyboardInterrupt:
        logger.info("shutting down")
                
if __name__ == "__main__":
    main()
