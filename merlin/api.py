import sys
import importlib.util

if importlib.util.find_spec("_sqlite3") is None:
    import pysqlite3  # type: ignore

    sys.modules["sqlite3"] = pysqlite3

import json
import asyncio
import aiosqlite
import logging
from aiohttp import web
from pydantic import BaseModel
from typing import Any

logger = logging.getLogger(__name__)


class WebhookPayload(BaseModel):
    challenge: str
    status: Any


bg_tasks: set[asyncio.Task] = set()


async def snitch_handler(request):
    try:
        data = await request.json()
        logger.info(data)
        payload = WebhookPayload.model_validate(data)
        challenge = payload.challenge
        status = payload.status

        if challenge and status is not None:
            db_path = request.app.get("db_path", "merlin.db")
            async with aiosqlite.connect(db_path) as db:
                async with db.execute(
                    "SELECT topic FROM API_Key WHERE key = ?", (challenge,)
                ) as cursor:
                    row = await cursor.fetchone()
                    if row:
                        topic = row[0]
                        payload_str = (
                            status if isinstance(status, str) else json.dumps(status)
                        )
                        for h in request.app["hooks"]:
                            task = asyncio.create_task(h.on_message(topic, payload_str))
                            bg_tasks.add(task)
                            task.add_done_callback(bg_tasks.discard)
    except Exception as e:
        logger.error(f"exception at /snitch: {e}")

    return web.Response(text="OK", status=200)


async def start_api(hooks, host="0.0.0.0", port=8080, db_path="merlin.db"):
    app = web.Application()
    app["hooks"] = hooks
    app["db_path"] = db_path
    app.router.add_post("/snitch", snitch_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    await site.start()
    return runner
