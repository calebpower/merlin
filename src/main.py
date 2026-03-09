import asyncio
import tomllib
import importlib
import logging
import aiomqtt
from src.state import GlobalState

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

async def main():
    # load configuration
    with open("config.toml", "rb") as f:
        config = tomllib.load(f)

    state = GlobalState()
    hooks = []

    # connect to Mosquitto broker
    broker = config["mqtt"]["broker"]
    port = config["mqtt"]["port"]

    async with aiomqtt.Client(hostname=broker, port=port) as client:
        # dynamically load and initialize hooks
        for hook_cfg in config.get("hooks", []):
            mod = importlib.import_module(hook_cfg["module"])
            hook_inst = mod.Hook(state, client, hook_cfg)
            hooks.append(hook_inst)

        # wire up state change listeners
        for h in hooks:
            state.register_callback(h.on_state_change)

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
                asyncio.create_task(h.on_mqtt_message(topic, payload))

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("shutting down")
