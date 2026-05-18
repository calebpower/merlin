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
import signal
from merlin.api import start_api
from merlin.state import GlobalState

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

bg_tasks = set()

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

    runners = []
    # dynamically load hooks with a placeholder client initially
    for hook_cfg in config.get("hooks", []):
        mod = importlib.import_module(hook_cfg["module"])
        hook_inst = mod.Hook(state, None, hook_cfg)
        hooks.append(hook_inst)
        state.register_callback(hook_inst.on_state_change)

    # dynamically load and start runners
    for runner_cfg in config.get("runners", []):
        mod = importlib.import_module(runner_cfg["module"])
        runner_inst = mod.Runner(state, None, runner_cfg)
        runners.append(runner_inst)
        task = asyncio.create_task(runner_inst.start())
        bg_tasks.add(task)
        task.add_done_callback(bg_tasks.discard)

    api_host = config.get("api", {}).get("host", "0.0.0.0")
    api_port = config.get("api", {}).get("port", 8080)
    await start_api(hooks, api_host, api_port, db_path)

    while True:
        try:
            async with aiomqtt.Client(hostname=broker, port=port) as client:
                # update injected MQTT clients across modules upon successful connection
                for h in hooks: h.mqtt = client
                for r in runners: r.mqtt = client
    
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
                        bg_tasks.add(task)
                        task.add_done_callback(bg_tasks.discard)

        except aiomqtt.MqttError as error:
            logger.error(f"MQTT connection error: {error}. Reconnecting in 5 seconds...")
            await asyncio.sleep(5)

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
